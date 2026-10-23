//
//  NotchChatManager.swift
//  leanring-buddy
//
//  Owns the HeyClicky-style notch chat: a small pill ("tap") hugging the
//  top-center screen edge that toggles a chat sheet springing down from
//  the top. The pill is a fake notch on non-notch Macs and lines up with
//  the real notch (safeAreaInsets) on notched MacBooks. Both windows join
//  all Spaces and float over fullscreen apps.
//

import AppKit
import Combine
import SwiftUI

/// NSPanel subclass so the borderless sheet can take keyboard focus for
/// the chat input (same trick as the menu bar panel's KeyablePanel).
private final class NotchKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension Notification.Name {
    /// Posted after the notch sheet finishes opening and becomes key —
    /// ChatView listens to grab input focus (its onAppear fires too early
    /// on first open and never again on reopens).
    static let clickyNotchSheetDidOpen = Notification.Name("clickyNotchSheetDidOpen")
}

@MainActor
final class NotchChatManager: ObservableObject {
    private let companionManager: CompanionManager

    private var pillPanel: NSPanel?
    private var sheetPanel: NotchKeyablePanel?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?
    /// M-notch-fix: space/app-activation tokens that re-front the pill/sheet —
    /// defends against the window server burying a statusBar-level panel of
    /// an accessory app after focus changes (the "only shows over the
    /// desktop" report).
    private var refrontObservers: [NSObjectProtocol] = []

    /// Drives the sheet's extrusion animation: the SwiftUI content scales
    /// from the notch (top-center anchor) to full size when this flips.
    /// Published so NotchChatSheetView re-renders and springs.
    @Published private(set) var isSheetOpen = false

    /// M8 — sheet body mode: false = chat (the default fresh draft),
    /// true = the Recents list. Reset to false on every open (openSheet)
    /// and on every row/new-chat tap back into a chat.
    @Published var showingRecents = false

    /// Set by the app delegate: opens the Home dashboard. The sheet header's
    /// house button calls through here.
    var onOpenHome: (() -> Void)?

