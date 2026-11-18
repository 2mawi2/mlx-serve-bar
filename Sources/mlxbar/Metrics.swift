import Foundation
import Combine

enum ServerState: String {
    case unknown, stopped, loading, running, stopping
}

struct MetricsSnapshot {
    var serving = false
    var decode = 0.0          // live decode tok/s (0 when not decoding)
    var prefill = 0.0         // live prefill tok/s (0 when not prefilling)
    var reqPerSec = -1.0      // -1 ⇒ null (dash shows —)
    var decodeMs = -1.0
    var prefillMs = -1.0
    var avgPrefillTps = -1.0
    var prefilling = false
    var livePre = 0.0
    var liveTok = 0.0
    var ttftMs = -1.0
    var e2eMs = -1.0
    var cachePct = -1.0
    var tokPct = -1.0
    var cacheHits = 0
    var cacheQueries = 0
    var gpuPct = 0
    var memMB = 0
    var acceptPct = -1.0      // speculative-decoding draft acceptance (splash only)
    var generated = 0
    var running = 0
    var waiting = 0
    var reqSuccess = 0
}

final class MetricsModel: ObservableObject {
    @Published var snap = MetricsSnapshot()
    @Published var decodeHist: [Double] = []
    @Published var prefillHist: [Double] = []
    @Published var state: ServerState = .unknown
    @Published var backend: Backend = .mlxServe
    /// Pi sessions on this machine (see AgentStats.swift).
    @Published var agent = AgentSnapshot()
}

// Mirror of the mlx-serve dashboard panel math: live phase speeds derived from
// gauges as Δtokens ÷ Δtime over trailing windows, re-derived from the current
// feed every tick — no carry-forward, no smoothing.
struct Sample {
    var t: Double      // seconds
    var live: Double   // generation_tokens_live
    var pre: Double    // prefill_tokens_live
    var req: Double    // requests_success_total
}

struct RatesResult {
    var decodeTps = 0.0
    var prefillTps = 0.0
    var avgPrefillTps = -1.0
    var reqRate = -1.0
    var prefilling = false
    var liveTok = 0.0
    var livePre = 0.0
}

enum MetricsMath {
    // Newest sample that is at least win old; oldest retained while warming up.
    static func panelAt(_ now: Double, _ samples: [Sample], _ win: Double) -> Sample? {
        guard var s = samples.first else { return nil }
        for x in samples {
            if now - x.t >= win { s = x } else { break }
        }
        return s
    }

    // Same rule for the (t, wall-ms) series that backs splash's busy %.
    static func panelAtWall(_ now: Double, _ samples: [(t: Double, wall: Double)], _ win: Double)
        -> (t: Double, wall: Double)? {
        guard var s = samples.first else { return nil }
        for x in samples {
            if now - x.t >= win { s = x } else { break }
        }
        return s
    }

    static func computeRates(now: Double, samples: [Sample], running: Int,
                             liveTok: Double, livePre: Double, prefilling: Bool,
                             prefillTotal: Double, prefillSumSec: Double,
                             reqTotal: Double) -> RatesResult {
        var r = RatesResult()
        r.liveTok = liveTok
        r.livePre = livePre
        r.prefilling = prefilling

        if running > 0 {
            if let wl = panelAt(now, samples, 4) {
                let dt = now - wl.t
                if dt > 0 { r.decodeTps = max(0, (liveTok - wl.live) / dt) }
            }
        }
        if livePre > 0 {
            if let wl = panelAt(now, samples, 30) {
                let dt = now - wl.t
                if dt > 0 { r.prefillTps = max(0, (livePre - wl.pre) / dt) }
            }
        }
        if prefillSumSec > 1e-6 && prefillTotal > 0 {
            r.avgPrefillTps = prefillTotal / prefillSumSec
        }
        if let wl = panelAt(now, samples, 60) {
            let dt = now - wl.t
            if dt > 0 { r.reqRate = max(0, (reqTotal - wl.req) / dt) }
        }
        return r
    }
}

