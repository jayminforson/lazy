//
//  StickyBoardManager.swift
//  Clicky
//
//  M6.3 — the sticky board: a tilted handwritten note pasted on the
//  desktop, ported from Lazy's Phase 9 Qt board (app/ui/stickyboard.py)
//  onto NSPanel + SwiftUI. Warm ruled paper (#FEF3A7), tape strip, Patrick
//  Hand handwriting (bundled OFL font — see NOTICE.md), wobbly hand-drawn
//  checkboxes, pencil strikethrough animation, red hand-drawn check, hover
//  ✕, right-click snooze/delete, "+ add something…" line, drag + geometry
//  persistence, 14 items/board with paging, visible across Spaces.
//
//  Items = open todos + reminders (open/snoozed) + board-worthy mail cards
//  (materialized as reminders by MailManager.mailToBoard). Completed items
//  stay crossed-out for the session (Lazy's done_session), gone next launch.
//

import AppKit
import Combine
import CoreText
import SwiftUI

// MARK: - Item model

struct StickyItem: Identifiable, Equatable {
    enum Kind: String { case todo, reminder }

    let kind: Kind
    let rowID: Int64
    var title: String
    var note: String
    var dueAt: Date?
    var done: Bool

    var id: String { "\(kind.rawValue):\(rowID)" }
}

// MARK: - Natural-due parsing (shared by the board add line + chat intents)

enum NaturalDueParser {

    /// Small deterministic phrase set: "at 5pm" / "at 5:30 pm" / "at 18:30" /
    /// "in 10 minutes" / "in 2 hours" / "tomorrow" / "tomorrow at 9am".
    /// Returns nil when no time is present (caller decides todo vs reminder).
    static func parse(_ text: String, now: Date = Date()) -> Date? {
        let lower = text.lowercased()
        let calendar = Calendar.current

        // "in N minutes/hours"
        if let range = lower.range(of: #"\bin (\d+)\s?(minute|minutes|min|hour|hours|hr|hrs)\b"#, options: .regularExpression) {
            let digits = String(lower[range]).filter { $0.isNumber }
            if let amount = Int(digits) {
                let slice = String(lower[range])
                let unit: TimeInterval = (slice.contains("hour") || slice.contains("hr")) ? 3600 : 60
                return now.addingTimeInterval(TimeInterval(amount) * unit)
            }
        }

        var base = now
        var timePart = lower
        let mentionsTomorrow = lower.contains("tomorrow")
        if mentionsTomorrow, let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            base = tomorrow
            timePart = lower.replacingOccurrences(of: "tomorrow", with: " ")
        }

        // "h[:mm] am/pm" or 24-hour "h:mm"
        let patterns = [#"\b(\d{1,2})(?::(\d{2}))?\s?(am|pm)\b"#, #"\b(\d{1,2}):(\d{2})\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: timePart, options: [], range: NSRange(timePart.startIndex..., in: timePart)),
                  let hourRange = Range(match.range(at: 1), in: timePart),
                  let hour = Int(timePart[hourRange])
            else { continue }
            let minute: Int
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
               let minuteRange = Range(match.range(at: 2), in: timePart) {
                minute = Int(timePart[minuteRange]) ?? 0
            } else {
                minute = 0
            }
            var meridiem: String?
            if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
               let meridiemRange = Range(match.range(at: 3), in: timePart) {
                meridiem = String(timePart[meridiemRange])
            }
            var components = calendar.dateComponents([.year, .month, .day], from: base)
            var resolvedHour = hour
            if let meridiem {
                if meridiem == "pm", hour < 12 { resolvedHour = hour + 12 }
                if meridiem == "am", hour == 12 { resolvedHour = 0 }
            } else if hour > 23 || minute > 59 {
                continue
            }
            components.hour = resolvedHour
            components.minute = minute
            if let date = calendar.date(from: components), date > now || mentionsTomorrow {
                return date
            }
        }