    // Window chrome sizes
    private static let pillSize = NSSize(width: 128, height: 34)
    private static let sheetSize = NSSize(width: 420, height: 560)
    private static let sheetMaximumHeightAboveScreenBottom: CGFloat = 48
    /// How long the close-collapse spring takes before the panel is ordered
    /// out (must be longer than the spring's settle time).
    private static let closeAnimationDuration: TimeInterval = 0.45

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        observeScreenParameterChanges()
        observeNotchFrontingEvents()
    }

    deinit {
        // Monitors and observers are torn down on the main thread via
        // hidePill()/closeSheet(); this is a last-resort safety net.
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        for refrontObserver in refrontObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(refrontObserver)
        }
    }

    // MARK: - Public API

    func toggle() {
        if isSheetOpen {
            closeSheet()
        } else {
            openSheet()
        }
    }

    /// Shows or hides the pill. Hiding also closes the sheet — used when
    /// permissions are revoked or onboarding is replayed.
    func setPillVisible(_ isVisible: Bool) {
        if isVisible {
            showPill()
        } else {
            closeSheet()
            hidePill()
        }
    }

    // MARK: - Pill

    private func showPill() {
        if pillPanel == nil {
            let newPillPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.pillSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            // M-notch-fix: above .statusBar so neither the menu bar, another
            // app's status-level panels, nor our own Home/tour/guide panels
            // can ever cover the strip; ties with system menus (.popUpMenu),
            // where open order still decides — menus opened later stay on top.
            newPillPanel.level = .popUpMenu
            newPillPanel.isOpaque = false
            newPillPanel.backgroundColor = .clear
            newPillPanel.hasShadow = false
            newPillPanel.hidesOnDeactivate = false
            newPillPanel.isReleasedWhenClosed = false
            newPillPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            newPillPanel.isExcludedFromWindowsMenu = true

            let pillHostingView = NSHostingView(
                rootView: NotchPillView(
                    companionManager: companionManager,
                    notchChatManager: self,
                    onTap: { [weak self] in
                        self?.toggle()
                    },
                    onDwellComplete: { [weak self] in
                        // Dwell-to-peek: only opens — never toggles closed.
                        guard let self, !self.isSheetOpen else { return }
                        self.openSheet()
                    }
                )
            )
            pillHostingView.frame = NSRect(origin: .zero, size: Self.pillSize)
            newPillPanel.contentView = pillHostingView
            pillPanel = newPillPanel
        }
        repositionPill()
        pillPanel?.orderFrontRegardless()
    }

    private func hidePill() {
        pillPanel?.orderOut(nil)
    }

    private func repositionPill() {
        guard let pillPanel, let targetScreen = screenForNotchChat() else { return }
        let pillOrigin = NSPoint(
            x: targetScreen.frame.midX - Self.pillSize.width / 2,
            // Flush with the top edge so the pill reads as part of the
            // notch / menu bar strip.
            y: targetScreen.frame.maxY - Self.pillSize.height
        )
        pillPanel.setFrame(NSRect(origin: pillOrigin, size: Self.pillSize), display: true)
    }

    private func observeScreenParameterChanges() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPill()
            }
        }
    }

    /// M-notch-fix — re-front the notch windows whenever the Space changes
    /// or the user switches apps. Both are the moments macOS can leave an
    /// accessory app's panel behind the active app's windows (symptom:
    /// works over the desktop, buried over windows). Re-positioning also
    /// snaps the pill onto the screen the mouse is on, so a click on any
    /// monitor's notch hits a pill that's actually there.
    private func observeNotchFrontingEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        refrontObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refrontNotchWindows(reason: "space change")
            }
        })
        refrontObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refrontNotchWindows(reason: "app activation")
            }
        })
    }

    private func refrontNotchWindows(reason: String) {
        // Only re-front windows that are supposed to be visible — an
        // ordered-out pill (permissions revoked / onboarding video) must
        // never be resurrected by an observer.
        guard let pillPanel, pillPanel.isVisible else { return }
        repositionPill()
        if isSheetOpen, let sheetPanel, sheetPanel.isVisible {
            // Mirror openSheet's stacking: sheet first, then the pill so the
            // two read as one continuous notch strip.
            sheetPanel.orderFrontRegardless()
            pillPanel.orderFrontRegardless()
        } else {
            pillPanel.orderFrontRegardless()
        }
    }

    // MARK: - Sheet

    private func openSheet() {
        // If the user rearranged monitors since the last open, re-center.
        repositionPill()
        // Opening the sheet counts as reading — clear the suggestion badge.
        companionManager.proactiveEngine.markAllRead()
        // M8 — every open lands on a fresh chat: empty transcript, empty
        // brain memory; past chats live behind the Recents toggle.
        companionManager.beginFreshChat()
        showingRecents = false
        guard let targetScreen = screenForNotchChat() else { return }

        let fullFrame = sheetFrame(on: targetScreen)

        if sheetPanel == nil {
            let newSheetPanel = NotchKeyablePanel(
                contentRect: fullFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            // M-notch-fix: matches the pill's level — both must clear the
            // same ceiling (see pill note).
            newSheetPanel.level = .popUpMenu
            newSheetPanel.isOpaque = false
            newSheetPanel.backgroundColor = .clear
            newSheetPanel.hasShadow = false
            newSheetPanel.hidesOnDeactivate = false
            newSheetPanel.isReleasedWhenClosed = false
            newSheetPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            newSheetPanel.isExcludedFromWindowsMenu = true

            let sheetHostingView = NSHostingView(
                rootView: NotchChatSheetView(
                    notchChatManager: self,
                    companionManager: companionManager,
                    onOpenHome: { [weak self] in
                        self?.onOpenHome?()
                    },
                    onClose: { [weak self] in
                        self?.closeSheet()
                    }
                )
            )
            sheetHostingView.autoresizingMask = [.width, .height]
            sheetHostingView.frame = NSRect(origin: .zero, size: fullFrame.size)
            newSheetPanel.contentView = sheetHostingView
            sheetPanel = newSheetPanel
        } else if let sheetHostingView = sheetPanel?.contentView as? NSHostingView<NotchChatSheetView> {
            sheetHostingView.frame = NSRect(origin: .zero, size: fullFrame.size)
        }

        // Don't fight the menu bar panel for the same screen real estate.
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // The panel is always full-size — the sheet extrudes from the notch
        // via a top-anchored SwiftUI scale, not a frame animation. Mount the
        // content at its collapsed state first, then flip isSheetOpen on the
        // next runloop tick so the spring actually animates (a view that
        // mounts already-open renders instantly with no transition).
        isSheetOpen = false
        sheetPanel?.setFrame(fullFrame, display: true)
        sheetPanel?.orderFrontRegardless()
        // The sheet covers the same top-edge strip as the pill — bring the
        // pill back above it so the two read as one continuous notch.
        pillPanel?.orderFrontRegardless()
        LazyAnalytics.trackNotchChatOpened()

        installSheetDismissalMonitors()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSheetOpen = true
            // Take keyboard focus so the chat input works immediately.
            NSApp.activate(ignoringOtherApps: true)
            self.sheetPanel?.makeKey()
            NotificationCenter.default.post(name: .clickyNotchSheetDidOpen, object: nil)
        }
    }

    /// Internal (not private): the Home button's handler closes the sheet
    /// before opening the dashboard — the sheet floats above every window
    /// level and would otherwise cover Home.
    func closeSheet() {
        guard isSheetOpen, let sheetPanel else {
            removeSheetDismissalMonitors()
            isSheetOpen = false
            return
        }
        isSheetOpen = false
        removeSheetDismissalMonitors()

        // The SwiftUI content springs back into the notch; order the panel
        // out once the collapse has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeAnimationDuration) { [weak self] in
            guard let self, self.isSheetOpen == false else { return }
            self.sheetPanel?.orderOut(nil)
        }
    }

    // MARK: - Dismissal

    private func installSheetDismissalMonitors() {
        removeSheetDismissalMonitors()

        // Esc (local — the sheet is key when the user is typing in it).
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // escape
                self?.closeSheet()
                return nil // swallow so it doesn't leak to the focused field
            }
            return event
        }

        // Clicks in other apps (global — local monitors never see those).
        // Clicks on our own pill/sheet aren't delivered to global monitors,
        // so there's no self-dismiss risk.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeSheet()
            }
        }
    }

    private func removeSheetDismissalMonitors() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    // MARK: - Geometry

    /// The screen the notch chat targets: wherever the mouse is (so opening
    /// on a second monitor puts the notch there), falling back to the main
    /// screen.
    private func screenForNotchChat() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    private func sheetFrame(on screen: NSScreen) -> NSRect {
        let sheetHeight = min(
            Self.sheetSize.height,
            screen.visibleFrame.height - Self.sheetMaximumHeightAboveScreenBottom
        )
        let sheetSize = NSSize(width: Self.sheetSize.width, height: sheetHeight)
        let origin = NSPoint(
            x: screen.frame.midX - sheetSize.width / 2,
            y: screen.frame.maxY - sheetSize.height
        )
        return NSRect(origin: origin, size: sheetSize)
    }
}