final class MetricsEngine {
    let model = MetricsModel()

    private var samples: [Sample] = []
    private var wallSamples: [(t: Double, wall: Double)] = []
    private var lastGenTotal = -1.0
    private let retainSec = 120.0
    private let sparkN = 60

    /// Either feed, dashboard JSON or Prometheus text: the format is sniffed from
    /// the body, so swapping mlx-serve for splash on the same port keeps
    /// rendering immediately instead of waiting for config.json to be rewritten.
    func parseFeed(_ data: Data) -> Parsed? {
        let head = String(decoding: Array(data.prefix(512)), as: UTF8.self)
        if head.hasPrefix("# HELP") || head.hasPrefix("splash_") || head.contains("\nsplash_") {
            return parsePrometheus(data)
        }
        return parse(data)
    }

    // Must run on the main thread.
    func update(feed: Data?) {
        var s = model.snap
        if let feed, let d = parseFeed(feed) {
            // Server restart clears the window (like reloading the dashboard page).
            if lastGenTotal >= 0 && d.genTotal < lastGenTotal { samples.removeAll(); wallSamples.removeAll() }
            lastGenTotal = d.genTotal

            let now = Date().timeIntervalSince1970
            let liveTok = d.liveTok ?? d.genTotal
            let livePre = d.livePre ?? 0
            samples.append(Sample(t: now, live: liveTok, pre: livePre, req: d.reqTotal))
            while samples.count > 2, now - samples[0].t > retainSec { samples.removeFirst() }

            let r = MetricsMath.computeRates(now: now, samples: samples, running: d.activeInt,
                                             liveTok: liveTok, livePre: livePre,
                                             prefilling: d.requestsPrefilling,
                                             prefillTotal: d.prefillTotal,
                                             prefillSumSec: d.prefillSumSec,
                                             reqTotal: d.reqTotal)

            s.serving = true
            s.decode = r.decodeTps
            // A backend whose prefill number is a lifetime counter (splash) has no
            // "not prefilling" state in that number, so the dashboard's "0 unless
            // prefilling" rule is applied to the derived rate instead.
            s.prefill = (d.prefillGaugeIsCounter && !r.prefilling) ? 0 : r.prefillTps
            s.reqPerSec = r.reqRate
            s.avgPrefillTps = r.avgPrefillTps
            s.prefilling = r.prefilling
            // splash has no per-request prefill gauge: its counter feeds the rate
            // window, but there is no "tokens so far in this request" to display.
            s.livePre = d.prefillDisplay ?? 0
            s.liveTok = r.liveTok
            s.decodeMs = d.decodeMs
            s.prefillMs = d.prefillMs
            s.ttftMs = d.ttftMs
            s.e2eMs = d.e2eMs
            s.cachePct = d.cachePct
            s.tokPct = d.tokPct
            s.cacheHits = d.cacheHits
            s.cacheQueries = d.cacheQueries
            if d.wallMs >= 0 {
                // No utilization gauge (splash): GPU busy = GPU wall time spent
                // (decode + prefill) ÷ elapsed, over the same trailing window as
                // decode so the bar and the tok/s number agree.
                wallSamples.append((t: now, wall: d.wallMs))
                while wallSamples.count > 2, now - wallSamples[0].t > retainSec { wallSamples.removeFirst() }
                if let w = MetricsMath.panelAtWall(now, wallSamples, 4) {
                    let dt = now - w.t
                    if dt > 0 {
                        let pct = (d.wallMs - w.wall) / (dt * 1000) * 100
                        s.gpuPct = Int(min(100.0, max(0.0, pct)).rounded())
                    }
                } else {
                    s.gpuPct = 0
                }
            } else {
                wallSamples.removeAll()
                s.gpuPct = d.gpuPct
            }
            s.acceptPct = d.acceptPct
            s.memMB = d.memMB
            s.generated = d.reqSuccessInt   // replaced by liveTok below for display
            s.liveTok = liveTok
            s.running = d.runningInt
            s.waiting = d.waitingInt
            s.reqSuccess = d.reqSuccessInt

            var dh = model.decodeHist, ph = model.prefillHist
            dh.append(r.decodeTps); if dh.count > sparkN { dh.removeFirst(dh.count - sparkN) }
            ph.append(r.prefillTps); if ph.count > sparkN { ph.removeFirst(ph.count - sparkN) }
            model.snap = s
            model.decodeHist = dh
            model.prefillHist = ph
        } else {
            s.serving = false
            s.decode = 0; s.prefill = 0
            samples.removeAll()
            wallSamples.removeAll()
            lastGenTotal = -1
            model.snap = s
            model.decodeHist = []
            model.prefillHist = []
        }
    }

