import Foundation

final class ServerController {
    let config: AppConfig
    private(set) var child: Process?
    private(set) var externalPid: Int32?
    var serving = false { didSet { if serving != oldValue { servingChanged() } } }
    var stopping = false
    var state: ServerState = .unknown
    var onStateChange: ((ServerState) -> Void)?

    init(config: AppConfig) { self.config = config }

    var ownedPid: Int32? { child?.processIdentifier }

    func refreshState() {
        let s: ServerState
        if serving { s = .running }
        else if stopping { s = .stopping }
        else if child != nil { s = .loading }
        else { s = .stopped }
        if s != state { state = s; onStateChange?(s) }
    }

    private func servingChanged() {
        if serving { stopping = false }
        else if stopping {
            stopping = false
            child = nil
            detectExternal()
        }
        refreshState()
    }

    func start() {
        if serving || child != nil { return }
        let logURL = config.serverLogURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: logURL) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.bin)
        p.arguments = config.args
        var env = ProcessInfo.processInfo.environment
        let binDir = (config.bin as NSString).deletingLastPathComponent
        env["PATH"] = binDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["MLX_BAR_CHILD"] = "1"
        p.environment = env
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.child?.processIdentifier == proc.processIdentifier { self.child = nil }
                self.detectExternal()
                self.refreshState()
            }
        }
        do { try p.run() } catch {
            NSLog("mlx-bar: failed to launch \(config.bin): \(error)")
            return
        }
        child = p
        refreshState()
    }

    func stop() {
        if child != nil {
            stopping = true
            child?.terminate()
        } else if let pid = externalPid {
            stopping = true
            kill(pid, SIGTERM)
        }
        refreshState()
    }

    // Scan for a running mlx-serve matching the configured port (started outside the bar).
    func detectExternal() {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,command="]) ?? ""
        var found: Int32? = nil
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            if pid == child?.processIdentifier { continue }
            let tokens = AppConfig.tokenize(String(parts[1]))
            guard let first = tokens.first else { continue }
            let base = (first as NSString).lastPathComponent
            guard base.hasPrefix("mlx-serve") else { continue }
            let hasPort = tokens.contains("--port") && tokens.contains(String(config.port))
            if hasPort || tokens.contains(String(config.port)) {
                found = pid
                break
            }
        }
        externalPid = found
    }

    func statusJSON() -> String {
        let s = MetricsEngineStatic.snapshotProvider?()
        var kv = [
            "\"state\":\"\(state.rawValue)\"",
            "\"serving\":\(serving)",
            "\"owned_pid\":\(child?.processIdentifier ?? 0)",
            "\"external_pid\":\(externalPid ?? 0)"
        ]
        if let s {
            kv.append("\"decode_tok_s\":\(String(format: "%.2f", s.decode))")
            kv.append("\"prefill_tok_s\":\(String(format: "%.2f", s.prefill))")
            kv.append("\"live_tokens\":\(Int(s.liveTok))")
            kv.append("\"cache_hit_pct\":\(String(format: "%.1f", s.cachePct))")
            kv.append("\"tokens_reused_pct\":\(String(format: "%.1f", s.tokPct))")
            kv.append("\"memory_mb\":\(s.memMB)")
            kv.append("\"gpu_pct\":\(s.gpuPct)")
            kv.append("\"ttft_ms\":\(String(format: "%.1f", s.ttftMs))")
            kv.append("\"requests_running\":\(s.running)")
        }
        return "{\(kv.joined(separator: ","))}"
    }
}

// Hook set by AppDelegate so the controller can serialize current metrics for `ctl status`.
enum MetricsEngineStatic {
    static var snapshotProvider: (() -> MetricsSnapshot?)?
}
