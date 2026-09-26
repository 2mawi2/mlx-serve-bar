import Foundation

/// Privacy preferences shared with the shell tooling.
///
/// Backing store is `~/.pi/agent/mlx-bar-privacy.conf`, a flat `key=0|1` file that is
/// *valid shell*, so `~/.local/bin/pi` and the `mlx-serve` launchers can `. ` it directly.
/// The app is the friendly editor; the file stays the single source of truth.
struct Privacy: Equatable {
    var telemetry = false   // pi install/update telemetry
    var ephemeral = true    // pi runs with --no-session unless the user opts in
    var serverLog = true    // keep the server prompt log
    var kvCache = true      // keep the prompt-derived KV cache on disk

    static var confURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/mlx-bar-privacy.conf")
    }

    static var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mlx-serve/kv-cache")
    }

    static let keys: [(key: String, label: String, hint: String)] = [
        ("telemetry", "pi telemetry", "anonymous install/update reports"),
        ("ephemeral", "pi sessions ephemeral", "no transcript written to ~/.pi/agent/sessions"),
        ("server_log", "server prompt log", "first line of every request, to disk"),
        ("kv_cache", "KV cache on disk", "prompt-derived state; big, but the main speed lever")
    ]

    static func load() -> Privacy {
        var p = Privacy()
        guard let text = try? String(contentsOf: confURL, encoding: .utf8) else { return p }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var val = parts[1].trimmingCharacters(in: .whitespaces)
            if let hash = val.firstIndex(of: "#") {
                val = String(val[val.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            let on = (val == "1" || ["true", "yes", "on"].contains(val.lowercased()))
            _ = p.set(key, on)
        }
        return p
    }

    @discardableResult
    mutating func set(_ key: String, _ value: Bool) -> Bool {
        switch key {
        case "telemetry": telemetry = value
        case "ephemeral": ephemeral = value
        case "server_log": serverLog = value
        case "kv_cache": kvCache = value
        default: return false
        }
        return true
    }

    func value(_ key: String) -> Bool? {
        switch key {
        case "telemetry": return telemetry
        case "ephemeral": return ephemeral
        case "server_log": return serverLog
        case "kv_cache": return kvCache
        default: return nil
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: Privacy.confURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let text = """
        # MLX Bar privacy settings — managed by the MLX Bar app, safe to edit by hand.
        # This file is sourced by ~/.local/bin/pi and by the mlx-serve launchers (valid sh).
        telemetry=\(telemetry ? 1 : 0)      # 1 = allow pi install/update telemetry
        ephemeral=\(ephemeral ? 1 : 0)      # 1 = pi runs with --no-session unless you pass -c/--session
        server_log=\(serverLog ? 1 : 0)     # 1 = keep the server's prompt log (first line of each message)
        kv_cache=\(kvCache ? 1 : 0)         # 1 = keep the prompt-derived KV cache on disk (performance)
        """
        try? text.write(to: Privacy.confURL, atomically: true, encoding: .utf8)
    }

    /// Mutate + persist in one step; returns the new JSON state.
    static func update(_ key: String, _ value: Bool) -> String {
        var p = load()
        guard p.set(key, value) else { return "{\"error\":\"unknown key\"}" }
        p.save()
        return p.json
    }

    var json: String {
        var kv = Privacy.keys.map { "\($0.key):\((value($0.key) ?? false) ? "true" : "false")" }
        kv.append("cache_mb:\(Privacy.cacheMB())")
        kv.append("cache_entries:\(Privacy.cacheEntries())")
        kv.append("conf:\"\(Privacy.confURL.path)\"")
        return "{\(kv.joined(separator: ","))}"
    }

    // MARK: - KV cache inspection / cleanup

    static func cacheMB() -> Int {
        guard let out = Shell.run("/usr/bin/du", ["-sk", cacheDir.path]) else { return 0 }
        let kb = out.split(whereSeparator: { $0 == "\t" || $0 == "\n" }).first
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        return kb / 1024
    }

    static func cacheEntries() -> Int {
        guard let models = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else { return 0 }
        var n = 0
        for m in models {
            let mdir = cacheDir.appendingPathComponent(m)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: mdir.path) else { continue }
            n += entries.filter { $0.hasPrefix("e") }.count
        }
        return n
    }

    /// Delete every persisted entry directory. Safe only while the server is stopped.
    static func clearCache() -> Int {
        let fm = FileManager.default
        var removed = 0
        guard let models = try? fm.contentsOfDirectory(atPath: cacheDir.path) else { return 0 }
        for m in models {
            let mdir = cacheDir.appendingPathComponent(m)
            guard let entries = try? fm.contentsOfDirectory(atPath: mdir.path) else { continue }
            for entry in entries where entry.hasPrefix("e") {
                if (try? fm.removeItem(at: mdir.appendingPathComponent(entry))) != nil { removed += 1 }
            }
        }
        return removed
    }
}