    // Poll failed but health answered: keep the last frame, freeze the chart.
    func updateStale() {
        var s = model.snap
        s.serving = true
        model.snap = s
    }

    struct Parsed {
        var genTotal = 0.0
        var liveTok: Double?
        var livePre: Double?
        /// Per-request prefill tokens in flight, when the backend reports one
        /// (nil for splash, whose prefill number is a lifetime counter).
        var prefillDisplay: Double?
        /// True when livePre is a monotonically growing counter rather than a
        /// per-request gauge that returns to 0 between requests.
        var prefillGaugeIsCounter = false
        var requestsPrefilling = false
        var reqTotal = 0.0
        var prefillTotal = 0.0
        var prefillSumSec = 0.0
        var decodeMs = -1.0
        var prefillMs = -1.0
        var ttftMs = -1.0
        var e2eMs = -1.0
        var cachePct = -1.0
        var tokPct = -1.0
        var cacheHits = 0
        var cacheQueries = 0
        var gpuPct = 0
        var wallMs = -1.0       // cumulative GPU wall ms; ≥0 ⇒ derive busy % from it
        var acceptPct = -1.0
        var memMB = 0
        var reqSuccessInt = 0
        var runningInt = 0
        var waitingInt = 0
        /// Gate for "still generating": some backends only report activity in a
        /// scheduler gauge, not in the running-request gauge.
        var activeInt = 0
    }

    func parse(_ data: Data) -> Parsed? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let c = obj["counters"] as? [String: Any] ?? [:]
        let g = obj["gauges"] as? [String: Any] ?? [:]
        let h = obj["histograms"] as? [String: Any] ?? [:]
        guard !c.isEmpty || !g.isEmpty else { return nil }

        func ci(_ d: [String: Any], _ k: String) -> Int {
            if let i = d[k] as? Int { return i }
            if let f = d[k] as? Double { return Int(f) }
            return 0
        }
        func cf(_ d: [String: Any], _ k: String) -> Double? {
            if let f = d[k] as? Double { return f }
            if let i = d[k] as? Int { return Double(i) }
            return nil
        }

