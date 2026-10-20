//
//  MailNotifier.swift
//  Clicky
//
//  M6.2 — macOS banners via `osascript display notification` (Lazy's
//  notify.py — works without any TCC prompt), plus the quiet-hours window
//  22:00–07:30 (Lazy's sync.quiet_hours default). Dedupe itself lives in
//  MailStore's notification_log (30-min window, Lazy F-09).
//

import Foundation

enum MailNotifier {

    /// Same window as Lazy's default config: banners sleep 22:00–07:30.
    static let quietHoursSpec = "22:00-07:30"

    // MARK: - Quiet hours (notify.py, ported)

    static func inQuietHours(now: Date = Date(), spec: String = quietHoursSpec) -> Bool {
        guard let window = parseQuietHours(spec) else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let current = formatter.string(from: now)
        if window.start <= window.end {
            return window.start <= current && current < window.end
        }
        // Overnight window (22:00–07:30): in until the end boundary.
        return current >= window.start || current < window.end
    }

    static func parseQuietHours(_ spec: String) -> (start: String, end: String)? {
        let parts = spec
            .split(separator: "-", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        for part in parts {
            let clock = part.split(separator: ":")
            guard clock.count == 2,
                  let hours = Int(clock[0]),
                  let minutes = Int(clock[1]),
                  (0...23).contains(hours),
                  (0...59).contains(minutes)
            else { return nil }
        }
        return (parts[0], parts[1])
    }

    /// Next occurrence of the quiet-hours end boundary (Lazy's
    /// `quiet_hours_end` — the scheduler snoozes due reminders to this).
    static func quietHoursEnd(now: Date = Date(), spec: String = quietHoursSpec) -> Date? {
        guard let window = parseQuietHours(spec),
              let hours = Int(window.end.split(separator: ":")[0]),
              let minutes = Int(window.end.split(separator: ":")[1])
        else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = hours
        components.minute = minutes
        components.second = 0
        let candidate = Calendar.current.date(from: components) ?? now
        if candidate <= now {
            return Calendar.current.date(byAdding: .day, value: 1, to: candidate)
        }
        return candidate
    }

    // MARK: - Banner

    @discardableResult
    static func notify(title: String, body: String, subtitle: String) async -> Bool {
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\" subtitle \"\(escape(subtitle))\""
        let result = await CompanionManager.runCommand(
            "/usr/bin/osascript",
            arguments: ["-e", script],
            timeoutSeconds: 5
        )
        if result == nil {
            print("📣 MailNotifier: osascript failed for \"\(title.prefix(60))\"")
        }
        return result != nil
    }

    /// Escape for an AppleScript string literal; newlines become " · " so the
    /// -e one-liner can never break across lines.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " · ")
    }
}
