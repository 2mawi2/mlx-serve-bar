import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config: AppConfig!
    var engine: MetricsEngine!
    var poller: Poller!
    var controller: ServerController!
    var status: StatusController!
    var rpc: RPCServer!
    private var healthMisses = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = AppConfig.load()
        engine = MetricsEngine()
        controller = ServerController(config: config)
        status = StatusController(config: config, controller: controller, engine: engine)

        MetricsEngineStatic.snapshotProvider = { [weak self] in
            guard let self else { return nil }
            return self.engine.model.snap
        }

        poller = Poller(
            metricsURL: config.baseURL + "/metrics.json",
            healthURL: config.baseURL + "/health")
        poller.onResult = { [weak self] data, healthOK in
            guard let self else { return }
            if let data {
                self.healthMisses = 0
                if !self.controller.serving { self.controller.serving = true }
                self.engine.update(json: data)
            } else if healthOK {
                // Healthy server but metrics timed out or are unavailable:
                // plateau the stats instead of flashing zeros/stopped.
                self.healthMisses = 0
                if !self.controller.serving { self.controller.serving = true }
                self.engine.updateStale()
            } else {
                self.healthMisses += 1
                if self.healthMisses >= 2 {
                    if self.controller.serving { self.controller.serving = false }
                    self.engine.update(json: nil)
                }
            }
        }

        rpc = RPCServer(path: config.socketPath)
        rpc.handle = { [weak self] cmd in
            guard let self else { return "{}" }
            switch cmd.cmd {
            case "status":
                self.controller.detectExternal()
                return self.controller.statusJSON()
            case "start":
                self.controller.start()
                return "{\"ok\":true}"
            case "stop":
                self.controller.stop()
                return "{\"ok\":true}"
            case "rect":
                return self.status.statusRectJSON()
            case "panel":
                return "{\"visible\":\(self.status.panelVisible())}"
            case "events":
                return self.status.eventsJSON()
            case "quit":
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return "{\"ok\":true,\"bye\":true}"
            default:
                return "{\"error\":\"unknown cmd\"}"
            }
        }
        rpc.start()

        controller.detectExternal()
        controller.refreshState()
        engine.model.state = controller.state
        poller.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
