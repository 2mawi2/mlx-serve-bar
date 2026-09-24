import Foundation

enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "PASS " : "FAIL ") + name)
            if !ok { failures += 1 }
        }

        // panelAt: newest sample at least win old; oldest while warming up
        let S = { (t: Double, l: Double, p: Double, r: Double) in Sample(t: t, live: l, pre: p, req: r) }
        let samples = [S(0, 100, 0, 4), S(4, 200, 0, 5), S(8, 250, 0, 6)]
        check("panelAt 4s", MetricsMath.panelAt(8, samples, 4)?.t == 4)
        check("panelAt 60s (warming)", MetricsMath.panelAt(8, samples, 60)?.t == 0)
        check("panelAt 9s window", MetricsMath.panelAt(10, samples, 9)?.t == 0)

        // computeRates: live decode over 4s window
        var r = MetricsMath.computeRates(now: 8, samples: samples, running: 1,
                                         liveTok: 300, livePre: 0, prefilling: false,
                                         prefillTotal: 0, prefillSumSec: 0, reqTotal: 6)
        check("decode rate", abs(r.decodeTps - 25.0) < 0.001)

        // idle: running == 0 → decode 0 no matter what
        r = MetricsMath.computeRates(now: 8, samples: samples, running: 0,
                                     liveTok: 300, livePre: 0, prefilling: false,
                                     prefillTotal: 0, prefillSumSec: 0, reqTotal: 6)
        check("idle decode 0", r.decodeTps == 0)

        // prefill over 30s window
        let ps = [S(0, 0, 0, 0), S(30, 0, 4000, 0)]
        r = MetricsMath.computeRates(now: 30, samples: ps, running: 1,
                                     liveTok: 50, livePre: 9000, prefilling: true,
                                     prefillTotal: 0, prefillSumSec: 0, reqTotal: 0)
        check("prefill rate", abs(r.prefillTps - 300.0) < 0.001)
        check("prefilling flag", r.prefilling)

        // avg prefill = forwarded tokens ÷ prefill-seconds
        r = MetricsMath.computeRates(now: 1, samples: [S(0, 0, 0, 0)], running: 0,
                                     liveTok: 0, livePre: 0, prefilling: false,
                                     prefillTotal: 2_143_675, prefillSumSec: 1531.1, reqTotal: 0)
        check("avg prefill tps", abs(r.avgPrefillTps - 1400.0) < 1.0)

        // req/s over 60s window
        let rs = [S(0, 0, 0, 4)]
        r = MetricsMath.computeRates(now: 60, samples: rs, running: 0,
                                     liveTok: 0, livePre: 0, prefilling: false,
                                     prefillTotal: 0, prefillSumSec: 0, reqTotal: 10)
        check("req rate", abs(r.reqRate - 0.1) < 0.001)

        // tokenizer
        let toks = AppConfig.tokenize("/Users/x/.local/bin/mlx-serve --model /A/B --port 11234 --serve")
        check("tokenize count", toks.count == 6)
        check("tokenize bin", toks.first == "/Users/x/.local/bin/mlx-serve")

        // parse against a captured sample
        let sample = """
        {"counters":{"prompt_tokens_total":65779935,"prefill_tokens_total":1953465,
        "prefix_cache_tokens_total":63826470,"generation_tokens_total":469725,
        "requests_success_total":946,"requests_cancelled_total":2,
        "prefix_cache_queries_total":948,"prefix_cache_hits_total":891},
        "gauges":{"requests_running":1,"requests_waiting":0,"gpu_utilization_pct":89,
        "memory_mb":75088,"generation_tokens_live":469626,"prefill_tokens_live":0,
        "requests_prefilling":0},
        "histograms":{"time_to_first_token_seconds":{"count":946,"sum":1869.88},
        "e2e_request_latency_seconds":{"count":946,"sum":8243.65},
        "prefill_time_seconds":{"count":946,"sum":1820.07},
        "decode_time_seconds":{"count":946,"sum":6373.77},
        "prompt_tokens":{"count":946,"sum":65779935}}}
        """
        let engine = MetricsEngine()
        if let p = engine.parse(Data(sample.utf8)) {
            check("parse gen total", p.genTotal == 469725)
            check("parse live tok", p.liveTok == 469626)
            check("parse prefill live nil→0 handled", p.livePre == 0)
            check("parse cache pct", abs(p.cachePct - 93.987) < 0.01)
            check("parse tok reused pct", abs(p.tokPct - 97.03) < 0.01)
            check("parse ttft", abs(p.ttftMs - 1976.6) < 1.0)
            check("parse decode ms", abs(p.decodeMs - 6737.6) < 1.0)
            check("parse prefill sumsec", abs(p.prefillSumSec - 1820.07) < 0.01)
            check("parse mem", p.memMB == 75088)
        } else {
            check("parse sample", false)
        }

        // format port
        check("fmt K d0", Formats.fmt(2016, 0) == "2.0K")
        check("fmt plain d1", Formats.fmt(72.23) == "72.2")
        check("fmt K d0 big", Formats.fmt(465500, 0) == "465.5K")
        check("fmt M", Formats.fmt(2.2e6, 0) == "2.2M")
        check("fmt d2", Formats.fmt(0.12, 2) == "0.12")
        check("orDash", Formats.orDash(-1) == "—")
        check("dashInt round", Formats.dashInt(93.987) == "94")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        return failures == 0 ? 0 : 1
    }
}