        // Bare "tomorrow" → 9:00 AM.
        if mentionsTomorrow {
            var components = calendar.dateComponents([.year, .month, .day], from: base)
            components.hour = 9
            components.minute = 0
            return calendar.date(from: components)
        }
        return nil
    }
}

// MARK: - Manager

@MainActor
final class StickyBoardManager: ObservableObject {

    static let maxItemsPerBoard = 14
    static let handFontName = "Patrick Hand"
    static let handFontSize: CGFloat = 20

    private static let geometryDefaultsKey = "clickyStickyBoardGeometry"
    private static let defaultSize = NSSize(width: 310 + (20 - 14) * 8, height: 400 + (20 - 14) * 12)

    @Published private(set) var items: [StickyItem] = []
    @Published private(set) var boardCount = 1
    @Published var boardIndex = 0
    @Published var flashItemID: String?
    @Published private(set) var isBoardShown = false

    private let mailManager: MailManager
    private var panel: NSPanel?
    private var dataObserver: NSObjectProtocol?
    private var finderObserver: NSObjectProtocol?
    private var popupManager: StickyPopupManager?
    /// The row press that opened the current popup — a fast second press at
    /// nearly the same spot is a double-click → rename (Lazy's
    /// mouseDoubleClickEvent, routed through the overlay that would otherwise
    /// swallow the second click before the board could see a double-click).
    private var lastPressItem: StickyItem?
    private var lastPressAt: Date?
    private var lastPressPoint: NSPoint?
    private var reloadWork: DispatchWorkItem?
    private var flashClearTask: Task<Void, Never>?
    private var dragOrigin: NSPoint?

    /// Completed THIS session stay on the board, crossed out (Lazy's
    /// done_session); they drop off on relaunch.
    private var sessionDone: [String: String] = [:]

    init(mailManager: MailManager) {
        self.mailManager = mailManager
    }

    // MARK: Font

    private static var didRegisterFont = false

    static func registerHandwritingFontIfNeeded() {
        guard !didRegisterFont else { return }
        didRegisterFont = true
        guard let url = Bundle.main.url(forResource: "PatrickHand-Regular", withExtension: "ttf") else {
            print("🗒 StickyBoard: Patrick Hand missing from bundle — system font fallback")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            print("🗒 StickyBoard: font registration failed — system font fallback")
        }
    }

    static var handFont: Font {
        if NSFont(name: handFontName, size: handFontSize) != nil {
            return .custom(handFontName, size: handFontSize)
        }
        return .system(size: handFontSize)
    }

    static func handFont(_ size: CGFloat) -> Font {
        if NSFont(name: handFontName, size: size) != nil {
            return .custom(handFontName, size: size)
        }
        return .system(size: size)
    }

    // MARK: Lifecycle

