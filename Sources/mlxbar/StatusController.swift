import AppKit
import SwiftUI
import Combine

final class StatusController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let item: NSStatusItem
    private let button: NSStatusBarButton
    private let popover = NSPopover()
    private let config: AppConfig
    private let controller: ServerController
    private let engine: MetricsEngine

    private var menuOpen = false
    private var menu: NSMenu!
    private var privacyItems: [String: NSMenuItem] = [:]
    private var uiEvents: [String] = []
    private var cancellables = Set<AnyCancellable>()

    init(config: AppConfig, controller: ServerController, engine: MetricsEngine) {
        self.config = config
        self.controller = controller
        self.engine = engine
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        button = item.button!
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        let root = DashboardView(
            model: engine.model,
            host: config.host, port: config.port,
            onStart: { [weak self] in self?.controller.start() },
            onStop: { [weak self] in self?.controller.stop() },
            onQuit: { NSApp.terminate(nil) },
            onDashboard: { NSWorkspace.shared.open(URL(string: self.config.dashboardURL)!) }
        )
        let host = NSHostingController(rootView: root)
        host.view.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = host

        button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "mlx-serve")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildMenu()
        engine.model.$snap
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        controller.onStateChange = { [weak self] state in
            self?.engine.model.state = state
            self?.updateIcon()
        }

        // Close the popover when clicking anywhere outside of it.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            if self.popover.isShown, !(self.popover.contentViewController?.view.window?.frame ?? .null).contains(loc) {
                self.popover.performClose(nil)
            }
        }
        updateIcon()
    }

    private func note(_ s: String) {
        uiEvents.append("\(Date().timeIntervalSince1970) \(s)")
        if uiEvents.count > 40 { uiEvents.removeFirst(uiEvents.count - 40) }
        NSLog("mlx-bar: \(s)")
    }

    private func updateIcon() {
        let s = engine.model.state
        let base = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "mlx-serve")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        switch s {
        case .running, .stopped, .unknown:
            // Template image ⇒ menu bar renders white on dark / black on light automatically.
            base?.isTemplate = true
            button.image = base
        case .loading, .stopping:
            if let img = base?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 1)])) {
                img.isTemplate = false
                button.image = img
            }
        }
        menu.items.first?.title = (s == .running) ? "Stop mlx-serve" : "Start mlx-serve"
        menu.items.first?.isEnabled = s != .loading && s != .stopping
    }

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(title: "Start mlx-serve", action: #selector(toggleServer), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let dash = NSMenuItem(title: "Open Dashboard…", action: #selector(openDashboard), keyEquivalent: "")
        dash.target = self
        menu.addItem(dash)
        let log = NSMenuItem(title: "Open Server Log…", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        let cfg = NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: "")
        cfg.target = self
        menu.addItem(cfg)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.enabled ? .on : .off
        menu.addItem(login)

        // Privacy: what these write is exactly what the pi wrapper and mlx-serve launchers read.
        let privacy = NSMenuItem(title: "Privacy", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = Privacy.load()
        for spec in Privacy.keys {
            let item = NSMenuItem(title: spec.label, action: #selector(togglePrivacy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec.key
            item.toolTip = spec.hint
            item.state = (current.value(spec.key) ?? false) ? .on : .off
            privacyItems[spec.key] = item
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let reveal = NSMenuItem(title: "Reveal KV Cache in Finder", action: #selector(revealCache), keyEquivalent: "")
        reveal.target = self
        sub.addItem(reveal)
        let clear = NSMenuItem(title: "Clear KV Cache…", action: #selector(clearCache), keyEquivalent: "")
        clear.target = self
        clear.toolTip = "Delete persisted prompt-derived KV state (best done with the server stopped)"
        sub.addItem(clear)
        privacy.submenu = sub
        menu.addItem(privacy)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MLX Bar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - clicks

    @objc private func clicked(_ sender: Any?) {
        let t = NSApp.currentEvent?.type
        let kind = (t == .rightMouseUp) ? "right" : "left"
        note("clicked \(kind) shown=\(popover.isShown)")
        if t == .rightMouseUp {
            if popover.isShown { popover.performClose(nil) }
            menuOpen = true
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            menuOpen = false
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func toggleServer() {
        if controller.state == .running { controller.stop() } else { controller.start() }
    }
    @objc private func openDashboard() { NSWorkspace.shared.open(URL(string: config.dashboardURL)!) }
    @objc private func openLog() { NSWorkspace.shared.open(config.serverLogURL) }
    @objc private func openConfig() { NSWorkspace.shared.open(config.fileURL) }
    @objc private func toggleLogin() {
        LoginItem.toggle()
        menu.items.first(where: { $0.title == "Launch at Login" })?.state = LoginItem.enabled ? .on : .off
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - privacy

    @objc private func togglePrivacy(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let newValue = sender.state != .on
        var p = Privacy.load()
        guard p.set(key, newValue) else { return }
        p.save()
        sender.state = newValue ? .on : .off
        note("privacy \(key)=\(newValue ? 1 : 0)")
    }

    @objc private func revealCache() {
        let dir = Privacy.cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @objc private func clearCache() {
        let mb = Privacy.cacheMB()
        let entries = Privacy.cacheEntries()
        let alert = NSAlert()
        alert.messageText = "Clear the on-disk KV cache?"
        alert.informativeText = "\(entries) persisted entries, \(mb) MB. They hold prompt-derived state for faster warm starts and are rewritten on demand. Best done with the server stopped."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = Privacy.clearCache()
        note("kv-cache cleared: \(removed) entries, was \(mb) MB")
        let done = NSAlert()
        done.messageText = "Removed \(removed) cache entries"
        done.informativeText = "KV cache is now \(Privacy.cacheMB()) MB."
        done.runModal()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if popover.isShown { popover.performClose(nil) }
        let p = Privacy.load()
        for (key, item) in privacyItems { item.state = (p.value(key) ?? false) ? .on : .off }
        if let clear = menu.item(withTitle: "Privacy")?.submenu?.item(withTitle: "Clear KV Cache…") {
            clear.title = "Clear KV Cache (\(Privacy.cacheMB()) MB)…"
        }
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: - diagnostics for selftests

    func statusRectJSON() -> String {
        guard let win = button.window, let screen = win.screen else { return "{\"error\":\"no button window\"}" }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        let sh = screen.frame.height
        return "{\"x\":\(r.midX),\"y\":\(r.midY),\"cg_x\":\(r.midX),\"cg_y\":\(sh - r.midY),\"screen_h\":\(sh)}"
    }

    func panelVisible() -> Bool { popover.isShown }

    func eventsJSON() -> String {
        "[" + uiEvents.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}
