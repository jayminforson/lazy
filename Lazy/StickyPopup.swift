//
//  StickyPopup.swift
//  Clicky
//
//  M6.7 — Lazy's StickyPopup (stickyboard.py) port: tapping a board row's
//  body opens a SECONDARY, TEMPORARY sticky near the click with the item's
//  full detail — bold subject + the whole note (for mail cards that is
//  From / Received / When: <date · time> / Join → link / summary), with
//  URLs rendered as short blue underlined labels that open the browser
//  (Lazy `_shorten_url` port). Same paper/handwriting aesthetic as the
//  board.
//
//  Faithful to the Python file: the note area fills the box and the popup
//  drags from ANYWHERE on its body — ✕ and link rects win the tap,
//  everything else starts the drag. Shadow is Lazy's popup value (blur 30 ·
//  x4 · y6 · 43 %), not the board's heavier one. ONE deliberate divergence
//  (M4.5d, user decision): long notes SCROLL instead of Lazy's hard clip at
//  the box bottom — the M4.5c second time line ("Your time (GMT): …") pushed
//  long summaries' tails out of view under the clip. Consequence: inside an
//  overflowing note a vertical drag scrolls it (the header bar is the drag
//  surface then); a non-overflowing note drags the popup as before.
//
//  Dismissal, Lazy verbatim: ✕ · any click outside (a transparent full-
//  screen overlay panel catches it — and, exactly like Lazy's overlay
//  widget, CONSUMES that first click, so the next click acts normally) ·
//  opening another popup replaces the current one. A quick second press on
//  the overlay at the same spot is routed to the board as a double-click →
//  the Edit dialog (see StickyBoardManager.handleOverlayPress), so rename
//  stays reachable even though the overlay eats the board's second click.
//
//  Layer: the board's shared widget level (M6.5b rule + the M6.9 +3 offset —
//  the popup can never cover windows, and it now also sits above Finder's
//  desktop window so neither board nor popup can be click-buried; Lazy's
//  floated over everything). Consequence:
//  a click on an app window doesn't reach us at this layer, so the popup
//  outlives it until ✕ or a desktop click — accepted divergence (recorded
//  in AGENTS.md). Popup geometry is NOT persisted (Lazy's wasn't either).
//

import AppKit
import SwiftUI

@MainActor
final class StickyPopupManager {

    private var popupPanel: NSPanel?
    private var overlayPanel: NSPanel?
    /// Popup-local grab point (AppKit, bottom-left) for header dragging —
    /// global-based so the frame stays glued to the mouse mid-drag.
    private var grabLocal: NSPoint?

    var isVisible: Bool { popupPanel != nil }

    /// Called when the transparent overlay catches a press (Lazy's
    /// `close_popup`). The board installs this to distinguish a quick second
    /// press (double-click → rename) from a plain dismiss. When nil, an
    /// overlay press just closes the popup.
    var onOutsidePress: (() -> Void)?

    // Lazy StickyPopup geometry (stickyboard.py: resize(420, 280)).
    static let popupWidth: CGFloat = 420
    static let popupHeight: CGFloat = 280