        var p = Parsed()
        p.genTotal = cf(c, "generation_tokens_total") ?? 0
        p.liveTok = cf(g, "generation_tokens_live")
        p.livePre = cf(g, "prefill_tokens_live")
        p.prefillDisplay = p.livePre
        p.requestsPrefilling = ci(g, "requests_prefilling") > 0
        p.reqTotal = cf(c, "requests_success_total") ?? 0
        p.prefillTotal = cf(c, "prefill_tokens_total") ?? 0
        p.prefillSumSec = histSum(h["prefill_time_seconds"])
        p.decodeMs = histAvgMs(h["decode_time_seconds"])
        p.prefillMs = histAvgMs(h["prefill_time_seconds"])
        p.ttftMs = histAvgMs(h["time_to_first_token_seconds"])
        p.e2eMs = histAvgMs(h["e2e_request_latency_seconds"])
        p.cacheHits = ci(c, "prefix_cache_hits_total")
        p.cacheQueries = ci(c, "prefix_cache_queries_total")
        if p.cacheQueries > 0 { p.cachePct = Double(p.cacheHits) / Double(p.cacheQueries) * 100 }
        let tokTotal = cf(c, "prompt_tokens_total") ?? 0
        let cacheTok = cf(c, "prefix_cache_tokens_total") ?? 0
        if tokTotal > 0 { p.tokPct = cacheTok / tokTotal * 100 }
        p.gpuPct = ci(g, "gpu_utilization_pct")
        p.memMB = ci(g, "memory_mb")
        p.reqSuccessInt = ci(c, "requests_success_total")
        p.runningInt = ci(g, "requests_running")
        p.waitingInt = ci(g, "requests_waiting")
        p.activeInt = p.runningInt
        return p
    }

    /// splash publishes Prometheus text only, under its own metric names. Map onto
    /// the dashboard's panel fields:
    ///
    ///   splash_decode_output_tokens_total        → generation tokens (window Δ ⇒ live tok/s)
    ///   splash_prefill_input_tokens_total        → *forwarded* prefill tokens, never cached ones
    ///   splash_scheduler_prefilling / _decoding  → prefilling flag, activity gate
    ///   splash_frontend_active / _waiting        → running / waiting (see note below)
    ///   splash_requests_completed_total          → req/s window + per-request averages
    ///   splash_{decode,prefill}_wall_milliseconds_total → avg decode/prefill ms, GPU busy
    ///   splash_http_ttft_seconds_{sum,count}     → avg time to first token
    ///   splash_http_request_seconds_{sum,count}  → avg end-to-end latency
    ///   splash_cache_hits_total ÷ (hits + cold_misses)              → cache hit rate
    ///   splash_cache_reused_tokens_total ÷ (reused + forwarded)      → % of prompt tokens reused
    ///   splash_memory_current_bytes              → resident footprint
    ///   splash_draft_acceptance_ratio            → speculative-decoding acceptance
    ///
    /// Two honest gaps: splash has no "tokens generated so far in this request"
    /// gauge, so decode is the counter delta over the window rather than a
    /// mid-request value, and it has no utilization gauge, so busy % comes from
    /// GPU wall time.
    func parsePrometheus(_ data: Data) -> Parsed? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let series = PromSeries(PromParser.parse(text))
        guard series.has("splash_info") || series.has("splash_decode_output_tokens_total") else { return nil }

        func d(_ n: String) -> Double? { series.sum(n) }

        var p = Parsed()
        p.genTotal = d("splash_decode_output_tokens_total") ?? 0
        p.liveTok = p.genTotal
        let pre = d("splash_prefill_input_tokens_total") ?? 0
        p.livePre = pre
        p.prefillGaugeIsCounter = true
        p.requestsPrefilling = (d("splash_scheduler_prefilling") ?? 0) > 0
        p.reqTotal = d("splash_requests_completed_total") ?? 0
        p.prefillTotal = pre
        p.prefillSumSec = (d("splash_prefill_wall_milliseconds_total") ?? 0) / 1000
        let done = d("splash_requests_completed_total") ?? 0
        p.decodeMs = done > 0 ? (d("splash_decode_wall_milliseconds_total") ?? 0) / done : -1
        p.prefillMs = done > 0 ? (d("splash_prefill_wall_milliseconds_total") ?? 0) / done : -1
        p.ttftMs = ratioMs(d("splash_http_ttft_seconds_sum"), d("splash_http_ttft_seconds_count"))
        p.e2eMs = ratioMs(d("splash_http_request_seconds_sum"), d("splash_http_request_seconds_count"))
        p.cacheHits = Int(d("splash_cache_hits_total") ?? 0)
        p.cacheQueries = p.cacheHits + Int(d("splash_cache_cold_misses_total") ?? 0)
        if p.cacheQueries > 0 { p.cachePct = Double(p.cacheHits) / Double(p.cacheQueries) * 100 }
        let reused = d("splash_cache_reused_tokens_total") ?? 0
        if reused + pre > 0 { p.tokPct = reused / (reused + pre) * 100 }
        p.wallMs = (d("splash_decode_wall_milliseconds_total") ?? 0)
            + (d("splash_prefill_wall_milliseconds_total") ?? 0)
        if let ratio = d("splash_draft_acceptance_ratio") { p.acceptPct = ratio * 100 }
        p.memMB = Int((d("splash_memory_current_bytes") ?? 0) / 1_000_000)
        p.reqSuccessInt = Int(done)
        // `splash_frontend_active` counts admission-queue slots, not in-flight
        // generations — it reads 0 while a request streams (verified live). The
        // lanes/scheduler gauges are what actually mean "a request is running".
        p.runningInt = max(Int(d("splash_state_active_lanes") ?? 0),
                           Int((d("splash_scheduler_decoding") ?? 0)
                               + (d("splash_scheduler_prefilling") ?? 0)),
                           Int(d("splash_frontend_active") ?? 0))
        p.waitingInt = Int(d("splash_frontend_waiting") ?? 0)
            + Int(d("splash_scheduler_queued") ?? 0)
            + Int(d("splash_admission_waiting_concurrency") ?? 0)
        p.activeInt = max(p.runningInt, Int(d("splash_transport_pending") ?? 0))
        return p
    }

    /// sum ÷ count of a Prometheus histogram, in ms; -1 ⇒ nothing measured yet.
    private func ratioMs(_ sum: Double?, _ count: Double?) -> Double {
        guard let s = sum, let c = count, c > 0 else { return -1 }
        return s / c * 1000
    }

    private func histSum(_ v: Any?) -> Double {
        (v as? [String: Any])?["sum"] as? Double ?? 0
    }

    private func histAvgMs(_ v: Any?) -> Double {
        guard let d = v as? [String: Any], let sum = d["sum"] as? Double,
              let count = d["count"] as? Double, count > 0 else { return -1 }
        return sum / count * 1000
    }
}