    func start() {
        Self.registerHandwritingFontIfNeeded()
        dataObserver = NotificationCenter.default.addObserver(
            forName: MailStore.boardDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReload() }
        }
        reload()
        // Ordering insurance (M6.9 note): Finder re-fronts its desktop window
        // on a desktop click, but the board now sits +3 ABOVE that layer
        // (-2147483600), so Finder can never bury it — the observer stays as
        // cheap insurance to re-stack board → overlay → popup after an app
        // activation; the LEVEL never changes, so app windows still always
        // win above us (same pattern as NotchChatManager's re-fronting).
        finderObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.frontIfVisible() }
        }
        // Lazy's behavior (M6.5): the board is pasted up whenever there's
        // anything on it — todos, reminders, mail cards — on every launch.
        // Empty = not shown. ✕/hide is session-only; a chat capture or the
        // next launch with items brings it back. Background events (mail
        // cards arriving, reminder flashes) never force-show after a close.
        if !items.isEmpty {
            show()
        }
    }

    /// Re-fronts the visible board without touching its level.
    /// A popup open at the same level must jump back on top of it.
    func frontIfVisible() {
        guard isBoardShown, panel?.isVisible == true else { return }
        panel?.orderFrontRegardless()
        popupManager?.refrontOverBoard()
    }

    func stop() {
        if let dataObserver {
            NotificationCenter.default.removeObserver(dataObserver)
        }
        if let finderObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(finderObserver)
        }
        reloadWork?.cancel()
        flashClearTask?.cancel()
        dismissPopup()
        panel?.orderOut(nil)
        panel = nil
        isBoardShown = false
    }

    func show() {
        reload()
        ensurePanel()
        positionPanelIfNeeded()
        panel?.orderFrontRegardless()
        popupManager?.refrontOverBoard()
        isBoardShown = true
    }

    func hide() {
        dismissPopup()
        panel?.orderOut(nil)
        isBoardShown = false
    }

    // MARK: Detail popup (M6.7 — Lazy's StickyPopup)

    /// Row-body tap: the secondary, temporary sticky with the item's full
    /// detail, opened near the click (Lazy's `_show_popup`).
    func openPopup(for item: StickyItem) {
        guard isBoardShown else { return }
        lastPressItem = item
        lastPressAt = Date()
        lastPressPoint = NSEvent.mouseLocation
        if popupManager == nil {
            let popup = StickyPopupManager()
            popup.onOutsidePress = { [weak self] in self?.handleOverlayPress() }
            popupManager = popup
        }
        popupManager?.show(title: item.title, note: item.note,
                           clickPoint: NSEvent.mouseLocation)
    }

    func dismissPopup() {
        popupManager?.close()
    }

    /// The popup's transparent overlay caught a press. A fast second press at
    /// nearly the same spot as the row press = double-click → Lazy's
    /// `_prompt_edit` (made reachable: the overlay otherwise swallows the
    /// second click before the board ever sees a double-click). Any other
    /// press just dismisses the popup.
    private func handleOverlayPress() {
        let item = lastPressItem
        let now = NSEvent.mouseLocation
        let quick = lastPressAt.map { Date.now.timeIntervalSince($0) < 0.30 } ?? false
        let near = lastPressPoint.map { abs(now.x - $0.x) < 40 && abs(now.y - $0.y) < 40 } ?? false
        lastPressItem = nil
        lastPressAt = nil
        lastPressPoint = nil
        dismissPopup()
        if quick, near, let item {
            promptRename(item)
        }
    }

    /// Lazy's `_prompt_add` — QInputDialog equivalent (native app-modal, so
    /// typing always lands; the inline field never reliably got a key window).
    func promptAdd() {
        guard isBoardShown else { return }
        guard let text = runInputDialog(title: "Add",
                                        prompt: "New item (a time like ‘friday at 3pm’ works too):") else { return }
        addItem(text: text)
    }

    /// Lazy's `_prompt_edit` (double-click) — prefilled Edit dialog; works on
    /// done rows too (Lazy has no done guard, and `rename` updates the
    /// session-done title).
    func promptRename(_ item: StickyItem) {
        guard let text = runInputDialog(title: "Edit", prompt: "Item:",
                                        initial: item.title) else { return }
        rename(item, to: text)
    }

    private func runInputDialog(title: String, prompt: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func toggleBoard() {
        if isBoardShown { hide() } else { show() }
    }

    // MARK: Widget layer (single source of truth: board + M6.7 popup)

    /// Desktop-widget level — above wallpaper + desktop icons, strictly
    /// below every normal app window, so the board (and its detail popup)
    /// can NEVER cover work.
    /// (rawValue 18 = kCGDesktopIconWindowLevelKey's ordinal in
    /// CGWindowLevel.h's CGWindowLevelKey — the CF_ENUM exposes only its
    /// failable raw init to Swift; Apple can only append keys, ordinals
    /// are stable. Probe-verified: -2147483603 vs windows at 0.)
    ///
    /// **+3 offset (M6.9):** Finder's desktop-icons window sits at exactly
    /// the raw desktop-icon level (-2147483603) and re-raises itself on every
    /// desktop click — same level, so it could order in front of the board and
    /// swallow its clicks (clicks "acted like empty desktop"; recovery only
    /// fired on app activation). Probe of the band above it: Finder desktop
    /// -2147483603, menu underbelly -2147483602, desktop widgets -2147483601,
    /// then nothing until normal windows at 0. +3 lands at **-2147483600** —
    /// deterministically above all three (never a tie, ties are where the race
    /// came from) and still ~2.1 billion below any app window, so the
    /// never-cover-work invariant holds by arithmetic.
    static var desktopIconLevel: NSWindow.Level {
        NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey(rawValue: 18)!)) + 3
        )
    }

    // MARK: Panel

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = StickyBoardPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Desktop-widget layer (M6.5/M6.5b) — shared `desktopIconLevel`:
        // above the wallpaper + icons, strictly below every app window,
        // no .fullScreenAuxiliary (absent while a full-screen app owns
        // the screen).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // shadow painted in SwiftUI (Lazy drew its own)
        panel.isMovableByWindowBackground = false
        // Level is assigned LAST, and `isFloatingPanel` must stay absent:
        // `isFloatingPanel = true` RE-LEVELS the panel to .floating (3) —
        // above every normal window (0) — the probe-verified root cause of
        // the M6.5b drill failure. Assigned last, nothing can overwrite it.
        panel.level = Self.desktopIconLevel
        let hosting = NSHostingView(rootView: StickyBoardView(manager: self))
        hosting.frame = NSRect(origin: .zero, size: Self.defaultSize)
        panel.contentView = hosting
        self.panel = panel
    }

    private func positionPanelIfNeeded() {
        guard let panel else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.geometryDefaultsKey) {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 4 {
                panel.setFrame(NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]), display: true)
                return
            }
        }
        // Default: right edge of the screen, just under the menu bar
        // (Lazy's paste spot).
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.defaultSize
        let origin = NSPoint(x: screen.maxX - size.width - 44, y: screen.maxY - 64 - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Drag + geometry

    func dragStarted() {
        dragOrigin = panel?.frame.origin
    }

    func dragMoved(by translation: CGSize) {
        guard let panel, let dragOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: dragOrigin.x + translation.width, y: dragOrigin.y - translation.height))
    }

    func dragEnded() {
        dragOrigin = nil
        guard let frame = panel?.frame else { return }
        UserDefaults.standard.set(
            "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))",
            forKey: Self.geometryDefaultsKey
        )
    }

    // MARK: Data

    /// Debounced so the 0.26 s strike animation finishes before an item
    /// relocates to the session-done tail (Lazy refreshed the same way).
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.reload() }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// board_items() port: open todos, then reminders not linked to a todo,
    /// then this session's completed items (crossed), sliced per board.
    func reload() {
        var merged: [StickyItem] = []
        var seenReminderIDs: Set<Int64> = []
        var liveKeys: Set<String> = []

        for todo in mailManager.boardTodos() {
            merged.append(StickyItem(kind: .todo, rowID: todo.id, title: todo.title, note: todo.details ?? "", dueAt: todo.dueAt, done: false))
            liveKeys.insert("todo:\(todo.id)")
            if let reminderID = todo.reminderID {
                seenReminderIDs.insert(reminderID)
            }
        }
        for reminder in mailManager.boardReminders() where !seenReminderIDs.contains(reminder.id) {
            merged.append(StickyItem(kind: .reminder, rowID: reminder.id, title: reminder.title, note: reminder.note ?? "", dueAt: reminder.dueAt, done: false))
            liveKeys.insert("reminder:\(reminder.id)")
        }
        for (key, title) in sessionDone where !liveKeys.contains(key) {
            let parts = key.split(separator: ":")
            guard parts.count == 2,
                  let kind = StickyItem.Kind(rawValue: String(parts[0])),
                  let rowID = Int64(parts[1])
            else { continue }
            merged.append(StickyItem(kind: kind, rowID: rowID, title: title, note: "", dueAt: nil, done: true))
        }

        boardCount = max(1, Int(ceil(Double(merged.count) / Double(Self.maxItemsPerBoard))))
        if boardIndex >= boardCount {
            boardIndex = boardCount - 1
        }
        let start = boardIndex * Self.maxItemsPerBoard
        items = Array(merged.dropFirst(start).prefix(Self.maxItemsPerBoard))
    }

    func cycleBoard() {
        boardIndex = (boardIndex + 1) % boardCount
        reload()
    }

    // MARK: Item operations (the view calls these)

    func toggleDone(_ item: StickyItem) {
        let becomingDone = !item.done
        if becomingDone {
            sessionDone[item.id] = item.title
        } else {
            sessionDone.removeValue(forKey: item.id)
        }
        mailManager.setBoardItemDone(kind: item.kind.rawValue, id: item.rowID, done: becomingDone)
    }

    func delete(_ item: StickyItem) {
        sessionDone.removeValue(forKey: item.id)
        mailManager.deleteBoardItem(kind: item.kind.rawValue, id: item.rowID)
    }

    func snooze(_ item: StickyItem) {
        mailManager.snoozeBoardReminder(id: item.rowID, minutes: 10)
    }

    func rename(_ item: StickyItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        if item.done {
            sessionDone[item.id] = trimmed
        }
        mailManager.editBoardItemTitle(kind: item.kind.rawValue, id: item.rowID, title: trimmed)
    }

    /// "+ add something…" / chat capture: a parsed time makes it a
    /// reminder, otherwise a todo (Lazy's add routed the same way).
    func addItem(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let due = NaturalDueParser.parse(trimmed) {
            mailManager.addReminderItem(title: trimmed, dueAt: due)
        } else {
            mailManager.addTodoItem(title: trimmed)
        }
    }

    func flash(itemID: String) {
        flashItemID = itemID
        flashClearTask?.cancel()
        flashClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flashItemID = nil
        }
    }
}

