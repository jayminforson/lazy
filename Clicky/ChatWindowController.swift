//
//  ChatWindowController.swift
//  leanring-buddy
//
//  Owns the floating chat window: typed messages, a scrollable transcript,
//  and a live-streaming assistant bubble. Unlike the menu bar panel (which
//  is non-activating), this is a regular window so the text input can take
//  keyboard focus normally.
//

import AppKit
import SwiftUI

@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    private static let persistedWindowFrameDefaultsKey = "clickyChatWindowFrame"
    private static let defaultWindowSize = NSSize(width: 380, height: 560)

    init(companionManager: CompanionManager) {
        let chatView = ChatView(companionManager: companionManager)
        let hostingView = NSHostingView(rootView: chatView)

        let chatWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        chatWindow.title = "Lazy Chat"
        chatWindow.titleVisibility = .hidden
        chatWindow.titlebarAppearsTransparent = true
        // The app is dark-only — force the titlebar to match the content so
        // there's no light chrome strip at the top of the window.
        chatWindow.appearance = NSAppearance(named: .darkAqua)
        // Matches DS.Colors.background (#101211) so the window looks opaque
        // even behind the rounded SwiftUI content.
        chatWindow.backgroundColor = NSColor(
            red: 0x10 / 255.0,
            green: 0x12 / 255.0,
            blue: 0x11 / 255.0,
            alpha: 1.0
        )
        chatWindow.contentView = hostingView
        // Keep the window alive when the user closes it so reopening is
        // instant and the transcript state is preserved.
        chatWindow.isReleasedWhenClosed = false
        // Float above most windows (like the menu bar panel) without going
        // over the fullscreen menu bar.
        chatWindow.level = .floating
        chatWindow.collectionBehavior = [.moveToActiveSpace]

        super.init(window: chatWindow)
        chatWindow.delegate = self
        restorePreviousFrameOrCenter(chatWindow)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the chat window, activating the app so the input field can
    /// receive keystrokes immediately.
    func showChatWindow() {
        guard let chatWindow = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        chatWindow.makeKeyAndOrderFront(nil)
    }

    // MARK: - Frame Persistence

    private func restorePreviousFrameOrCenter(_ chatWindow: NSWindow) {
        if let frameString = UserDefaults.standard.string(forKey: Self.persistedWindowFrameDefaultsKey) {
            let restoredFrame = NSRectFromString(frameString)
            if restoredFrame.width > 0, restoredFrame.height > 0 {
                chatWindow.setFrame(restoredFrame, display: false)
                return
            }
        }
        // First launch: default size, centered on the screen the mouse is on.
        if let screenWithMouse = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main {
            let visibleFrame = screenWithMouse.visibleFrame
            let origin = NSPoint(
                x: visibleFrame.midX - Self.defaultWindowSize.width / 2,
                y: visibleFrame.midY - Self.defaultWindowSize.height / 2
            )
            chatWindow.setFrame(NSRect(origin: origin, size: Self.defaultWindowSize), display: false)
        } else {
            chatWindow.center()
        }
    }

    func windowDidMove(_ notification: Notification) {
        persistCurrentFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistCurrentFrame()
    }

    private func persistCurrentFrame() {
        guard let chatWindow = window, chatWindow.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(chatWindow.frame), forKey: Self.persistedWindowFrameDefaultsKey)
    }
}
