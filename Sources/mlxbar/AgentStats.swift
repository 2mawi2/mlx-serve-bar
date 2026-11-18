import Foundation
import Combine

// The server tiles say what the GPU is doing, but not *who* is asking. Pi answers
// that for free: every session appends one JSON line per event to
// ~/.pi/agent/sessions/<cwd-slug>/<timestamp>_<id>.jsonl (append-only, see
// docs/session-format.md), and those lines carry model, per-message usage,
// per-message duration and cost.
//
// Reading the transcripts means the bar sees every Pi session on the machine —
// including ones started without any plugin — and Pi itself is never modified.
// Only structural fields are read (cwd, names, model ids, usage numbers,
// timestamps); message/tool text is parsed past and never copied into the
// snapshot, the popover or `ctl agent`. Ephemeral sessions (`--no-session`,
// privacy key `ephemeral`) write no transcript at all and therefore stay
// invisible, which is the correct outcome.
//
// Reads are incremental: per file we remember the byte offset of the last parsed
// newline and only read the appended tail, so a 5 MB transcript costs a few
// kilobytes per tick instead of a full re-parse.

struct AgentSession {
    var id = ""
    var title = ""              // /rename name when set, else the project folder
    var cwd = ""
    var provider = ""
    var model = ""
    var thinking = ""
    var lastWrite = Date.distantPast   // file mtime: Pi writes as the turn proceeds
    var ctxTokens = 0           // totalTokens of the last reply ≈ what is in context
    var ctxWindow = 0           // that model's contextWindow from models.json
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0
    var cost = 0.0
    var messages = 0            // assistant replies
    var outTps = -1.0           // last reply: output ÷ durationMs (agent-side speed)
    var durationMs = -1.0
    var lastRole = ""
    var lastStop = ""

    var ctxPct: Double { ctxWindow > 0 ? Double(ctxTokens) / Double(ctxWindow) * 100 : -1 }

    func working(now: Date, within: TimeInterval = 12) -> Bool {
        now.timeIntervalSince(lastWrite) < within
    }

    /// What the session is most likely doing. Pi appends a line when a tool
    /// result lands and when a reply finishes, so the last role plus file
    /// freshness is enough for a label; it is a heuristic, not a live state.
    func phase(now: Date) -> String {
        guard working(now: now) else { return "idle" }
        switch lastRole {
        case "toolResult": return "tool → request"
        case "assistant":  return "decoding"
        case "user":       return "requesting"
        default:           return "active"
        }
    }

    func json(now: Date) -> String {
        var kv = [
            "\"id\":\"\(AgentSession.escape(id))\"",
            "\"title\":\"\(AgentSession.escape(title))\"",
            "\"cwd\":\"\(AgentSession.escape(cwd))\"",
            "\"provider\":\"\(AgentSession.escape(provider))\"",
            "\"model\":\"\(AgentSession.escape(model))\"",
            "\"thinking\":\"\(AgentSession.escape(thinking))\"",
            "\"phase\":\"\(phase(now: now))\"",
            "\"working\":\(working(now: now))",
            "\"age_s\":\(String(format: "%.1f", max(0, now.timeIntervalSince(lastWrite))))",
            "\"ctx_tokens\":\(ctxTokens)",
            "\"ctx_window\":\(ctxWindow)",
            "\"ctx_pct\":\(String(format: "%.1f", ctxPct))",
            "\"input\":\(inputTokens)",
            "\"output\":\(outputTokens)",
            "\"reasoning\":\(reasoningTokens)",
            "\"cache_read\":\(cacheReadTokens)",
            "\"cache_write\":\(cacheWriteTokens)",
            "\"cost\":\(String(format: "%.4f", cost))",
            "\"messages\":\(messages)",
            "\"out_tok_s\":\(String(format: "%.1f", outTps))",
            "\"duration_ms\":\(String(format: "%.0f", durationMs))"
        ]
        kv.sort()
        return "{\(kv.joined(separator: ","))}"
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }
}

struct AgentSnapshot {
    var sessions: [AgentSession] = []
    var now = Date()

    var workingCount: Int { sessions.filter { $0.working(now: now) }.count }
    var isEmpty: Bool { sessions.isEmpty }

