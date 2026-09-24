import Foundation
import ServiceManagement

enum LoginItem {
    static var supported: Bool { Bundle.main.bundleIdentifier != nil }

    static var enabled: Bool {
        guard supported else { return false }
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func toggle() {
        guard supported else { return }
        if #available(macOS 13, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {
                NSLog("mlx-bar: login item error: \(error)")
            }
        }
    }
}