/// Borderless nonactivating panel that hosts the board. Add/edit use
/// app-modal dialogs (Lazy's QInputDialog), so the panel no longer needs to
/// become key — the override is kept but unused.
final class StickyBoardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Board view

private let paperColor = Color(red: 254.0 / 255.0, green: 243.0 / 255.0, blue: 167.0 / 255.0)
private let paperEdgeColor = Color(red: 227.0 / 255.0, green: 203.0 / 255.0, blue: 98.0 / 255.0)
private let ruleColor = Color(red: 216.0 / 255.0, green: 195.0 / 255.0, blue: 106.0 / 255.0)
private let pencilColor = Color(red: 63.0 / 255.0, green: 63.0 / 255.0, blue: 70.0 / 255.0)
private let pencilSoftColor = Color(red: 120.0 / 255.0, green: 113.0 / 255.0, blue: 108.0 / 255.0)
private let tapeColor = Color(red: 255.0 / 255.0, green: 249.0 / 255.0, blue: 196.0 / 255.0)
private let checkRedColor = Color(red: 220.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0)
private let flashColor = Color(red: 253.0 / 255.0, green: 223.0 / 255.0, blue: 110.0 / 255.0)

struct StickyBoardView: View {
    @ObservedObject var manager: StickyBoardManager

