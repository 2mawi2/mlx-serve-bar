import Foundation

struct RawConfig: Codable {
    var bin: String
    var args: [String]
    var host: String
    var port: Int
    var backend: String?
}

struct AppConfig {
    var bin: String
    var args: [String]
    var host: String
    var port: Int
    var backend: Backend
    var fileURL: URL

    var baseURL: String { "http://\(host):\(port)" }
    var dashboardURL: String { "http://\(host):\(port)/" }
    var metricsURL: String { baseURL + backend.metricsPath }
    var metricsEnableURL: String { baseURL + "/metrics/enable" }
    var healthURL: String { baseURL + "/health" }
    var modelsURL: String { baseURL + "/v1/models" }

    /// Canonical launcher for the active backend: port safety checks, model
    /// verification and full args baked in.
    var startScript: String { backend.startScript }

    var labelSuffix: String {
        fileURL.lastPathComponent == "config.json" ? "" : "-\(fileURL.deletingPathExtension().lastPathComponent)"
    }
    var socketPath: String {
        fileURL.deletingPathExtension().appendingPathExtension("rpc.sock").path
    }
    var logDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
            .appendingPathComponent("MLXBar\(labelSuffix)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var serverLogURL: URL { logDir.appendingPathComponent("server.log") }

    static var defaultConfigURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MLXBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func socketPath(forConfigFile url: URL) -> String {
        url.deletingPathExtension().appendingPathExtension("rpc.sock").path
    }

    static func load() -> AppConfig {
        let url: URL
        if let p = ProcessInfo.processInfo.environment["MLX_BAR_CONFIG"] {
            url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            url = defaultConfigURL
        }
        if let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode(RawConfig.self, from: data) {
            let b = raw.backend.flatMap { Backend(rawValue: $0) }
                ?? Backend.infer(bin: raw.bin, args: raw.args)
            return AppConfig(bin: (raw.bin as NSString).expandingTildeInPath,
                             args: raw.args, host: raw.host, port: raw.port,
                             backend: b, fileURL: url)
        }
        var cfg = discover() ?? RawConfig(bin: Backend.mlxServe.startScript, args: [],
                                          host: "127.0.0.1", port: 11234,
                                          backend: Backend.mlxServe.rawValue)
        cfg.bin = (cfg.bin as NSString).expandingTildeInPath
        let b = cfg.backend.flatMap { Backend(rawValue: $0) }
            ?? Backend.infer(bin: cfg.bin, args: cfg.args)
        let app = AppConfig(bin: cfg.bin, args: cfg.args, host: cfg.host, port: cfg.port,
                            backend: b, fileURL: url)
        app.save()
        return app
    }

    func save() {
        let raw = RawConfig(bin: bin, args: args, host: host, port: port,
                            backend: backend.rawValue)
        if let data = try? JSONEncoder().encodeWithPretty(raw) {
            try? data.write(to: fileURL)
        }
    }

    static func discover() -> RawConfig? {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,command="]) ?? ""
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let cmd = String(parts[1])
            guard let backend = Backend.detect(fromCommand: cmd) else { continue }
            let tokens = tokenize(cmd)
            guard let first = tokens.first else { continue }
            let base = (first as NSString).lastPathComponent
            let argTokens = Array(tokens.dropFirst())
            var host = "127.0.0.1"
            var port = 11234
            var i = 0
            while i < argTokens.count {
                if argTokens[i] == "--host", i + 1 < argTokens.count { host = argTokens[i + 1]; i += 2; continue }
                if argTokens[i] == "--port", i + 1 < argTokens.count, let p = Int(argTokens[i + 1]) { port = p; i += 2; continue }
                i += 1
            }
            let canonical = backend.startScript
            // Prefer the canonical start script (safety checks + full args baked in,
            // and for sushi it also opens the metrics endpoint);
            // fall back to the discovered wrapper/binary with the live args.
            let bin: String
            let args: [String]
            if FileManager.default.isExecutableFile(atPath: canonical) {
                bin = canonical
                args = []
            } else {
                let wrapper = ("~/.local/bin/\(base)" as NSString).expandingTildeInPath
                bin = FileManager.default.isExecutableFile(atPath: wrapper) ? wrapper : first
                args = argTokens
            }
            return RawConfig(bin: bin, args: args, host: host, port: port,
                             backend: backend.rawValue)
        }
        return nil
    }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var inSingle = false, inDouble = false, escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" && !inSingle { escaped = true; continue }
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if ch == " " && !inSingle && !inDouble {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
                continue
            }
            cur.append(ch)
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }
}

enum Shell {
    static func run(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

extension JSONEncoder {
    func encodeWithPretty<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(v)
    }
}