// MARK: - Pill View

/// The "tap": a fake-notch pill flush with the top screen edge. Dark like
/// a real notch, bottom corners rounded, the Clicky eyes on the left (they
/// blink, glance, and track the pointer), and a status dot wrapped in the
/// hover-dwell ring on the right: green while listening (push-to-talk held),
/// yellow while a reply is generating or speaking (voice or typed), blue when
/// idle. Resting the pointer on the pill fills the ring and peeks the sheet.
private struct NotchPillView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var notchChatManager: NotchChatManager
    let onTap: () -> Void
    let onDwellComplete: () -> Void

    @StateObject private var dwell = NotchDwellController(duration: 0.6)

    private var statusDotColor: Color {
        switch companionManager.notchPillStatus {
        case .idle:
            return DS.Colors.overlayCursorBlue
        case .listening:
            return DS.Colors.success
        case .working:
            return DS.Colors.warning
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                NotchEyesPairView()

                Spacer(minLength: 0)

                // M3 unread-suggestion badge — sits left of the status dot;
                // cleared when the sheet or Home → Suggestions opens.
                if companionManager.unreadSuggestionCount > 0 {
                    Text(companionManager.unreadSuggestionCount > 99 ? "99+" : "\(companionManager.unreadSuggestionCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 16, minHeight: 14)
                        .background(Capsule().fill(DS.Colors.warning))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // Status dot; while dwelling, the progress ring grows around it.
                Group {
                    if dwell.progress > 0.001 {
                        NotchDwellRingView(progress: dwell.progress, dotColor: statusDotColor)
                    } else {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 6, height: 6)
                            .shadow(color: statusDotColor.opacity(0.7), radius: 3)
                            .frame(width: 20, height: 20)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: dwell.progress > 0.001)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(duration: 0.3), value: companionManager.unreadSuggestionCount)
            .background(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    style: .continuous
                )
                .fill(Color.black.opacity(0.92))
                .overlay(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: 12,
                        bottomTrailingRadius: 12,
                        style: .continuous
                    )
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            guard !notchChatManager.isSheetOpen else { return }
            if hovering {
                dwell.hoverBegan(onComplete: onDwellComplete)
            } else {
                dwell.hoverEnded()
            }
        }
        .onChange(of: notchChatManager.isSheetOpen) { _, isOpen in
            if isOpen { dwell.reset() }
        }
    }
}