    @State private var hoverItemID: String?
    @State private var strikeProgress: [String: Double] = [:]
    @State private var isDragging = false

    // Metrics from Lazy (font_pt = 20): row = pt+20, header = pt+24, add = pt+22.
    private let rowHeight: CGFloat = 40
    private let headerHeight: CGFloat = 44
    private let addHeight: CGFloat = 42
    private let margin: CGFloat = 18
    private let boxSize: CGFloat = 18

    var body: some View {
        ZStack(alignment: .top) {
            // Paper + shadow (Lazy: rounded rect, edge stroke, drop shadow).
            RoundedRectangle(cornerRadius: 6)
                .fill(paperColor)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(paperEdgeColor, lineWidth: 1.2))
                .shadow(color: .black.opacity(0.39), radius: 24, x: 5, y: 8)

            VStack(alignment: .leading, spacing: 0) {
                header
                rows
                addBand
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            tapeStrip
        }
        .padding(12)
        .rotationEffect(.degrees(-1.5))
        .help("Lazy's notes — click checkbox to done, click item to see full summary")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(titleText)
                .font(StickyBoardManager.handFont(20))
                .foregroundColor(pencilColor)
                .onTapGesture(count: 2) { manager.cycleBoard() }
            Text(Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(StickyBoardManager.handFont(16))
                .foregroundColor(pencilSoftColor)
            Spacer()
            Button {
                manager.hide()
            } label: {
                Text("✕")
                    .font(StickyBoardManager.handFont(16))
                    .foregroundColor(pencilColor)
            }
            .buttonStyle(.plain)
        }
        .frame(height: headerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        manager.dragStarted()
                    }
                    manager.dragMoved(by: value.translation)
                }
                .onEnded { _ in
                    isDragging = false
                    manager.dragEnded()
                }
        )
    }

    private var titleText: String {
        var text = "Lazy's notes"
        if manager.boardCount > 1 {
            text += " (\(manager.boardIndex + 1)/\(manager.boardCount))"
        }
        return text
    }

    private var tapeStrip: some View {
        Rectangle()
            .fill(tapeColor)
            .opacity(0.8)
            .frame(width: 72, height: 20)
            .rotationEffect(.degrees(-2.5))
            .offset(x: -36 + 12, y: 12 - 10)
    }

    // MARK: Rows

    private var rows: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(manager.items) { item in
                    rowView(item)
                }
            }
            .padding(.top, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ruleColor).frame(height: 1)
        }
    }

    @ViewBuilder
    private func rowView(_ item: StickyItem) -> some View {
        let progress = strikeProgress[item.id] ?? (item.done ? 1.0 : 0.0)
        HStack(spacing: 0) {
            ZStack {
                WobblyCheckbox(jitter: jitter(for: item))
                if progress >= 0.99 {
                    HandCheckmark(jitter: jitter(for: item))
                }
            }
            .frame(width: boxSize + 6, height: rowHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                // Lazy: checkbox zone click crosses the item out (0.26 s
                // pencil strike, OutCubic) and persists the state.
                withAnimation(.easeOut(duration: 0.26)) {
                    strikeProgress[item.id] = item.done ? 0.0 : 1.0
                }
                manager.toggleDone(item)
            }

            ZStack(alignment: .leading) {
                Text(item.title)
                    .font(StickyBoardManager.handFont(20))
                    .foregroundColor(pencilColor.opacity(progress >= 0.5 ? 0.55 : 1.0))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .overlay(alignment: .leading) {
                        if progress > 0 {
                            PencilStrikeShape(progress: progress, jitter: jitter(for: item))
                                .stroke(
                                    pencilSoftColor,
                                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                                )
                                .allowsHitTesting(false)
                        }
                    }
            }
            // Lazy: pressing anywhere in the row body (not the checkbox/✕
            // zones) opens the detail popup — the whole strip is tappable, no
            // dead margins, and a single tap has no double-tap disambiguation
            // lag. Rename is a quick second press on the popup overlay
            // (handleOverlayPress), so both actions stay reachable.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                manager.openPopup(for: item)
            }

            removeButton(item)
        }
        .frame(height: rowHeight)
        .background {
            if manager.flashItemID == item.id {
                flashColor.opacity(0.67)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 4)
        .contextMenu {
            if item.kind == .reminder {
                Button("⏰ snooze 10m") { manager.snooze(item) }
            }
            Button("🗑 delete") { manager.delete(item) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ruleColor).frame(height: 1)
        }
    }

    private func removeButton(_ item: StickyItem) -> some View {
        let isHovered = hoverItemID == item.id
        return Button {
            manager.delete(item)
        } label: {
            Canvas { context, _ in
                let color: Color = isHovered ? checkRedColor : pencilSoftColor.opacity(0.25)
                let width: CGFloat = isHovered ? 1.8 : 1.4
                var first = Path()
                first.move(to: CGPoint(x: 0, y: 0))
                first.addLine(to: CGPoint(x: 9, y: 9))
                var second = Path()
                second.move(to: CGPoint(x: 9, y: 0))
                second.addLine(to: CGPoint(x: 0, y: 9))
                context.stroke(first, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                context.stroke(second, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .onHover { hoverItemID = $0 ? item.id : nil }
    }

    // MARK: Add band

    private var addBand: some View {
        HStack(spacing: 6) {
            Text("+ add something…")
                .font(StickyBoardManager.handFont(20))
                .foregroundColor(pencilSoftColor)
            Spacer()
        }
        .frame(height: addHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // Lazy: clicking anywhere on the add band opens the Add dialog.
            manager.promptAdd()
        }
    }

    // MARK: Helpers

    /// Deterministic per-item wobble (Lazy seeded a RNG with the key).
    private func jitter(for item: StickyItem) -> Double {
        var hash: UInt64 = 5381
        for byte in item.id.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Double(hash % 240) / 100.0 - 1.2
    }
}

// MARK: - Hand-drawn pieces

/// Four wobbly quad segments (Lazy's hand-drawn box).
private struct WobblyCheckbox: View {
    var jitter: Double

    var body: some View {
        Canvas { context, size in
            let box = min(size.width, size.height)
            let j = CGFloat(jitter)
            let corners = [
                CGPoint(x: 1, y: 1 + j * 0.4),
                CGPoint(x: box - 1, y: 1 - j * 0.3),
                CGPoint(x: box - 1 + j * 0.3, y: box - 1),
                CGPoint(x: 1 - j * 0.2, y: box - 1 - j * 0.3)
            ]
            var path = Path()
            path.move(to: corners[0])
            for index in 0..<4 {
                let next = corners[(index + 1) % 4]
                let control = CGPoint(
                    x: (corners[index].x + next.x) / 2 + j * 0.5,
                    y: (corners[index].y + next.y) / 2 - j * 0.4
                )
                path.addQuadCurve(to: next, control: control)
            }
            path.closeSubpath()
            context.stroke(
                path,
                with: .color(pencilSoftColor),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

/// Red hand-drawn check (Lazy's two curved jittered segments).
private struct HandCheckmark: View {
    var jitter: Double

    var body: some View {
        Canvas { context, size in
            let box = min(size.width, size.height)
            let j = CGFloat(jitter)
            let first = CGPoint(x: 2 + j * 0.3, y: box / 2)
            let middle = CGPoint(x: box / 2, y: box - 2 - j * 0.2)
            let last = CGPoint(x: box - 1 - j * 0.3, y: 1 + j * 0.2)
            var path = Path()
            path.move(to: first)
            path.addQuadCurve(
                to: middle,
                control: CGPoint(x: (first.x + middle.x) / 2 + j * 0.4, y: (first.y + middle.y) / 2)
            )
            path.addQuadCurve(
                to: last,
                control: CGPoint(x: (middle.x + last.x) / 2 - j * 0.3, y: (middle.y + last.y) / 2)
            )
            context.stroke(
                path,
                with: .color(checkRedColor),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

/// Wobbly pencil strikethrough that grows left→right with `progress`.
private struct PencilStrikeShape: Shape {
    var progress: Double
    var jitter: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = rect.minX - 3
        let end = rect.maxX + 4
        let span = (end - start) * progress
        var x = start
        var step = 0
        path.move(to: CGPoint(x: start, y: rect.midY + jitter))
        while x < start + span {
            x = min(x + 9, start + span)
            let y = rect.midY + jitter + (step % 2 == 0 ? 1.7 : -1.5)
            path.addLine(to: CGPoint(x: x, y: y))
            step += 1
        }
        return path
    }
}
