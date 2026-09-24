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
    private var lastGenTotal = -1.0
    private let retainSec = 120.0
    private let sparkN = 60

    // Must run on the main thread.
    func update(json: Data?) {
        var s = model.snap
        if let json, let d = parse(json) {
            // Server restart clears the window (like reloading the dashboard page).
            if lastGenTotal >= 0 && d.genTotal < lastGenTotal { samples.removeAll() }
            lastGenTotal = d.genTotal

            let now = Date().timeIntervalSince1970
            let liveTok = d.liveTok ?? d.genTotal
            let livePre = d.livePre ?? 0
            samples.append(Sample(t: now, live: liveTok, pre: livePre, req: d.reqTotal))
            while samples.count > 2, now - samples[0].t > retainSec { samples.removeFirst() }

            let r = MetricsMath.computeRates(now: now, samples: samples, running: d.runningInt,
                                             liveTok: liveTok, livePre: livePre,
                                             prefilling: d.requestsPrefilling,
                                             prefillTotal: d.prefillTotal,
                                             prefillSumSec: d.prefillSumSec,
                                             reqTotal: d.reqTotal)

            s.serving = true
            s.decode = r.decodeTps
            s.prefill = r.prefillTps
            s.reqPerSec = r.reqRate
            s.avgPrefillTps = r.avgPrefillTps
            s.prefilling = r.prefilling
            s.livePre = r.livePre
            s.liveTok = r.liveTok
            s.decodeMs = d.decodeMs
            s.prefillMs = d.prefillMs
            s.ttftMs = d.ttftMs
            s.e2eMs = d.e2eMs
            s.cachePct = d.cachePct
            s.tokPct = d.tokPct
            s.cacheHits = d.cacheHits
            s.cacheQueries = d.cacheQueries
            s.gpuPct = d.gpuPct
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
        var memMB = 0
        var reqSuccessInt = 0
        var runningInt = 0
        var waitingInt = 0
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
        return p
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
    private let url: URL
    private let healthURL: URL
    private let session: URLSession
    var onResult: ((Data?, Bool) -> Void)?

    init(metricsURL: String, healthURL: String) {
        self.url = URL(string: metricsURL)!
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

    func tick() {
        session.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200, let data {
                DispatchQueue.main.async { self.onResult?(data, true) }
                return
            }
            self.session.dataTask(with: self.healthURL) { _, r2, _ in
                let c2 = (r2 as? HTTPURLResponse)?.statusCode ?? -1
                DispatchQueue.main.async { self.onResult?(nil, c2 == 200) }
            }.resume()
        }.resume()
    }
}