    /// Lazy `_show_popup`: close any existing popup, open a fresh one at
    /// click +12 / −40, clamped into the usable screen.
    func show(title: String, note: String, clickPoint: NSPoint) {
        close()
        let screen = NSScreen.screens.first { $0.frame.contains(clickPoint) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let vis = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let popupH = max(200, min(Self.popupHeight, vis.height - 16))

        // Qt py = click.y − 40 → AppKit top = click.y + 40 (y flipped);
        // clamp both axes to the visible frame, same 8 pt margins as Lazy.
        var top = min(clickPoint.y + 40, vis.maxY - 8)
        top = max(top, vis.minY + popupH + 8)
        let originX = min(max(clickPoint.x + 12, vis.minX + 8),
                          vis.maxX - Self.popupWidth - 8)
        let frame = NSRect(x: originX, y: top - popupH,
                           width: Self.popupWidth, height: popupH)

        // Click-catcher first, popup ordered after → popup sits ABOVE the
        // overlay at the same level; the board (also same level) sits below
        // both, so the first board click dismisses exactly like Lazy.
        let overlay = NSPanel(contentRect: vis,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        Self.configure(overlay)
        overlay.contentView = NSHostingView(
            rootView: StickyPopupOverlayView { [weak self] in
                guard let self else { return }
                if let onOutsidePress {
                    onOutsidePress()
                } else {
                    close()
                }
            }
        )
        overlay.orderFrontRegardless()
        overlayPanel = overlay

        let popup = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        Self.configure(popup)
        popup.contentView = NSHostingView(
            rootView: StickyPopupView(title: title, note: note,
                                      height: popupH, manager: self)
        )
        popup.setFrame(frame, display: true)
        popup.orderFrontRegardless()
        popupPanel = popup
    }

    func close() {
        popupPanel?.orderOut(nil)
        popupPanel = nil
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        grabLocal = nil
    }

    /// The board re-fronts on app activation/show — at this shared level,
    /// later order wins, so lift the overlay + popup back above it.
    func refrontOverBoard() {
        guard isVisible else { return }
        overlayPanel?.orderFrontRegardless()
        popupPanel?.orderFrontRegardless()
    }

    /// Header dragging — anchor on the first change, then track the real
    /// mouse in global coordinates (immune to the window moving mid-drag).
    func dragChanged(location: NSPoint, viewHeight: CGFloat) {
        if grabLocal == nil {
            grabLocal = NSPoint(x: location.x, y: viewHeight - location.y)
        }
        guard let grab = grabLocal, let panel = popupPanel else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
    }

    func dragEnded() {
        grabLocal = nil
    }

    private static func configure(_ panel: NSPanel) {
        panel.level = StickyBoardManager.desktopIconLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // shadow painted in SwiftUI (board does the same)
    }
}

// MARK: - Click-catcher (Lazy's transparent overlay widget)

struct StickyPopupOverlayView: View {
    var onOutsideClick: () -> Void

    var body: some View {
        // ~1 % visible, fully hit-testable — consumes the first click.
        Color.white
            .opacity(0.01)
            .contentShape(Rectangle())
            .onTapGesture { onOutsideClick() }
    }
}

// MARK: - The temporary sticky itself

struct StickyPopupView: View {
    let title: String
    let note: String
    let height: CGFloat
    let manager: StickyPopupManager

    // Palette mirrors the board's file-private hexes (same family look).
    private let paper = Color(red: 254.0 / 255.0, green: 243.0 / 255.0, blue: 167.0 / 255.0)
    private let paperEdge = Color(red: 227.0 / 255.0, green: 203.0 / 255.0, blue: 98.0 / 255.0)
    private let rule = Color(red: 216.0 / 255.0, green: 195.0 / 255.0, blue: 106.0 / 255.0)
    private let pencil = Color(red: 63.0 / 255.0, green: 63.0 / 255.0, blue: 70.0 / 255.0)
    private let pencilSoft = Color(red: 120.0 / 255.0, green: 113.0 / 255.0, blue: 108.0 / 255.0)
    private let linkBlue = Color(red: 29.0 / 255.0, green: 78.0 / 255.0, blue: 216.0 / 255.0)

    var body: some View {
        VStack(spacing: 0) {
            // Title bar — bold subject + ✕.
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(StickyBoardManager.handFont(20))
                    .fontWeight(.bold)
                    .foregroundColor(pencil)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    manager.close()
                } label: {
                    Text("✕")
                        .font(StickyBoardManager.handFont(20))
                        .foregroundColor(pencilSoft)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 44, alignment: .top)

            Rectangle()
                .fill(rule)
                .frame(height: 1)
                .padding(.horizontal, 12)

            // Full note — links clickable. Scrolls when the note overflows
            // (M4.5d user decision; M6.8's Lazy clip hid the tail of long
            // summaries once M4.5c added the second time line).
            ScrollView {
                Text(Self.attributedNote(note, pencil: pencil, linkBlue: linkBlue))
                    .font(StickyBoardManager.handFont(17))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: StickyPopupManager.popupWidth, height: height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(paper)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(paperEdge, lineWidth: 1.4)
                )
        )
        // Lazy's popup shadow: QGraphicsDropShadowEffect(blur 30, x 4, y 6,
        // alpha 110/255 ≈ 0.43) — distinct from the board's heavier shadow.
        .shadow(color: .black.opacity(0.43), radius: 30, x: 4, y: 6)
        .contentShape(Rectangle())
        // Drag from ANYWHERE on the body (Lazy checks ✕ / link rects first,
        // then starts the drag). minimumDistance keeps a stationary ✕/link
        // tap from becoming a drag.
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    manager.dragChanged(location: value.location, viewHeight: height)
                }
                .onEnded { _ in manager.dragEnded() }
        )
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url) ? .handled : .discarded
        })
    }

    // MARK: Note → attributed text (Lazy: URLs split out, shortened, blue)

    /// Splits each line into text runs (pencil) and URL runs rendered as
    /// short labels carrying the link attribute SwiftUI turns into a tap
    /// (blue + underlined, Lazy's look).
    static func attributedNote(_ note: String, pencil: Color, linkBlue: Color) -> AttributedString {
        var result = AttributedString()
        guard let urlRegex = try? NSRegularExpression(pattern: #"(https?://\S+)"#) else {
            return AttributedString(note)
        }
        let lines = note.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            let nsLine = String(line)
            let ns = NSRange(nsLine.startIndex..., in: nsLine)
            var cursor = nsLine.startIndex
            for match in urlRegex.matches(in: nsLine, options: [], range: ns) {
                guard let range = Range(match.range, in: nsLine) else { continue }
                if cursor < range.lowerBound {
                    appendRun(String(nsLine[cursor..<range.lowerBound]), into: &result, color: pencil)
                }
                appendLink(String(nsLine[range]), into: &result, blue: linkBlue)
                cursor = range.upperBound
            }
            if cursor < nsLine.endIndex {
                appendRun(String(nsLine[cursor...]), into: &result, color: pencil)
            }
        }
        return result
    }

    private static func appendRun(_ text: String, into result: inout AttributedString, color: Color) {
        guard !text.isEmpty else { return }
        var run = AttributedString(text)
        let range = run.startIndex..<run.endIndex
        run[range].foregroundColor = color
        result.append(run)
    }

    private static func appendLink(_ rawURL: String, into result: inout AttributedString, blue: Color) {
        var run = AttributedString(shortLabel(for: rawURL))
        let range = run.startIndex..<run.endIndex
        if let url = URL(string: rawURL) {
            run[range].link = url
        }
        run[range].underlineStyle = .single
        run[range].foregroundColor = blue
        result.append(run)
    }

    /// Lazy `_shorten_url` port: "zoom.us/j/42" style labels — host minus
    /// "www." plus the last path segment when it is ≤30 chars.
    static func shortLabel(for rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              let host = components.host,
              !host.isEmpty else {
            return String(rawURL.prefix(40))
        }
        let hostPart = host.replacingOccurrences(of: "www.", with: "")
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.isEmpty {
            let last = path.split(separator: "/").last.map(String.init) ?? ""
            if !last.isEmpty, last.count <= 30 {
                return "\(hostPart)/\(last)"
            }
        }
        return hostPart
    }
}
