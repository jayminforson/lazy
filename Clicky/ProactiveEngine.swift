//
//  ProactiveEngine.swift
//  Clicky
//
//  Sensing + suggestion rules (locked M3):
//    - once/day batch after 6 am while the user is active (input < 5 min ago)
//    - suppressed while Do Not Disturb / any Focus is active (rule_dnd)
//    - "ignore breaks until <time>" pauses all batches until then
//    - overdue routines settle as cards (rule_routines), break card at a
//      50 min uninterrupted stretch (rule_breaks), yesterday's most-used
//      app fact card (rule_daily is the master cadence toggle)
//  DND is read from ~/Library/DoNotDisturb/DB/Assertions.json (no private
//  framework linked); unknown/unreadable → not DND. An empty batch never
//  marks the day delivered — the batch waits for real content.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class ProactiveSuggestionEngine: ObservableObject {

    // MARK: - Published state

    @Published private(set) var suggestions: [ClickySuggestion] = []
    @Published private(set) var routines: [ClickyRoutine] = []
    @Published private(set) var isDoNotDisturbActive = false
    @Published private(set) var pauseUntil: Date?
    @Published private(set) var unreadCount = 0
    @Published private(set) var secondsSinceLastInput: TimeInterval = 0
    @Published private(set) var lastDeliveredDay: String?

    /// Set by CompanionManager — receives each delivered batch so the
    /// manager can append the ReplySource.scheduled transcript entry and
    /// update the notch badge mirror.
    var onDeliverBatch: (([ClickySuggestion]) -> Void)?

    // MARK: - Locks / state

    private static let defaults = UserDefaults.standard
    private var tickTimer: Timer?
    private var usageObserver: NSObjectProtocol?
    private var dndObservers: [NSObjectProtocol] = []
    private var currentUsageApp: String?
    private var currentAppStartedAt: Date?
    private var activeStretchStart: Date?

    private enum Key {
        static let suggestions = "clickySuggestions"
        static let routines = "clickyRoutines"
        static let pausedUntil = "clickySuggestionsPausedUntil"
        static let lastDeliveryDay = "clickySuggestionLastDeliveredDay"
        static let usageToday = "clickyAppUsageToday"
        static let usageYesterday = "clickyAppUsageYesterday"
        static let usageDayStamp = "clickyAppUsageDayStamp"
    }

    private enum Rules {
        static let breaks = "clickySuggestionRule_breaks"
        static let routines = "clickySuggestionRule_routines"
        static let daily = "clickySuggestionRule_daily"
        static let dnd = "clickySuggestionRule_dnd"
    }

    /// Unset rule defaults to ON (matches the Home toggles' @AppStorage defaults).
    private func ruleEnabled(_ key: String) -> Bool {
        Self.defaults.object(forKey: key) == nil ? true : Self.defaults.bool(forKey: key)
    }

    // MARK: - Lifecycle

    func start() {
        loadState()
        rotateUsageDayIfNeeded()

        // App-usage rollup: activation switches the tracked frontmost app.
        usageObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.noteAppActivation(bundleID: app?.bundleIdentifier, name: app?.localizedName)
            }
        }

        // Best-effort live DND refresh; the 60 s tick polls regardless.
        for name in ["com.apple.donotdisturb.dbchanged", "com.apple.focus.modechanged"] {
            dndObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDoNotDisturb()
                }
            })
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        tick()
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let usageObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(usageObserver)
            self.usageObserver = nil
        }
        for dndObserver in dndObservers {
            DistributedNotificationCenter.default().removeObserver(dndObserver)
        }
        dndObservers.removeAll()
        accumulateUsage()
    }

    // MARK: - Tick

    private func tick() {
        refreshDoNotDisturb()
        rotateUsageDayIfNeeded()
        accumulateUsage()

        // kCGAnyInputEventType — a C #define that doesn't import as a case.
        // Verified the raw-value init accepts 0xFFFFFFFF at runtime.
        let anyInput = CGEventType(rawValue: 0xFFFFFFFF) ?? .null
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        secondsSinceLastInput = idle
        if idle < 15 {
            if activeStretchStart == nil { activeStretchStart = Date() }
        } else {
            activeStretchStart = nil
        }

        evaluateDailyBatch(now: Date(), idleSeconds: idle)
    }

    /// Locked batch rules. Empty content → return without marking the day,
    /// so the next tick retries (still capped at one delivery/day).
    private func evaluateDailyBatch(now: Date, idleSeconds: TimeInterval) {
        guard ruleEnabled(Rules.daily) else { return }

        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) >= 6 else { return }

        let today = Self.dayString(now)
        if lastDeliveredDay == today { return }

        // "while active" = recent keyboard/mouse input.
        guard idleSeconds < 300 else { return }

        if ruleEnabled(Rules.dnd), isDoNotDisturbActive { return }
        if let paused = pauseUntil, now < paused { return }

        var cards: [ClickySuggestion] = []

        if ruleEnabled(Rules.routines) {
            let overdue = routines
                .filter { $0.isOverdue(asOf: now) }
                .sorted { $0.nextDueDate() < $1.nextDueDate() }
                .prefix(3)
            cards += overdue.map { routine in
                ClickySuggestion(
                    kind: .routine,
                    title: routine.name,
                    body: "was due \(routine.overdueLabel(asOf: now))",
                    routineID: routine.id
                )
            }
        }

        if ruleEnabled(Rules.breaks),
           let stretchStart = activeStretchStart,
           now.timeIntervalSince(stretchStart) >= 50 * 60 {
            let minutes = Int(now.timeIntervalSince(stretchStart) / 60)
            cards.append(ClickySuggestion(
                kind: .note,
                title: "Take five",
                body: "\(minutes)m straight at the keyboard — stretch while the idea is good."
            ))
        }

        if let usageCard = makeUsageCard(now: now) {
            cards.append(usageCard)
        }

        guard !cards.isEmpty else { return }
        if cards.count > 4 { cards = Array(cards.prefix(4)) }

        suggestions = cards + suggestions
        if suggestions.count > 12 {
            suggestions = Array(suggestions.prefix(12))
        }
        lastDeliveredDay = today
        persistSuggestions()
        Self.defaults.set(today, forKey: Key.lastDeliveryDay)
        recalcUnread()

        print("🔔 Morning notch: \(cards.count) suggestion(s)")
        onDeliverBatch?(cards)
    }

    private func makeUsageCard(now: Date) -> ClickySuggestion? {
        let yesterday = Self.defaults.dictionary(forKey: Key.usageYesterday) as? [String: Double] ?? [:]
        guard let top = yesterday.max(by: { $0.value < $1.value }), top.value >= 1800 else {
            return nil
        }
        return ClickySuggestion(
            kind: .usage,
            title: "Yesterday belonged to \(top.key)",
            body: "\(Self.formatDuration(top.value)) there — the most of any app."
        )
    }

    // MARK: - App usage sensing

    private func noteAppActivation(bundleID: String?, name: String?) {
        accumulateUsage()
        if let name, bundleID != Bundle.main.bundleIdentifier {
            currentUsageApp = name
            currentAppStartedAt = Date()
        } else {
            currentUsageApp = nil
            currentAppStartedAt = nil
        }
    }

    private func accumulateUsage() {
        guard let name = currentUsageApp, let started = currentAppStartedAt else {
            if currentUsageApp == nil {
                let front = NSWorkspace.shared.frontmostApplication
                if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
                    currentUsageApp = front.localizedName
                    currentAppStartedAt = Date()
                }
            }
            return
        }
        var today = Self.defaults.dictionary(forKey: Key.usageToday) as? [String: Double] ?? [:]
        today[name, default: 0] += Date().timeIntervalSince(started)
        if today.count > 30 {
            today = today.sorted { $0.value > $1.value }
                .prefix(20)
                .reduce(into: [String: Double]()) { $0[$1.key] = $1.value }
        }
        Self.defaults.set(today, forKey: Key.usageToday)
        currentAppStartedAt = Date()
    }

    private func rotateUsageDayIfNeeded() {
        let today = Self.dayString(Date())
        let stamp = Self.defaults.string(forKey: Key.usageDayStamp)
        guard stamp != today else { return }
        if stamp != nil {
            let current = Self.defaults.dictionary(forKey: Key.usageToday) as? [String: Double] ?? [:]
            Self.defaults.set(current, forKey: Key.usageYesterday)
        }
        Self.defaults.set([:] as [String: Double], forKey: Key.usageToday)
        Self.defaults.set(today, forKey: Key.usageDayStamp)
        currentUsageApp = nil
        currentAppStartedAt = nil
    }

    // MARK: - Do Not Disturb sensing

    /// Reads the Focus/DND assertion store (plain JSON, no private API
    /// linked). Active assertions live under a `store…AssertionRecords`
    /// key; invalidation-only history never matches. Unknown → not DND.
    private func refreshDoNotDisturb() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else {
            isDoNotDisturbActive = false
            return
        }
        var active = false
        for entry in entries {
            // Canonical active-Focus key (verified stable macOS 12→26 across
            // community tooling): non-empty storeAssertionRecords = Focus on.
            if let records = entry["storeAssertionRecords"] as? [[String: Any]], !records.isEmpty {
                active = true
            }
        }
        isDoNotDisturbActive = active
    }

    // MARK: - Pause / resume intents (local, no brain — locked rule)

    enum SuggestionIntent: Equatable {
        case pauseUntil(Date)
        case resume
    }

    /// "ignore breaks until 3pm" / "pause suggestions until tomorrow morning"
    /// / "quiet until noon" → .pauseUntil; resume phrases → .resume.
    /// Strict prefix matches on normalized text — anything else stays with
    /// the brain.
    func suggestionIntent(matching text: String) -> SuggestionIntent? {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))

        let resumePhrases = [
            "start suggesting again",
            "resume suggestions",
            "unpause suggestions",
            "you can suggest again"
        ]
        if resumePhrases.contains(where: { normalized == $0 }) {
            return .resume
        }

        let pausePrefixes = [
            "ignore breaks until ",
            "pause suggestions until ",
            "quiet until "
        ]
        for prefix in pausePrefixes where normalized.hasPrefix(prefix) {
            let tail = String(normalized.dropFirst(prefix.count))
            if let date = Self.pauseDate(fromRelativeTime: tail) {
                return .pauseUntil(date)
            }
        }
        return nil
    }

    func pauseSuggestions(until date: Date) {
        pauseUntil = date
        Self.defaults.set(date.iso8601String(), forKey: Key.pausedUntil)
        print("🔕 Suggestions paused until \(date)")
    }

    func resumeSuggestions() {
        pauseUntil = nil
        Self.defaults.removeObject(forKey: Key.pausedUntil)
        print("🔔 Suggestions resumed")
    }

    static func pauseDate(fromRelativeTime raw: String) -> Date? {
        var tail = raw.trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return nil }

        var dayOffset = 0
        if tail.hasPrefix("tomorrow") {
            dayOffset = 1
            tail = String(tail.dropFirst("tomorrow".count)).trimmingCharacters(in: .whitespaces)
        }
        if tail.hasPrefix("this ") {
            tail = String(tail.dropFirst(5))
        }

        let calendar = Calendar.current
        let now = Date()

        func date(hour: Int, minute: Int) -> Date? {
            var comps = calendar.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            guard var result = calendar.date(from: comps) else { return nil }
            result = result.addingTimeInterval(Double(dayOffset) * 86_400)
            if result <= now {
                result = result.addingTimeInterval(86_400)
            }
            return result
        }

        switch tail {
        case "":
            return date(hour: 6, minute: 0)
        case "morning":
            return date(hour: 9, minute: 0)
        case "afternoon":
            return date(hour: 15, minute: 0)
        case "evening":
            return date(hour: 20, minute: 0)
        case "tonight":
            return date(hour: 21, minute: 0)
        case "noon":
            return date(hour: 12, minute: 0)
        case "midnight":
            return date(hour: 0, minute: 0)
        default:
            break
        }

        // "3pm" / "3:30 pm" / "15:30" / bare "3"
        let pattern = #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: tail,
                range: NSRange(tail.startIndex..., in: tail)
              ),
              let hourRange = Range(match.range(at: 1), in: tail),
              let hour = Int(tail[hourRange]) else { return nil }

        var minute = 0
        if let minuteRange = Range(match.range(at: 2), in: tail), let parsed = Int(tail[minuteRange]) {
            minute = parsed
        }
        var meridiem: String?
        if let merRange = Range(match.range(at: 3), in: tail) {
            meridiem = String(tail[merRange])
        }

        var resolvedHour = hour
        switch meridiem {
        case "pm":
            if resolvedHour < 12 { resolvedHour += 12 }
        case "am":
            if resolvedHour == 12 { resolvedHour = 0 }
        default:
            break // bare number → next occurrence of that clock time
        }
        guard (0...23).contains(resolvedHour), (0...59).contains(minute) else { return nil }
        return date(hour: resolvedHour, minute: minute)
    }

    // MARK: - Suggestions / routines CRUD

    func markAllRead() {
        guard suggestions.contains(where: { !$0.isRead }) else { return }
        suggestions = suggestions.map { var s = $0; s.isRead = true; return s }
        persistSuggestions()
        recalcUnread()
    }

    func markRead(id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].isRead = true
        persistSuggestions()
        recalcUnread()
    }

    func dismiss(id: UUID) {
        suggestions.removeAll { $0.id == id }
        persistSuggestions()
        recalcUnread()
    }

    /// "Done" on a routine card: resets its cadence and clears the card.
    func completeRoutine(id: UUID) {
        if let index = routines.firstIndex(where: { $0.id == id }) {
            routines[index].lastRunDate = Date()
            persistRoutines()
        }
        if let card = suggestions.first(where: { $0.routineID == id }) {
            dismiss(id: card.id)
        }
    }

    func addRoutine(name: String, intervalHours: Double, dueNow: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, intervalHours > 0 else { return }
        let lastRun = dueNow
            ? Date().addingTimeInterval(-(intervalHours * 3600) - 60)
            : Date()
        routines.append(ClickyRoutine(name: trimmed, intervalHours: intervalHours, lastRunDate: lastRun))
        persistRoutines()
        print("📅 Routine added: \(trimmed) every \(intervalHours)h")
    }

    func removeRoutine(id: UUID) {
        routines.removeAll { $0.id == id }
        suggestions.removeAll { $0.routineID == id }
        persistRoutines()
        persistSuggestions()
        recalcUnread()
    }

    private func recalcUnread() {
        unreadCount = suggestions.filter { !$0.isRead }.count
    }

    // MARK: - Persistence

    private func loadState() {
        if let data = Self.defaults.data(forKey: Key.suggestions),
           let decoded = try? JSONDecoder().decode([ClickySuggestion].self, from: data) {
            suggestions = decoded
        }
        if let data = Self.defaults.data(forKey: Key.routines),
           let decoded = try? JSONDecoder().decode([ClickyRoutine].self, from: data) {
            routines = decoded
        }
        if let stamp = Self.defaults.string(forKey: Key.lastDeliveryDay) {
            lastDeliveredDay = stamp
        }
        if let iso = Self.defaults.string(forKey: Key.pausedUntil),
           let date = ISO8601DateFormatter().date(from: iso) {
            pauseUntil = date
        }
        recalcUnread()
    }

    private func persistSuggestions() {
        guard let data = try? JSONEncoder().encode(suggestions) else { return }
        Self.defaults.set(data, forKey: Key.suggestions)
    }

    private func persistRoutines() {
        guard let data = try? JSONEncoder().encode(routines) else { return }
        Self.defaults.set(data, forKey: Key.routines)
    }

    // MARK: - Formatting helpers

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }
}

private extension Date {
    func iso8601String() -> String {
        ISO8601DateFormatter().string(from: self)
    }
}
