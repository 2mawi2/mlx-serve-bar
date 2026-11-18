import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config: AppConfig!
    var engine: MetricsEngine!
    var poller: Poller!
    var controller: ServerController!
    var status: StatusController!
    var rpc: RPCServer!
    var scanner: AgentScanner!
    private var agentTimer: Timer?
    private var healthMisses = 0
    private var backendProbes = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = AppConfig.load()
        Privacy.activeBackend = config.backend
        engine = MetricsEngine()
        engine.model.backend = config.backend
        controller = ServerController(config: config)
        status = StatusController(config: config, controller: controller, engine: engine)

        MetricsEngineStatic.snapshotProvider = { [weak self] in
            guard let self else { return nil }
            return self.engine.model.snap
        }

        poller = Poller(
            metricsURL: config.metricsURL,
            enableURL: config.metricsEnableURL,
            healthURL: config.healthURL)
        // sushi serves /metrics only on demand; ask once when the endpoint says so.
        poller.onMetricsDisabled = { [weak self] in
            guard let self else { return }
            if self.config.backend.metricsOptIn { self.poller.enableMetrics() }
        }
        poller.onResult = { [weak self] data, healthOK in
            guard let self else { return }
            if let data {
                self.healthMisses = 0
                if !self.controller.serving {
                    self.controller.serving = true
                    self.probeBackend()
                }
                self.engine.update(feed: data)
            } else if healthOK {
                // Healthy server but metrics timed out or are unavailable:
                // plateau the stats instead of flashing zeros/stopped.
                self.healthMisses = 0
                if !self.controller.serving {
                    self.controller.serving = true
                    self.probeBackend()
                }
                self.engine.updateStale()
            } else {
                self.healthMisses += 1
                if self.healthMisses >= 2 {
                    if self.controller.serving { self.controller.serving = false }
                    self.engine.update(feed: nil)
                }
            }
        }

        rpc = RPCServer(path: config.socketPath)
        rpc.handle = { [weak self] cmd in
            guard let self else { return "{}" }
            switch cmd.cmd {
            case "status":
                self.adopt(self.controller.detectExternal())
                return self.controller.statusJSON()
            case "start":
                self.adopt(self.controller.detectExternal())
                self.controller.start()
                return "{\"ok\":true,\"backend\":\"\(self.config.backend.rawValue)\"}"
            case "stop":
                self.controller.stop()
                return "{\"ok\":true}"
            case "rect":
                return self.status.statusRectJSON()
            case "panel":
                return "{\"visible\":\(self.status.panelVisible())}"
            case "events":
                return self.status.eventsJSON()
            case "agent":
                return self.scanner.scan().json()
            case "quit":
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return "{\"ok\":true,\"bye\":true}"
            case "privacy":
                return Privacy.load().json
            case "cache-clear":
                let removed = Privacy.clearCache()
                Privacy.load().save()   // create/normalise the conf on first use
                return "{\"removed\":\(removed),\"cache_mb\":\(Privacy.cacheMB()),\"cache_entries\":\(Privacy.cacheEntries())}"
            case let c where c.hasPrefix("privacy-set "):
                let parts = c.split(separator: " ")
                guard parts.count == 3 else { return "{\"error\":\"usage: privacy-set <key> <0|1>\"}" }
                let on = ["1", "true", "yes", "on"].contains(parts[2].lowercased())
                return Privacy.update(String(parts[1]), on)
            default:
                return "{\"error\":\"unknown cmd\"}"
            }
        }
        rpc.start()

        adopt(controller.detectExternal())
        controller.refreshState()
        engine.model.state = controller.state
        poller.start()

        // Agent-side stats: Pi transcripts, polled separately from the server
        // because they must keep working when the server is stopped or unreachable.
        scanner = AgentScanner()
        engine.model.agent = scanner.scan()
        agentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.engine.model.agent = self.scanner.scan()
        }
    }

    /// Adopt the backend of the server actually running (mlx-serve vs sushi),
    /// rewrite config.json so the power button launches the right launcher, and
    /// keep the menu-bar chrome in sync.
    private func adopt(_ detected: Backend?) {
        guard let b = detected else { return }
        let backendChanged = b != config.backend
        let launcherStale = Backend.infer(bin: config.bin, args: config.args) != b
        guard backendChanged || launcherStale else { return }
        config.backend = b
        Privacy.activeBackend = b
        engine.model.backend = b
        controller.backend = b
        if launcherStale {
            // A stale config.json may still point at the other flavor's launcher.
            let script = b.startScript
            if FileManager.default.isExecutableFile(atPath: script) {
                config.bin = script
                config.args = []
            }
        }
        controller.config = config
        config.save()
        status.refreshChrome()
        // splash serves /metrics, not /metrics.json: follow the backend.
        if poller.point(metrics: config.metricsURL, enable: config.metricsEnableURL,
                        health: config.healthURL) {
            engine.reset()
        }
        NSLog("mlx-bar: backend = \(b.rawValue) (\(config.bin))")
        if b.metricsOptIn { poller.enableMetrics() }
    }

    /// Fallback flavor detection for servers whose process line is hidden
    /// (e.g. launched by another wrapper): `/v1/models` advertises `owned_by`.
    private func probeBackend() {
        guard backendProbes < 3 else { return }
        backendProbes += 1
        guard let u = URL(string: config.modelsURL) else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.urlCache = nil
        URLSession(configuration: cfg).dataTask(with: u) { [weak self] data, resp, _ in
            guard let self, (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let b = Backend.detect(fromModelsJSON: data) else { return }
            DispatchQueue.main.async { self.adopt(b) }
        }.resume()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
