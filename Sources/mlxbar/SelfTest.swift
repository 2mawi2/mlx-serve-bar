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

        // backend detection: mlx-serve vs sushi
        check("backend mlx process", Backend.detect(fromCommand: "/Users/x/.local/bin/mlx-serve --serve --port 11234") == .mlxServe)
        check("backend sushi process", Backend.detect(fromCommand: "/Users/x/.local/bin/sushi serve --model /p --host 127.0.0.1 --port 11234") == .sushi)
        check("backend sushi wrapper", Backend.detect(fromCommand: "/bin/bash /Users/x/.local/bin/sushi-deepseek-start") == .sushi)
        check("backend infer config", Backend.infer(bin: "/Users/x/.local/bin/mlx-serve-start") == .mlxServe
              && Backend.infer(bin: "/Users/x/.local/bin/sushi-deepseek-start") == .sushi)
        check("backend metrics opt-in", Backend.sushi.metricsOptIn && !Backend.mlxServe.metricsOptIn)
        check("backend kv cache dir", Backend.sushi.kvCacheDir.path.hasSuffix("/.sushi/kv-cache"))
        check("backend symbol", Backend.sushi.symbolName == "fish")
        let models = "{\"data\":[{\"id\":\"beamster/DeepSeek-V4.1-Flash-1017-Sushi-STQ-1.75bpw\",\"owned_by\":\"sushi\"}]}"
        check("backend /v1/models", Backend.detect(fromModelsJSON: Data(models.utf8)) == .sushi)
        let legacy = "{\"bin\":\"/x/mlx-serve-start\",\"args\":[],\"host\":\"127.0.0.1\",\"port\":11234}"
        if let raw = try? JSONDecoder().decode(RawConfig.self, from: Data(legacy.utf8)) {
            check("config legacy backend", raw.backend == nil && Backend.infer(bin: raw.bin) == .mlxServe)
        }

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

        // inline bar readout (numbers pad to 5 cols for constant width)
        let row1 = BarTrend.row("D", 109.6, [40, 80, 109.6], BarTrend.decodeFloor)
        check("bar row text", row1.text.hasPrefix("D 110   ▰"))
        let row0 = BarTrend.row("", 109.6, [], BarTrend.decodeFloor)
        check("bar row no label", row0.text.hasPrefix("110   ▰"))
        check("bar pad constant width", BarTrend.row("", 0, [], BarTrend.decodeFloor).text.count ==
              BarTrend.row("", 23456, [], BarTrend.decodeFloor).text.count)
        check("bar pad 0.0", BarTrend.row("", 0.0, [], BarTrend.decodeFloor).text.hasPrefix("0.0   ▫"))
        check("bar pad 14K", BarTrend.row("", 14000, [], BarTrend.prefillFloor).text.hasPrefix("14.0K ▰"))
        check("bar row fills", BarTrend.filled(109.6, 109.6) == BarTrend.barCount)
        check("bar floor", BarTrend.filled(10, 100) == 1)
        check("bar zero", BarTrend.filled(0, 100) == 0)
        let row2 = BarTrend.row("P", 1400, [], BarTrend.prefillFloor)
        check("bar prefill floor scale", BarTrend.filled(1400, BarTrend.prefillFloor) == 4)

        // splash: process detection and Prometheus mapping
        let splashModels = """
        {"object":"list","data":[{"id":"local/flash","object":"model","owned_by":"splash",
          "context_length":262144}]}
        """
        check("backend splash engine process",
              Backend.detect(fromCommand: "/opt/homebrew/Cellar/splash/1.7.0/libexec/engine/splash serve-native /m 262144 auto") == .splash)
        check("backend splash python parent",
              Backend.detect(fromCommand: "/opt/homebrew/Cellar/splash/1.7.0/libexec/python/bin/python3 -u -P -m server.server /m/uuid --model local/flash --binary /opt/homebrew/Cellar/splash/1.7.0/libexec/engine/splash --port 11234 --serve-record /r.json --max-context=262144 --served-model-name=local/flash") == .splash)
        check("backend splash wrapper",
              Backend.detect(fromCommand: "/bin/bash /Users/x/.local/bin/splash-swap-start") == .splash)
        check("backend splash /v1/models", Backend.detect(fromModelsJSON: Data(splashModels.utf8)) == .splash)
        check("backend splash metrics path", Backend.splash.metricsPath == "/metrics"
              && Backend.mlxServe.metricsPath == "/metrics.json")
        check("backend splash no opt-in", !Backend.splash.metricsOptIn)
        check("backend splash kv ram-only", !Backend.splash.persistentKVCache
              && Backend.mlxServe.persistentKVCache)
        check("splash launcher picks wrapper",
              Backend.splash.startScript.hasSuffix("splash-swap-start")
              || Backend.splash.startScript.hasSuffix("/splash-start"))

        let prom = """
        # HELP splash_info Splash runtime metrics.
        # TYPE splash_info gauge
        splash_info{runtime="native"} 1
        splash_ready 1
        splash_frontend_active 2
        splash_frontend_waiting 1
        splash_scheduler_queued 3
        splash_scheduler_prefilling 1
        splash_scheduler_decoding 1
        splash_state_active_lanes 2
        splash_requests_completed_total 31
        splash_requests_submitted_total 31
        splash_decode_output_tokens_total 10754
        splash_prefill_input_tokens_total 84707
        splash_decode_wall_milliseconds_total 110367.8485
        splash_prefill_wall_milliseconds_total 42217.56829
        splash_http_ttft_seconds_sum 43.891204
        splash_http_ttft_seconds_count 31
        splash_http_request_seconds_sum 154.7066398
        splash_http_request_seconds_count 32
        splash_cache_hits_total 25
        splash_cache_cold_misses_total 6
        splash_cache_reused_tokens_total 375936
        splash_memory_current_bytes 87966908416
        splash_draft_acceptance_ratio 0.3711248893
        splash_thermal_state{state="nominal"} 0
        splash_thermal_state{state="fair"} 1
        """
        let series = PromSeries(PromParser.parse(prom))
        check("prom parses every line", series.samples.count == 25)
        check("prom label lookup", series.value("splash_thermal_state", "state", is: "fair") == 1)
        check("prom active state", series.activeState("splash_thermal_state") == "fair")
        check("prom counter sum", series.sum("splash_cache_hits_total") == 25)
        check("prom ignores comments", series.first("HELP") == nil)

        let sp = engine.parsePrometheus(Data(prom.utf8))
        check("splash gen total", sp?.genTotal == 10754)
        check("splash requests completed", sp?.reqTotal == 31 && sp?.reqSuccessInt == 31)
        check("splash cache hit", abs((sp?.cachePct ?? 0) - 80.645) < 0.01)
        check("splash tokens reused", abs((sp?.tokPct ?? 0) - 81.611) < 0.01)
        check("splash ttft ms", abs((sp?.ttftMs ?? 0) - 1415.8) < 0.5)
        check("splash e2e ms", abs((sp?.e2eMs ?? 0) - 4834.6) < 0.5)
        check("splash avg decode ms", abs((sp?.decodeMs ?? 0) - 3560.3) < 0.5)
        check("splash avg prefill tps", abs((sp?.prefillTotal ?? 0) / (sp?.prefillSumSec ?? 1) - 2006.4) < 0.5)
        check("splash memory MB", sp?.memMB == 87966)
        check("splash draft accept", abs((sp?.acceptPct ?? 0) - 37.11) < 0.01)
        check("splash running/waiting", sp?.runningInt == 2 && sp?.waitingInt == 4)
        check("splash activity gate", sp?.activeInt == 2)

        // Live shape of a single streaming splash request: the frontend gauge
        // stays 0, so "running" has to come from the scheduler/lanes.
        let streaming = """
        splash_info{runtime="native"} 1
        splash_transport_pending 1
        splash_frontend_active 0
        splash_state_active_lanes 1
        splash_scheduler_decoding 1
        splash_decode_output_tokens_total 75831
        """
        let live = engine.parsePrometheus(Data(streaming.utf8))
        check("splash running follows lanes", live?.runningInt == 1 && live?.activeInt == 1)
        check("splash idle reads zero",
              engine.parsePrometheus(Data("splash_info 1\nsplash_state_active_lanes 0\n".utf8))?.runningInt == 0)
        check("splash busy wall total", abs((sp?.wallMs ?? 0) - 152585.4) < 0.1)
        check("splash prefill is counter", sp?.prefillGaugeIsCounter == true
              && sp?.prefillDisplay == nil)
        check("feed sniffing picks prometheus", engine.parseFeed(Data(prom.utf8))?.acceptPct != nil)
        check("splash JSON is not prometheus", engine.parseFeed(Data(sample.utf8))?.acceptPct == -1)

        let ws = [(t: 0.0, wall: 100.0), (t: 4.0, wall: 300.0), (t: 6.0, wall: 350.0)]
        check("panelAtWall oldest-enough sample", MetricsMath.panelAtWall(6, ws, 4)?.t == 0)
        check("panelAtWall warming", MetricsMath.panelAtWall(5, [ws[0], ws[1]], 60)?.t == 0)

        // Pi agent sessions
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mlxbar-selftest-\(UUID().uuidString)")
        let agentDir = root.appendingPathComponent("agent")
        let sessDir = agentDir.appendingPathComponent("sessions/--Users-x-proj--")
        try? fm.createDirectory(at: sessDir, withIntermediateDirectories: true)
        try? Data("""
        {"providers":{"splash":{"models":[{"id":"local/flash","contextWindow":262144}]},
         "anthropic":{"models":[{"id":"claude-sonnet-4-5","contextWindow":200000}]}}}
        """.utf8).write(to: agentDir.appendingPathComponent("models.json"))
        let sessURL = sessDir.appendingPathComponent("2026-11-18T17-21-52-112Z_abc.jsonl")
        let firstLines = """
        {"type":"session","version":3,"id":"abc","timestamp":"2026-11-18T17:21:52.112Z","cwd":"/Users/x/proj"}
        {"type":"model_change","provider":"splash","modelId":"local/flash","timestamp":"2026-11-18T17:21:52.310Z"}
        {"type":"thinking_level_change","thinkingLevel":"xhigh","timestamp":"2026-11-18T17:21:52.311Z"}
        {"type":"session_info","name":"Adopt the bar","timestamp":"2026-11-18T17:21:52.312Z"}
        {"type":"message","message":{"role":"user","content":"hi"}}
        {"type":"message","message":{"role":"assistant","provider":"splash","model":"local/flash","thinkingLevel":"high","stopReason":"toolUse","durationMs":4000,"usage":{"input":100,"output":800,"cacheRead":20000,"cacheWrite":0,"reasoning":200,"totalTokens":20900,"cost":{"total":0}}}}
        {"type":"message","message":{"role":"toolResult","toolName":"bash","content":[{"type":"text","text":"super-secret-tool-output"}]}}
        {"type":"usage","kind":"cache_warm","usage":{"input":0,"output":0,"cacheRead":5000,"cacheWrite":0,"totalTokens":25900,"cost":{"total":0.02}}}
        """
        try? Data((firstLines + "\n").utf8).write(to: sessURL)
        let fixedNow = Date(timeIntervalSince1970: 1_763_500_000)
        try? fm.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-3)], ofItemAtPath: sessURL.path)

        let scanner = AgentScanner(agentDir: agentDir, now: { fixedNow })
        let snap = scanner.scan()
        check("agent sees one session", snap.sessions.count == 1)
        let a = snap.sessions.first
        check("agent title from session_info", a?.title == "Adopt the bar")
        check("agent cwd + model", a?.cwd == "/Users/x/proj" && a?.model == "local/flash"
              && a?.provider == "splash" && a?.thinking == "high")
        check("agent context window lookup", a?.ctxWindow == 262144)
        check("agent ctx tokens = last reply", a?.ctxTokens == 20900)
        check("agent ctx pct", abs((a?.ctxPct ?? 0) - 7.97) < 0.01)
        check("agent totals incl. usage entries", a?.cacheReadTokens == 25000 && a?.cost == 0.02)
        check("agent out tok/s from durationMs", abs((a?.outTps ?? 0) - 200.0) < 0.01)
        check("agent phase from last role", a?.phase(now: fixedNow) == "tool → request")
        check("agent working flag", a?.working(now: fixedNow) == true && snap.workingCount == 1)
        check("agent json hides transcript text", !snap.json().contains("super-secret-tool-output"))
        check("agent json carries model and ctx", snap.json().contains("\"model\":\"local/flash\"")
              && snap.json().contains("\"ctx_window\":262144"))

        // append-only transcript: the next tick must read only the new lines
        do {
            let h = try FileHandle(forWritingTo: sessURL)
            defer { try? h.close() }
            h.seekToEndOfFile()
            let appended = """
            {"type":"message","message":{"role":"assistant","provider":"splash","model":"local/flash","stopReason":"stop","durationMs":1000,"usage":{"input":50,"output":125,"cacheRead":21000,"cacheWrite":0,"totalTokens":21175,"cost":{"total":0}}}}
            """
            h.write(Data((appended + "\n").utf8))
        } catch { check("agent transcript appendable", false) }
        try? fm.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-1)], ofItemAtPath: sessURL.path)
        let snap2 = scanner.scan()
        let b = snap2.sessions.first
        check("agent incremental messages", b?.messages == 2)
        check("agent incremental tokens", b?.outputTokens == 925 && b?.ctxTokens == 21175)
        check("agent incremental phase", b?.phase(now: fixedNow) == "decoding")
        check("agent json totals", snap2.json().contains("\"sessions\":1") && snap2.json().contains("\"output\":925"))

        // stale sessions drop out of the panel entirely
        try? fm.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-3600)], ofItemAtPath: sessURL.path)
        check("agent forgets idle sessions", scanner.scan(now: fixedNow).sessions.isEmpty)
        try? fm.removeItem(at: root)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        return failures == 0 ? 0 : 1
    }
}
