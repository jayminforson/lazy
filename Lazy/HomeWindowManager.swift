//
//  HomeWindowManager.swift
//  Clicky
//
//  The Home dashboard: a large borderless key panel centered on the mouse's
//  screen, inset so the gel card floats with its own shadow. Reveals with the
//  same top-anchored language as the notch sheet (scale + fade, spring).
//  Closes on Esc, the header ×, or a click outside.
//

import AppKit
import SwiftUI
import Combine

/// Borderless panel that can still become key (text fields in Home need it).
private class HomePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HomeWindowManager: ObservableObject {
    /// Published so HomeView's reveal animation can bind to it (mirrors the
    /// notch sheet's mount-collapsed-then-flip trick).
    @Published private(set) var isOpen = false

    /// Set by the app delegate: replays the welcome tour (Settings button).
    var onReplayTour: (() -> Void)?

    private let companionManager: CompanionManager
    private var panel: HomePanel?
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?

    private static let revealAnimationDuration: TimeInterval = 0.32

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Public API

    /// Opens Home (or re-focuses it if already open).
    func show() {
        if isOpen, let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            return
        }

        guard let targetScreen = homeScreen() else { return }

        let frame = homeFrame(on: targetScreen)

        if panel == nil {
            let newPanel = HomePanel(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            newPanel.level = .statusBar
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.hidesOnDeactivate = false
            newPanel.isReleasedWhenClosed = false
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.isExcludedFromWindowsMenu = true

            let hostingView = NSHostingView(
                rootView: HomeView(
                    companionManager: companionManager,
                    manager: self,
                    onReplayTour: { [weak self] in
                        self?.onReplayTour?()
                    }
                )
            )
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = NSRect(origin: .zero, size: frame.size)
            newPanel.contentView = hostingView
            panel = newPanel
        } else if let hostingView = panel?.contentView as? NSHostingView<HomeView> {
            hostingView.frame = NSRect(origin: .zero, size: frame.size)
        }

        // Home shouldn't fight the notch sheet for attention — dismiss the
        // menu-bar panel if it's up (same notification the sheet uses).
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        panel?.setFrame(frame, display: true)
        // Mount collapsed, order front, then flip isOpen next tick so the
        // reveal spring actually animates.
        isOpen = false
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKey()

        DispatchQueue.main.async { [weak self] in
            self?.isOpen = true
        }

        installDismissalMonitors()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeDismissalMonitors()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealAnimationDuration) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel?.orderOut(nil)
        }
    }

    // MARK: - Frame

    private func homeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    /// Near-full-screen dashboard: 92% × 86% of the screen, capped, centered.
    private func homeFrame(on screen: NSScreen) -> NSRect {
        let size = NSSize(
            width: min(screen.frame.width * 0.92, 1440),
            height: min(screen.frame.height * 0.86, 900)
        )
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Dismissal

    private func installDismissalMonitors() {
        removeDismissalMonitors()

        // Esc closes (only while Home is key).
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.close()
                }
                return nil
            }
            return event
        }

        // Click outside the card closes.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, self.isOpen else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.close()
                }
            }
        }
    }

    private func removeDismissalMonitors() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
