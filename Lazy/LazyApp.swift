//
//  LazyApp.swift
//  Clicky
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct LazyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var homeWindowManager: HomeWindowManager?
    private var welcomeTourManager: WelcomeTourManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Lazy: Starting...")
        print("🎯 Lazy: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        LazyAnalytics.configure()
        LazyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)

        // Home dashboard: opened from the notch sheet header's house button.
        let home = HomeWindowManager(companionManager: companionManager)
        homeWindowManager = home
        companionManager.setNotchChatHomeHandler { [weak self] in
            // Close the chat sheet first — it floats above every window
            // level and would cover the dashboard.
            self?.companionManager.closeNotchChatSheet()
            self?.homeWindowManager?.show()
        }

        // Welcome tour: replayable from Home → Settings.
        let tour = WelcomeTourManager()
        welcomeTourManager = tour
        home.onReplayTour = { [weak self] in
            self?.welcomeTourManager?.show()
        }

        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }

        // First-run welcome tour: shows once, shortly after launch, once the
        // user is onboarded with permissions (onboarding owns first launch).
        if WelcomeTourManager.hasSeenTour == false && companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self,
                      WelcomeTourManager.hasSeenTour == false,
                      self.companionManager.hasCompletedOnboarding,
                      self.companionManager.allPermissionsGranted else { return }
                self.welcomeTourManager?.show()
            }
        }

        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Lazy: Registered as login item")
            } catch {
                print("⚠️ Lazy: Failed to register as login item: \(error)")
            }
        }
    }
}
