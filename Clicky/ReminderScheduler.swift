//
//  ReminderScheduler.swift
//  Clicky
//
//  M6.3 — polls for due reminders every 15 s (Lazy's scheduler.py port):
//  claim due rows (30-min dedupe) → during quiet hours DEFER (snooze to the
//  window's end, Lazy never drops) → otherwise banner via MailNotifier and
//  flash the board row. A DB hiccup never kills the loop.
//

import Foundation

@MainActor
final class ReminderScheduler {

    static let tickIntervalSeconds: TimeInterval = 15
    static let dedupeMinutes = 30

    private let store: MailStore
    private var task: Task<Void, Never>?

    /// Called with (id, title) for every reminder that actually fired.
    var onFired: ((Int64, String) -> Void)?

    init(store: MailStore) {
        self.store = store
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.tickIntervalSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func tick(now: Date = Date()) async {
        let due = store.claimDueReminders(now: now, dedupeMinutes: Self.dedupeMinutes)
        guard !due.isEmpty else { return }

        // Quiet hours defer instead of dropping (Lazy's deferred_until).
        if MailNotifier.inQuietHours(now: now), let quietEnd = MailNotifier.quietHoursEnd(now: now) {
            for reminder in due {
                store.snoozeReminder(id: reminder.id, until: quietEnd)
                print("⏰ Reminder \(reminder.id) deferred to quiet-hours end")
            }
            return
        }

        for reminder in due {
            let dueLine = reminder.dueAt.map { "Due \($0.formatted(date: .omitted, time: .shortened))" } ?? "Due now"
            if await MailNotifier.notify(title: "⏰ \(reminder.title)", body: dueLine, subtitle: "Reminder") {
                print("⏰ Reminder fired: \(reminder.title)")
                onFired?(reminder.id, reminder.title)
            }
        }
    }
}