    var inputTokens: Int { sessions.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { sessions.reduce(0) { $0 + $1.outputTokens } }
    var cacheReadTokens: Int { sessions.reduce(0) { $0 + $1.cacheReadTokens } }
    var cost: Double { sessions.reduce(0) { $0 + $1.cost } }

    func json() -> String {
        let list = sessions.map { $0.json(now: now) }.joined(separator: ",")
        let totals = "\"totals\":{\"sessions\":\(sessions.count),\"input\":\(inputTokens),"
            + "\"output\":\(outputTokens),\"cache_read\":\(cacheReadTokens),"
            + "\"cost\":\(String(format: "%.4f", cost))}}"
        return "{\"now\":\(String(format: "%.3f", now.timeIntervalSince1970)),"
            + "\"working\":\(workingCount),\"sessions\":[\(list)],\(totals)"
    }
}

final class AgentStatsModel: ObservableObject {
    @Published var snap = AgentSnapshot()
}

/// Incremental reader over `~/.pi/agent/sessions`. Not thread-safe: call it from
/// the main thread, which is what the UI poller does.
final class AgentScanner {
    /// Sessions newer than this are listed at all.
    var recentWindow: TimeInterval = 300
    /// Cap on files read per tick, newest first.
    var maxSessions = 16

    private struct FileState {
        var offset: UInt64 = 0
        var pending = Data()          // trailing bytes of a not-yet-complete line
        var session = AgentSession()
    }

    private let fm = FileManager.default
    private var state: [String: FileState] = [:]
    private var windowSource: (mtime: TimeInterval, map: [String: Int])?

    let sessionsRoot: URL
    let modelsFiles: [URL]
    private let clock: () -> Date

    init(agentDir: URL? = nil, sessionsRoot: URL? = nil, modelsFiles: [URL]? = nil,
         now: @escaping () -> Date = Date.init) {
        let env = ProcessInfo.processInfo.environment
        func expanded(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        let dir = agentDir
            ?? env["PI_CODING_AGENT_DIR"].map { expanded($0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        self.sessionsRoot = sessionsRoot
            ?? env["PI_CODING_AGENT_SESSION_DIR"].map { expanded($0) }
            ?? dir.appendingPathComponent("sessions")
        self.modelsFiles = modelsFiles ?? [dir.appendingPathComponent("models.json"),
                                           dir.appendingPathComponent("models-store.json")]
        self.clock = now
    }

    // MARK: - scanning

    func scan(now: Date? = nil) -> AgentSnapshot {
        let t = now ?? clock()
        var found: [(url: URL, mtime: TimeInterval, size: Int64)] = []
        // stat() through FileManager, not URLResourceValues: Foundation caches the
        // latter per URL, which can hide the line Pi appended a second ago.
        for dir in (try? fm.contentsOfDirectory(atPath: sessionsRoot.path)) ?? [] {
            let dirURL = sessionsRoot.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? [] where name.hasSuffix(".jsonl") {
                let fileURL = dirURL.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                      let m = attrs[.modificationDate] as? Date else { continue }
                if t.timeIntervalSince(m) > recentWindow { continue }
                found.append((fileURL, m.timeIntervalSince1970, (attrs[.size] as? NSNumber)?.int64Value ?? 0))
            }
        }
        found.sort { $0.mtime > $1.mtime }
        if found.count > maxSessions { found = Array(found.prefix(maxSessions)) }

        let windows = contextWindows()
        var out: [AgentSession] = []
        var alive = Set<String>()
        for f in found {
            let path = f.url.path
            alive.insert(path)
            var st = state[path] ?? FileState()
            if st.offset > UInt64(max(f.size, 0)) { st = FileState() }   // replaced/truncated
            if readAppendages(to: &st, url: f.url, size: f.size, windows: windows) {
                state[path] = st
            }
            var s = st.session
            s.lastWrite = Date(timeIntervalSince1970: f.mtime)
            if s.id.isEmpty { s.id = f.url.deletingPathExtension().lastPathComponent }
            if s.title.isEmpty {
                s.title = URL(fileURLWithPath: s.cwd.isEmpty ? path : s.cwd).lastPathComponent
            }
            out.append(s)
        }
        state = state.filter { alive.contains($0.key) }

        var snap = AgentSnapshot()
        snap.sessions = out
        snap.now = t
        return snap
    }

    /// Read the bytes appended since the last tick and merge them into `st`.
    /// Returns true when anything was consumed, so the caller caches the state.
    @discardableResult
    private func readAppendages(to st: inout FileState, url: URL, size: Int64,
                                windows: [String: Int]) -> Bool {
        guard size > 0, UInt64(size) > st.offset || !st.pending.isEmpty else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: st.offset)
            guard let chunk = try handle.readToEnd(), !chunk.isEmpty else { return false }
            st.pending.append(chunk)
            // Consume whole lines only: Pi may be caught mid-write at the tail.
            var last = st.pending.startIndex
            var consumedLines = 0
            for i in st.pending.indices where st.pending[i] == 0x0A {
                let line = st.pending[last..<i]
                if !line.isEmpty { merge(Data(line), into: &st, windows: windows) }
                last = st.pending.index(after: i)
                consumedLines += 1
            }
            let bytes = st.pending.distance(from: st.pending.startIndex, to: last)
            st.pending.removeSubrange(st.pending.startIndex..<last)
            st.offset += UInt64(bytes)
            return consumedLines > 0
        } catch {
            return false
        }
    }

    private func merge(_ line: Data, into st: inout FileState, windows: [String: Int]) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        var s = st.session

        switch type {
        case "session":
            s.cwd = (obj["cwd"] as? String) ?? s.cwd
            if let id = obj["id"] as? String { s.id = id }
        case "session_info":
            if let n = obj["name"] as? String, !n.isEmpty { s.title = n }
        case "model_change":
            if let p = obj["provider"] as? String { s.provider = p }
            if let m = obj["modelId"] as? String { s.model = m }
        case "thinking_level_change":
            s.thinking = (obj["thinkingLevel"] as? String) ?? s.thinking
        case "message":
            guard let m = obj["message"] as? [String: Any] else { break }
            let role = (m["role"] as? String) ?? ""
            if !role.isEmpty { s.lastRole = role }
            let usage = m["usage"] as? [String: Any]
            if role == "assistant" {
                s.messages += 1
                if let p = m["provider"] as? String { s.provider = p }
                if let mo = m["model"] as? String { s.model = mo }
                if let tl = m["thinkingLevel"] as? String { s.thinking = tl }
                if let sr = m["stopReason"] as? String { s.lastStop = sr }
                if let cw = windows["\(s.provider)/\(s.model)"] ?? windows[s.model] { s.ctxWindow = cw }
                // totalTokens of the newest reply *is* the context that reply
                // carried, which is what the context bar should fill to. Usage
                // entries outside the conversation (cache warming, compaction)
                // count towards totals but not towards context size.
                if let t = num(usage?["totalTokens"]) { s.ctxTokens = Int(t) }
                if let d = num(m["durationMs"]), d > 1 {
                    s.durationMs = d
                    let out = num(usage?["output"]) ?? 0
                    s.outTps = out / (d / 1000)
                }
            }
            if let u = usage { apply(u, to: &s) }
        default:
            // `usage`, `compaction` and `branch_summary` all carry usage that Pi
            // counts in the session totals, so the bar counts it the same way.
            if let u = obj["usage"] as? [String: Any] { apply(u, to: &s) }
        }
        st.session = s
    }

