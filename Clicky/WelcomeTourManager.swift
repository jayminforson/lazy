//
//  WelcomeTourManager.swift
//  Clicky
//
//  Manages the first-run welcome tour: a dimmed full-screen overlay with a
//  four-beat card (notch → hotkey → Home → done). Auto-shows once after
//  onboarding; "Replay the welcome tour" in Home → Settings shows it again.
//  Original copy; structure mirrors the reference's tour beats.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class WelcomeTourManager: ObservableObject {
    static let seenDefaultsKey = "clickyWelcomeTourSeen"
    static let beatCount = 4

    @Published private(set) var isShowing = false
    @Published var beatIndex = 0

    private var panel: NSPanel?

    var isLastBeat: Bool { beatIndex >= Self.beatCount - 1 }

    /// One-time first-run check used by the app delegate.
    static var hasSeenTour: Bool {
        UserDefaults.standard.bool(forKey: seenDefaultsKey)
    }

    // MARK: - Public API

    func show() {
        beatIndex = 0

        guard let targetScreen = tourScreen() else { return }

        if panel == nil {
            let newPanel = TourPanel(
                contentRect: targetScreen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
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
                rootView: WelcomeTourView(manager: self)
            )
            hostingView.autoresizingMask = [.width, .height]
            newPanel.contentView = hostingView
            panel = newPanel
        }

        panel?.setFrame(targetScreen.frame, display: true)

        // Mount collapsed, order front, flip next tick — same reveal trick
        // as the notch sheet so the card springs in.
        isShowing = false
        panel?.orderFrontRegardless()

        DispatchQueue.main.async { [weak self] in
            self?.isShowing = true
        }
    }

    func advance() {
        if isLastBeat {
            finish()
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                beatIndex += 1
            }
        }
    }

    func skip() {
        finish()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenDefaultsKey)
        close()
    }

    private func close() {
        guard isShowing else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            isShowing = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, !self.isShowing else { return }
            self.panel?.orderOut(nil)
        }
    }

    // MARK: - Screen

    private func tourScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }
}

/// Transparent fullscreen overlay; clicks on the dimmed area are swallowed
/// (the card handles its own buttons).
private final class TourPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
