import AppKit
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var windows: WindowCoordinator!
    private var status: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        var migrationError: String?
        do { try LegacyMigration.perform() } catch { migrationError = "Eski kurulum geçişi tamamlanamadı: \(error.localizedDescription)" }
        model = AppModel()
        if let migrationError { model.integrationMessage = migrationError }
        windows = WindowCoordinator(model: model)
        model.start()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "refik")
        let menu = NSMenu()
        menu.addItem(withTitle: "Maskotu göster/gizle", action: #selector(toggleVisibility), keyEquivalent: "")
        menu.addItem(withTitle: "Durum paneli", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ayarlar…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Konumu sıfırla", action: #selector(resetPosition), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "refik'ten çık", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status.menu = menu
        UNUserNotificationCenter.current().delegate = self
        windows.showFirstLaunchIfNeeded()
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    @objc private func toggleVisibility() { windows.toggleVisibility() }
    @objc private func showPanel() { windows.showPanel() }
    @objc private func showSettings() { windows.showSettings() }
    @objc private func resetPosition() { windows.resetPosition() }
    @objc private func quit() { NSApp.terminate(nil) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        DispatchQueue.main.async {
            if self.model.preferences.hidden { self.model.preferences.hidden = false }
            self.windows.showPanel(targetSessionID: sessionID)
            completionHandler()
        }
    }
}

@main struct refikMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