    private func apply(_ u: [String: Any], to s: inout AgentSession) {
        s.inputTokens += Int(num(u["input"]) ?? 0)
        s.outputTokens += Int(num(u["output"]) ?? 0)
        s.cacheReadTokens += Int(num(u["cacheRead"]) ?? 0)
        s.cacheWriteTokens += Int(num(u["cacheWrite"]) ?? 0)
        s.reasoningTokens += Int(num(u["reasoning"]) ?? 0)
        if let c = u["cost"] as? [String: Any] { s.cost += num(c["total"]) ?? 0 }
    }

    private func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    // MARK: - context windows

    /// provider/id → contextWindow, from models.json plus the downloaded catalog
    /// in models-store.json. Cached until either file changes.
    private func contextWindows() -> [String: Int] {
        var stamp = 0.0
        for url in modelsFiles {
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                stamp = max(stamp, d.timeIntervalSince1970)
            }
        }
        if let c = windowSource, c.mtime == stamp { return c.map }

        var map = [String: Int]()
        for url in modelsFiles {
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            // models.json nests under "providers"; models-store.json is keyed by
            // provider id at the top level.
            let providers = (root["providers"] as? [String: Any]) ?? root
            for (prov, val) in providers {
                guard let p = val as? [String: Any], let models = p["models"] as? [[String: Any]] else { continue }
                for m in models {
                    guard let id = m["id"] as? String, let cw = num(m["contextWindow"]), cw > 0 else { continue }
                    map["\(prov)/\(id)"] = Int(cw)
                    if map[id] == nil { map[id] = Int(cw) }
                }
            }
        }
        windowSource = (stamp, map)
        return map
    }
}
