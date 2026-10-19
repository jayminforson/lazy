//
//  GuideStepOverlay.swift
//  Clicky
//
//  M4 B1 (amended — user decision: walkthrough shows ON SCREEN) — floating
//  step card for active [GUIDE:] walkthroughs. Visible while steps exist
//  and the notch sheet is CLOSED (the chat checklist card owns the surface
//  when the sheet is open). Bottom-center of the screen under the pointer,
//  repositioned on show and on every step advance.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class GuideStepOverlayManager {
    static let cardWidth: CGFloat = 440
    static let cardHeight: CGFloat = 132
    static let bottomInset: CGFloat = 20

    private weak var companionManager: CompanionManager?
    private weak var notchChatManager: NotchChatManager?
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(companionManager: CompanionManager, notchChatManager: NotchChatManager) {
        self.companionManager = companionManager
        self.notchChatManager = notchChatManager
    }

    /// Subscribes to the walkthrough + sheet state. Called once from
    /// `CompanionManager.start()`. Sinks inherit MainActor from init.
    func startObserving() {
        guard cancellables.isEmpty else { return }

        companionManager?.$activeGuideSteps
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        companionManager?.$activeGuideStepIndex
            .sink { [weak self] _ in
                guard let self, self.isShowing else { return }
                self.repositionPanel()
            }
            .store(in: &cancellables)

        notchChatManager?.$isSheetOpen
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)
    }

    private var isShowing: Bool {
        panel?.isVisible ?? false
    }

    private func refreshVisibility() {
        guard let companionManager else { return }
        let shouldShow = !companionManager.activeGuideSteps.isEmpty
            && !(notchChatManager?.isSheetOpen ?? false)
        if shouldShow {
            showPanel()
        } else {
            hidePanel()
        }
    }

    private func showPanel() {
        let panel = ensurePanel()
        repositionPanel()
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight),
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
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.isExcludedFromWindowsMenu = true
        newPanel.ignoresMouseEvents = false

        if let companionManager {
            let hostingView = NSHostingView(
                rootView: GuideStepCardView(companionManager: companionManager)
            )
            hostingView.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight)
            newPanel.contentView = hostingView
        }

        panel = newPanel
        return newPanel
    }

    /// Bottom-center of whichever screen contains the pointer — follows the
    /// user as they move between displays during a walkthrough.
    private func repositionPanel() {
        guard let panel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let targetScreen else { return }
        let visible = targetScreen.visibleFrame
        let frame = NSRect(
            x: visible.midX - Self.cardWidth / 2,
            y: visible.minY + Self.bottomInset,
            width: Self.cardWidth,
            height: Self.cardHeight
        )
        panel.setFrame(frame, display: true, animate: false)
    }
}

/// On-screen counterpart of the sheet's GuideWalkthroughCard: current step
/// only, compact header, same next/done button language. Taps speak the
/// outcome line via deliverGuideIntentAndSpeak (same beat as the voice
/// "next"/"done" pre-route).
private struct GuideStepCardView: View {
    @ObservedObject var companionManager: CompanionManager

    private var stepIndex: Int {
        guard !companionManager.activeGuideSteps.isEmpty else { return 0 }
        return min(companionManager.activeGuideStepIndex, companionManager.activeGuideSteps.count - 1)
    }

    private var isOnLastStep: Bool {
        companionManager.activeGuideStepIndex >= companionManager.activeGuideSteps.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("walkthrough")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(stepIndex + 1)/\(companionManager.activeGuideSteps.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if stepIndex < companionManager.activeGuideSteps.count {
                Text(companionManager.activeGuideSteps[stepIndex].text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    companionManager.deliverGuideIntentAndSpeak(.advance)
                } label: {
                    Text(isOnLastStep ? "last step" : "next")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isOnLastStep ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(isOnLastStep ? 0.04 : 0.10))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(isOnLastStep)

                Button {
                    companionManager.deliverGuideIntentAndSpeak(.finish)
                } label: {
                    Text("done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(DS.Colors.overlayCursorBlue.opacity(0.22))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(14)
        .frame(width: GuideStepOverlayManager.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.94))
                .shadow(color: Color.black.opacity(0.40), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}
