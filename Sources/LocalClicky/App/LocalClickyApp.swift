//
//  LocalClickyApp.swift
//  LocalClicky
//
//  Menu bar-only companion app — the fully-local build. No dock icon, no main
//  window, no cloud services, no analytics, no auto-updater phoning home. Just
//  an always-available status item; clicking it opens the floating panel with
//  the companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct LocalClickyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the
        // AppDelegate. This empty Settings scene satisfies SwiftUI's requirement
        // for at least one scene but is never shown (LSUIElement=true).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts the
/// companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🔵 LocalClicky: Starting...")
        print("🔵 LocalClicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()

        // Auto-open the panel on launch only if setup is still needed
        // (a permission hasn't been granted). Otherwise stay out of the way —
        // the first-run intro plays via the blue side-text beside the cursor.
        if !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        companionManager.refreshAllPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches on startup. Shows up in
    /// System Settings → General → Login Items so the user can turn it off.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
            } catch {
                print("⚠️ LocalClicky: failed to register as login item: \(error)")
            }
        }
    }
}
