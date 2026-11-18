import Foundation

/// Which local inference server the bar watches and can start/stop.
///
/// mlx-serve and sushi differ in exactly three places that matter here:
///  - the process name seen in `ps` (server detection),
///  - the canonical launcher (~/.local/bin/<backend>-start),
///  - metrics: sushi serves Prometheus metrics only on demand (`--metrics`, or
///    POST /metrics/enable), while mlx-serve's launcher always enables them.
/// Everything else — `/health`, `/metrics.json` shape and metric names, the
/// dashboard page — is identical, so one metrics engine covers both.
///
/// splash is a third, different animal: a Python server wrapping a native engine
/// (so two processes, and the *parent* is a `python3 -m server.server` line),
/// Prometheus text exposition on `/metrics` with its own `splash_*` vocabulary
/// and no `/metrics.json` at all. `MetricsEngine` maps its gauges onto the same
/// `MetricsSnapshot`, so every tile, sparkline and `ctl` field keeps working.
enum Backend: String, Codable, CaseIterable {
    case mlxServe = "mlx-serve"
    case sushi = "sushi"
    case splash = "splash"

    var displayName: String { rawValue }

    /// Binaries that identify this backend in the process table.
    var processNames: [String] {
        switch self {
        case .mlxServe: return ["mlx-serve", "mlx-serve-flash", "mlx-serve.exe"]
        case .sushi: return ["sushi", "sushi-bin", "sushi.exe"]
        case .splash: return ["splash", "splash-engine"]
        }
    }

    /// Metrics endpoint and its format. splash publishes Prometheus text; the
    /// others serve the dashboard's JSON panel feed.
    var metricsPath: String { self == .splash ? "/metrics" : "/metrics.json" }
    var metricsIsPrometheus: Bool { self == .splash }

    /// splash keeps KV state in RAM (verified against a live server: no spill
    /// files, weights mmapped read-only), so there is nothing to clear or reveal.
    var persistentKVCache: Bool { self != .splash }

    /// Canonical launcher: port safety checks + model verification + full args.
    var startScriptName: String {
        switch self {
        case .mlxServe: return "mlx-serve-start"
        case .sushi: return "sushi-deepseek-start"
        case .splash: return "splash-start"
        }
    }

    /// The canonical launcher when installed. Splash is usually started through a
    /// model-specific wrapper (`splash-swap-start`, …), so fall back to any
    /// `<backend>-*-start` script before giving up and naming the canonical one.
    var startScript: String {
        let dir = ("~/.local/bin" as NSString).expandingTildeInPath
        let canonical = dir + "/" + startScriptName
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: canonical) { return canonical }
        if let names = try? fm.contentsOfDirectory(atPath: dir) {
            for n in names.sorted() where n.hasPrefix("\(rawValue)-") && n.hasSuffix("-start") {
                let p = dir + "/" + n
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return canonical
    }

    /// Sushi needs an explicit metrics request; mlx-serve does not.
    var metricsOptIn: Bool { self == .sushi }

    /// Prompt-derived KV cache location, per backend.
    var kvCacheDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .mlxServe: return home.appendingPathComponent(".mlx-serve/kv-cache")
        case .sushi: return home.appendingPathComponent(".sushi/kv-cache")
        case .splash: return home.appendingPathComponent("Library/Application Support/Splash")
        }
    }

    /// Menu-bar glyph while the server is stopped or loading.
    var symbolName: String {
        switch self {
        case .mlxServe: return "waveform.path.ecg"
        case .sushi: return "fish"
        case .splash: return "drop"
        }
    }

    var symbolDescription: String { "\(displayName) server" }

    /// Infer the backend from a server command line, e.g.
    /// `/Users/me/.local/bin/sushi serve --model … --port 11234`.
    static func detect(fromCommand line: String) -> Backend? {
        let tokens = AppConfig.tokenize(line)
        guard let first = tokens.first else { return nil }
        let base = (first as NSString).lastPathComponent
        for b in Backend.allCases where b.processNames.contains(base) { return b }
        // A wrapper script shows as `bash /path/sushi-deepseek-start` until it
        // execs, and per-model variants exist too (splash-swap-start).
        for b in Backend.allCases where tokens.contains(where: {
            let n = ($0 as NSString).lastPathComponent
            return n == b.startScriptName || (n.hasPrefix("\(b.rawValue)-") && n.hasSuffix("-start"))
        }) { return b }
        if isSplash(tokens: tokens, firstBase: base) { return .splash }
        return nil
    }

    /// splash runs as two processes, neither named `splash` in the way the loop
    /// above expects:
    ///   `/opt/homebrew/…/libexec/engine/splash serve-native <dir> 262144 auto`
    ///   `python3 -u -P -m server.server <model-dir> --binary …/engine/splash
    ///      --port 11234 --serve-record … --served-model-name local/flash`
    /// The engine binary appears as the argv[0] of the child and as the value of
    /// `--binary` in the parent, so either names it.
    private static func isSplash(tokens: [String], firstBase: String) -> Bool {
        if firstBase == "splash" || firstBase == "splash-engine" { return true }
        if tokens.contains(where: { ($0 as NSString).lastPathComponent == "splash" }) { return true }
        if tokens.contains("server.server")
            && tokens.contains(where: { $0.hasPrefix("--serve-record") || $0.hasPrefix("--served-model-name") }) {
            return true
        }
        return false
    }

    /// Fallback: `/v1/models` advertises the pack owner (`owned_by`).
    static func detect(fromModelsJSON data: Data) -> Backend? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return nil }
        for m in list {
            let owner = (m["owned_by"] as? String ?? "").lowercased()
            if owner.contains("splash") { return .splash }
            if owner.contains("sushi") { return .sushi }
            if owner.contains("mlx") { return .mlxServe }
        }
        return nil
    }

    /// Infer from the configured launcher path, so config.json files written by
    /// older versions (no `backend` key) keep working.
    static func infer(bin: String, args: [String] = []) -> Backend {
        let haystack = (bin + " " + args.joined(separator: " ")).lowercased()
        if haystack.contains("splash") { return .splash }
        return haystack.contains("sushi") ? .sushi : .mlxServe
    }
}
