import Foundation

struct RPCCmd: Codable { var cmd: String }

// Tiny line protocol over a unix socket so `mlx-bar ctl` and scripts can drive the bar.
final class RPCServer {
    private var listenFD: Int32 = -1
    private let path: String
    private let queue = DispatchQueue(label: "mlxbar.rpc", qos: .utility)
    private var stopped = false
    var handle: ((RPCCmd) -> String)?  // called on main thread

    init(path: String) {
        self.path = path
    }

    func start() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { close(listenFD); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { NSLog("mlx-bar: rpc bind failed \(errno)"); close(listenFD); return }
        listen(listenFD, 4)
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while !stopped {
            let c = accept(listenFD, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                break
            }
            serve(c)
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > 64 * 1024 { break }
        }
        guard let cmd = (try? JSONDecoder().decode(RPCCmd.self, from: data)) else {
            writeAll(c, "{\"error\":\"bad command\"}")
            return
        }
        if cmd.cmd == "ping" { writeAll(c, "{\"pong\":true}"); return }
        let resp = DispatchQueue.main.sync { handle?(cmd) ?? "{\"error\":\"closed\"}" }
        writeAll(c, resp)
    }

    private func writeAll(_ fd: Int32, _ s: String) {
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, bytes.count - off) }
            if n <= 0 { break }
            off += n
        }
    }

    func stop() {
        stopped = true
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    deinit { stop() }
}

enum RPCClient {
    static func call(socketPath: String, cmd: String, timeout: TimeInterval = 2.5) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else { return nil }
        let payload = Array("{\"cmd\":\"\(cmd)\"}".utf8)
        let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        guard sent > 0 else { return nil }
        shutdown(fd, SHUT_WR)
        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            resp.append(contentsOf: buf[0..<n])
        }
        return String(data: resp, encoding: .utf8)
    }
}

enum CTL {
    static let usage = """
    usage: mlx-bar ctl [--config <path>] <command>
      status                       current server + metrics state
      start | stop | quit | ping
      rect | panel | events        UI diagnostics
      privacy                      show privacy settings + KV cache size
      privacy-set <key> <0|1>      toggle telemetry|ephemeral|server_log|kv_cache
      cache-clear                  delete persisted KV cache entries
    """

    static func run(_ args: [String]) -> Int32 {
        var configPath: String? = nil
        var positional: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--config", i + 1 < args.count { configPath = (args[i + 1] as NSString).expandingTildeInPath; i += 2; continue }
            positional.append(args[i])
            i += 1
        }
        guard !positional.isEmpty else {
            FileHandle.standardError.write(Data(CTL.usage.utf8))
            return 2
        }
        let c = positional.joined(separator: " ")
        let simple = ["status", "start", "stop", "quit", "ping", "rect", "panel", "events", "privacy", "cache-clear"]
        guard simple.contains(c) || c.hasPrefix("privacy-set ") else {
            FileHandle.standardError.write(Data(CTL.usage.utf8))
            return 2
        }
        let cfgURL: URL
        if let p = configPath { cfgURL = URL(fileURLWithPath: p) }
        else if let p = ProcessInfo.processInfo.environment["MLX_BAR_CONFIG"] { cfgURL = URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        else { cfgURL = AppConfig.defaultConfigURL }
        let sock = AppConfig.socketPath(forConfigFile: cfgURL)
        guard let resp = RPCClient.call(socketPath: sock, cmd: c) else {
            print("mlx-bar: not running")
            return 1
        }
        print(resp)
        return resp.contains("\"error\"") ? 1 : 0
    }
}