final class Poller {
    private var timer: Timer?
    private var url: URL
    private var enableURL: URL
    private var healthURL: URL
    private let session: URLSession
    var onResult: ((Data?, Bool) -> Void)?
    /// Metrics endpoint answered "metrics not enabled" (sushi without --metrics).
    var onMetricsDisabled: (() -> Void)?
    private var enableInFlight = false
    private var lastEnableAt = Date.distantPast

    init(metricsURL: String, enableURL: String, healthURL: String) {
        self.url = URL(string: metricsURL)!
        self.enableURL = URL(string: enableURL)!
        self.healthURL = URL(string: healthURL)!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.5
        cfg.timeoutIntervalForResource = 3.0
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    func start(interval: TimeInterval = 1.0) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Re-point the poller after adopting a different backend (splash serves
    /// `/metrics`, the others `/metrics.json`). Returns true when the endpoint
    /// actually changed, so the caller can drop the rate windows.
    @discardableResult
    func point(metrics: String, enable: String, health: String) -> Bool {
        guard let m = URL(string: metrics), let e = URL(string: enable), let h = URL(string: health) else { return false }
        guard m != url || e != enableURL || h != healthURL else { return false }
        url = m; enableURL = e; healthURL = h
        timer?.invalidate()
        start()
        return true
    }

    func tick() {
        session.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // sushi without --metrics: plain-text "metrics not enabled" body.
            let disabled = code != -1 && body.localizedCaseInsensitiveContains("metrics not enabled")
            if code == 200, let data, !disabled {
                DispatchQueue.main.async { self.onResult?(data, true) }
                return
            }
            self.session.dataTask(with: self.healthURL) { _, r2, _ in
                let c2 = (r2 as? HTTPURLResponse)?.statusCode ?? -1
                DispatchQueue.main.async {
                    if disabled { self.onMetricsDisabled?() }
                    self.onResult?(nil, c2 == 200)
                }
            }.resume()
        }.resume()
    }

    /// POST /metrics/enable (sushi only). Idempotent; throttled so a stopped
    /// server doesn't get hammered every tick.
    func enableMetrics() {
        guard !enableInFlight, Date().timeIntervalSince(lastEnableAt) > 2 else { return }
        enableInFlight = true
        lastEnableAt = Date()
        var req = URLRequest(url: enableURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        session.dataTask(with: req) { [weak self] _, resp, _ in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            DispatchQueue.main.async {
                self.enableInFlight = false
                NSLog("mlx-bar: metrics enable → HTTP \(code)")
            }
        }.resume()
    }
}

extension MetricsEngine {
    /// Forget the rate windows: used when the polled endpoint changes, so a rate
    /// is never computed across two different servers (same rule as a restart).
    func reset() {
        samples.removeAll()
        wallSamples.removeAll()
        lastGenTotal = -1
    }
}

// MARK: - Prometheus text exposition

struct PromSample {
    let name: String
    let labels: [String: String]
    let value: Double
}

/// Minimal reader for the Prometheus text format: `name{k="v",…} 1.23 [ts]`,
/// comments and blank lines skipped. Deliberately small — the splash panel is all
/// plain gauges and counters, with at most a `state`/`account` label — so it does
/// not pull a dependency in for a handful of series.
enum PromParser {
    static func parse(_ text: String) -> [PromSample] {
        var out: [PromSample] = []
        out.reserveCapacity(512)
        for raw in text.split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let head = line[line.startIndex..<sep]
            let rest = line[line.index(after: sep)...]
            guard let valueText = rest.split(separator: " ").first, let value = Double(valueText)
            else { continue }
            var name = Substring(head), labels: [String: String] = [:]
            if let brace = head.firstIndex(of: "{") {
                name = head[head.startIndex..<brace]
                let inner = head[head.index(after: brace)...]
                let closing = inner.lastIndex(of: "}") ?? inner.endIndex
                labels = parseLabels(inner[inner.startIndex..<closing])
            }
            out.append(PromSample(name: String(name), labels: labels, value: value))
        }
        return out
    }

    /// `a="1",b="with, comma"` → dictionary. Quotes and escaped quotes respected.
    private static func parseLabels(_ s: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", val = "", inValue = false, inQuote = false, escaped = false
        var i = s.startIndex
        func flush() {
            if !key.isEmpty { out[key] = val }
            key = ""; val = ""; inValue = false; inQuote = false
        }
        while i < s.endIndex {
            let c = s[i]
            if escaped { val.append(c); escaped = false; i = s.index(after: i); continue }
            switch c {
            case "\\" where inQuote: escaped = true
            case "\"" where !escaped: inQuote.toggle()
            case "=" where !inQuote: inValue = true
            case "," where !inQuote:
                if inValue { flush() }
            default:
                if inValue { val.append(c) } else if c != " " { key.append(c) }
            }
            i = s.index(after: i)
        }
        if !key.isEmpty { out[key] = val }
        return out
    }
}

/// Lookup over a parsed scrape. `sum` folds the label variants of one metric
/// together, which is what counters like `splash_cache_hits_total{…}` want.
struct PromSeries {
    let samples: [PromSample]

    init(_ samples: [PromSample]) { self.samples = samples }

    func has(_ name: String) -> Bool { samples.contains { $0.name == name } }

    func sum(_ name: String) -> Double? {
        var found = false, total = 0.0
        for s in samples where s.name == name { found = true; total += s.value }
        return found ? total : nil
    }

    func first(_ name: String) -> Double? { samples.first { $0.name == name }?.value }

    /// The series of `name` whose `label` equals `value` (splash's state gauges:
    /// `splash_thermal_state{state="fair"} 1`).
    func value(_ name: String, _ label: String, is: String) -> Double? {
        samples.first { $0.name == name && $0.labels[label] == `is` }?.value
    }

    /// Name of the active state among `name{state="…"}` gauges, i.e. the one set to 1.
    func activeState(_ name: String, label: String = "state") -> String? {
        samples.first { $0.name == name && $0.value != 0 }?.labels[label]
    }
}
