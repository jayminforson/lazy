//
//  MailClassifier.swift
//  Clicky
//
//  M6.2 — fully local mail analysis, ported from Lazy's Phase 4/5 pipeline:
//  school detection (mailschool.py), deterministic urgency/event scoring
//  (extraction.py DEADLINE_PATTERNS/EVENT_PATTERNS with their exact scores),
//  meeting-detail extraction, and the extractive fallback summary. No cloud
//  involved in classification itself — only the optional summary (M6.2's
//  MailSummarizer) touches Gemini.
//

import Foundation

/// One message's analysis verdict, all deterministic.
struct MailClassification {
    let isSchool: Bool
    let schoolReason: String
    let isTimeSensitive: Bool
    let hasEvent: Bool
    let urgencyLevel: String      // "high" | "normal" | "low"
    let urgencyConfidence: Double
    let urgencyReasons: [String]
    let meeting: MailClassifier.MeetingDetails
    /// Lazy's `due_at` (orchestrator `_mail_to_board`): the event's parsed
    /// start time — local, future-only, nil unless `hasEvent`. Drives the
    /// card's due-first sort and the ⏰ scheduler banner at meeting time.
    /// M4.5c: when the mail states its own zone, this is the TRUE instant
    /// (converted), not the email's wall clock stamped onto yours.
    let meetingStart: Date?
    /// M4.5c: the short zone label the mail itself wrote ("ET", "UTC"),
    /// nil when the mail gave no zone — so the card can show the time as
    /// emailed and the converted local time side by side, and stays silent
    /// rather than inventing a conversion.
    let meetingZoneLabel: String?

    /// Board rule (Lazy `_on_mail_message`): school OR time-sensitive OR event.
    var shouldBoard: Bool { isSchool || isTimeSensitive || hasEvent }

    /// Banner rule (Lazy `_notify_urgent_mail`): level "high" + conf ≥ 0.7 —
    /// with Lazy's scoring that is exactly `urgencyLevel == "high"`.
    var shouldBanner: Bool { urgencyLevel == "high" && urgencyConfidence >= 0.7 }
}

enum MailClassifier {

    // MARK: - School detection (mailschool.py, verbatim)

    static let schoolKeywords = [
        ".edu", ".ac.uk", ".edu.au", ".ac.za",
        "university", "college", "admission", "admissions",
        "scholarship", "financial aid", "applicant",
        "enrollment", "registrar", "bursar", "fafsa"
    ]

    static let schoolPhrases = [
        "your application", "your admission", "your application status",
        "application received", "application decision", "acceptance",
        "waitlist", "deferred", "early decision", "regular decision",
        "financial aid package", "fafsa", "scholarship offer",
        "student housing", "orientation", "registration opens",
        "transcript received", "test scores received"
    ]

    static func detectSchool(sender: String, subject: String, body: String) -> (isSchool: Bool, reason: String) {
        let senderLower = sender.lowercased()
        let subjectLower = subject.lowercased()
        let bodyLower = body.lowercased()

        for keyword in schoolKeywords {
            if senderLower.contains(keyword) { return (true, "sender matches school keyword '\(keyword)'") }
            if subjectLower.contains(keyword) { return (true, "subject matches school keyword '\(keyword)'") }
        }
        for phrase in schoolPhrases where subjectLower.contains(phrase) {
            return (true, "subject phrase '\(phrase)'")
        }
        for phrase in schoolPhrases where bodyLower.contains(phrase) {
            return (true, "body phrase '\(phrase)'")
        }
        return (false, "")
    }

    // MARK: - Urgency (extraction.py deterministic_analyze, exact scores)

    private struct ScoredPattern {
        let regex: NSRegularExpression
        let score: Double
        let label: String
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Static, constant patterns — a bad one would be a build-time bug.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let deadlinePatterns: [ScoredPattern] = [
        ScoredPattern(regex: regex(#"\b(urgent|asap|immediately|right away)\b"#), score: 0.9, label: "explicit urgency keyword"),
        ScoredPattern(regex: regex(#"\b(deadline|due by|due date|overdue|final notice|last reminder)\b"#), score: 0.85, label: "deadline phrasing"),
        ScoredPattern(regex: regex(#"\b(by (the end of )?eod|by end of day|end of business|close of business)\b"#), score: 0.85, label: "end-of-day deadline"),
        ScoredPattern(regex: regex(#"\b(action required|respond (today|by|within)|needs? your (reply|response|approval))\b"#), score: 0.8, label: "response requested"),
        ScoredPattern(regex: regex(#"\b(today|tonight|this (morning|afternoon|evening))\b"#), score: 0.7, label: "same-day time cue"),
        ScoredPattern(regex: regex(#"\b(expiring|expires|before|no later than|by)\s"#), score: 0.6, label: "bounded-time phrasing")
    ]

    static func urgency(in text: String) -> (level: String, confidence: Double, reasons: [String]) {
        var reasons: [String] = []
        var bestScore = 0.0
        for pattern in deadlinePatterns where matches(pattern.regex, in: text) {
            bestScore = max(bestScore, pattern.score)
            reasons.append(pattern.label)
        }
        let level: String
        if bestScore >= 0.7 {
            level = "high"
        } else if bestScore >= 0.5 {
            level = "normal"
        } else {
            level = "low"
            reasons.append("no deadline or urgency signals")
        }
        let confidence = min(0.95, bestScore == 0 ? 0.4 : bestScore)
        return (level, confidence, reasons)
    }

    // MARK: - Event detection (EVENT_PATTERNS + date required, Lazy semantics)

    private static let eventPatterns: [ScoredPattern] = [
        ScoredPattern(regex: regex(#"\b(meeting|invite|invitation|calendar|appointment|sync|standup|call|zoom|teams|webinar|interview)\b"#), score: 0.85, label: "meeting/invitation cue"),
        ScoredPattern(regex: regex(#"\b(let'?s (meet|connect|catch up)|are (we|you) (still )?(on|meeting)|join (me|us))\b"#), score: 0.8, label: "scheduling language"),
        ScoredPattern(regex: regex(#"\b(location|room \d+|conference|lobby|address|dial[- ]?in|passcode)\b"#), score: 0.6, label: "location detail")
    ]

    // MARK: - Date / time recognizers (mailschool + extraction regexes)

    private static let datePatterns: [NSRegularExpression] = [
        regex(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b"#),
        regex(#"\b(mon|tues|wednes|thurs|fri|satur|sun)day,?\s+\w+\s+\d{1,2}\b"#),
        regex(#"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#),
        regex(#"\b\d{4}-\d{2}-\d{2}\b"#)
    ]

    private static let timePatterns: [NSRegularExpression] = [
        regex(#"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\b"#),
        regex(#"\b(?:at\s+)([01]?\d|2[0-3]):([0-5]\d)\b"#)
    ]

    static func hasRecognizableDate(in text: String) -> Bool {
        datePatterns.contains { matches($0, in: text) }
    }

    static func hasRecognizableTime(in text: String) -> Bool {
        timePatterns.contains { matches($0, in: text) }
    }

    // MARK: - Meeting details (mailschool.extract_meeting_details, ported)

    struct MeetingDetails {
        var date: String?
        var time: String?
        var link: String?
    }

    static func extractMeetingDetails(body: String) -> MeetingDetails {
        var details = MeetingDetails()
        guard !body.isEmpty else { return details }

        // Strip <url> angle brackets first (Lazy did the same).
        let cleanBody = replacing(in: body, pattern: #"<(https?://[^>]+)>"#, with: "$1")

        let linkPatterns = [
            #"(https://zoom\.us/j/\S+)"#,
            #"(https://[a-z0-9.-]+\.zoom\.us/j/\S+)"#,
            #"(https://teams\.microsoft\.com/l/meetup-join/\S+)"#,
            #"(https://meet\.google\.com/[a-z-]+)"#
        ]
        for pattern in linkPatterns {
            if let link = firstGroup(of: regex(pattern), in: cleanBody) {
                details.link = trimmedURL(link)
                break
            }
        }
        if details.link == nil {
            let registerPattern = regex(#"(?:register|join|rsvp|sign up|info session|add to calendar)[^\n]{0,200}?(https?://\S+)"#)
            if let link = firstGroup(of: registerPattern, in: cleanBody) {
                details.link = trimmedURL(link)
            } else {
                let anyURL = regex(#"(https?://\S+)"#)
                let range = NSRange(cleanBody.startIndex..., in: cleanBody)
                for match in anyURL.matches(in: cleanBody, options: [], range: range) {
                    guard let url = group(1, match, cleanBody) else { continue }
                    let lower = url.lowercased()
                    if lower.contains("privacy") || lower.contains("optout")
                        || lower.contains("unsubscribe") || lower.contains("mailto") { continue }
                    details.link = trimmedURL(url)
                    break
                }
            }
        }

        let dateRegexes = [
            regex(#"(?:on|this|next)?\s*((?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day,?\s+\w+\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?)"#),
            regex(#"((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?)"#),
            regex(#"(\d{1,2}/\d{1,2}/\d{2,4})"#)
        ]
        for pattern in dateRegexes {
            if let date = firstGroup(of: pattern, in: body) {
                details.date = date.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ","))
                break
            }
        }

        let timeRegexes = [
            regex(#"(\d{1,2}:\d{2}\s*(?:AM|PM|am|pm)(?:\s*(?:ET|PT|CT|MT|EST|PST|CST|MST|GMT|UTC))?)"#),
            regex(#"(\d{1,2}\s*(?:AM|PM|am|pm)(?:\s*(?:ET|PT|CT|MT|EST|PST|CST|MST|GMT|UTC))?)"#),
            regex(#"((?:\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)))"#)
        ]
        for pattern in timeRegexes {
            if let time = firstGroup(of: pattern, in: body) {
                details.time = time.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return details
    }

    // MARK: - Bulk senders (orchestrator._BULK_SENDER_MARKERS, verbatim)

    static let bulkSenderMarkers = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
        "newsletter", "marketing", "notifications@", "alerts@",
        "receipts@", "welcome@", "support@", "info@"
    ]

    static func isBulkSender(_ sender: String) -> Bool {
        let lower = sender.lowercased()
        return bulkSenderMarkers.contains { lower.contains($0) }
    }

    // MARK: - Extractive fallback summary (mailschool.extractive_summary, ported)

    static func extractiveSummary(body: String, meeting: MeetingDetails, maxSentences: Int = 2) -> String {
        guard !body.isEmpty else { return "" }
        let sentenceSplitter = regex(#"(?<=[.!?])\s+"#)
        let range = NSRange(body.startIndex..., in: body)
        let sentences = sentenceSplitter
            .stringByReplacingMatches(in: body, options: [], range: range, withTemplate: "\u{0}")
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let greetingFilter = regex(#"^(hi|hello|dear|greetings|hey|thank|thanks|best|regards|sincerely)"#)
        var useful = sentences.filter { sentence in
            sentence.count > 20 && !matches(greetingFilter, in: sentence)
        }
        if useful.isEmpty {
            useful = Array(sentences.prefix(maxSentences))
        }
        var summary = useful.prefix(maxSentences).joined(separator: " ")
        if summary.count > 200 {
            summary = String(summary.prefix(197)) + "…"
        }
        let extras = meetingExtras(meeting)
        if !extras.isEmpty {
            summary += " | " + extras.joined(separator: " | ")
        }
        return summary
    }

    /// "Fri, Oct 23 · 3:00 PM" + link line, matching Lazy's extras shape.
    static func meetingExtras(_ meeting: MeetingDetails) -> [String] {
        var extras: [String] = []
        if meeting.date != nil || meeting.time != nil {
            extras.append([meeting.date, meeting.time].compactMap { $0 }.joined(separator: " · "))
        }
        if let link = meeting.link {
            extras.append(link)
        }
        return extras
    }

    // MARK: - The one-call classify

    static func classify(sender: String, subject: String, body: String, now: Date = Date()) -> MailClassification {
        let school = detectSchool(sender: sender, subject: subject, body: body)
        let timeSensitive = hasRecognizableDate(in: body) || hasRecognizableTime(in: body)
        let meeting = extractMeetingDetails(body: body)
        // Lazy: an event needs cue words AND an extracted date (start_at).
        let eventCues = eventPatterns.contains { matches($0.regex, in: body) }
        let hasEvent = eventCues && meeting.date != nil
        let urgencyResult = urgency(in: subject + "\n" + body)
        // M4.5c: a zone written beside the time means those components belong
        // to the MAIL's zone, not the user's — resolve the instant there and
        // remember the label for the card. If the id can't be resolved, fall
        // back to local and show no label rather than claim a conversion we
        // didn't make.
        let zoneMatch = extractTimezone(text: body)
        let sourceZone = zoneMatch.flatMap { TimeZone(identifier: $0.zoneID) }
        return MailClassification(
            isSchool: school.isSchool,
            schoolReason: school.reason,
            isTimeSensitive: timeSensitive,
            hasEvent: hasEvent,
            urgencyLevel: urgencyResult.level,
            urgencyConfidence: urgencyResult.confidence,
            urgencyReasons: urgencyResult.reasons,
            meeting: meeting,
            meetingStart: eventStart(in: body, hasEvent: hasEvent, now: now, sourceZone: sourceZone),
            meetingZoneLabel: sourceZone == nil ? nil : zoneMatch?.label
        )
    }

    // MARK: - Event start / due time (extraction.py `_extract_date`/`_extract_time` + orchestrator `due_at`, ported)

    /// Lazy `_mail_to_board`'s due time came from the DETERMINISTIC
    /// pipeline (`extraction.analyze(..., prefer_model=False)` — no model
    /// call on the mail path): `start_at = f"{date}T{time or '00:00'}"`,
    /// kept only when `has_event`. Rules ported verbatim: today/tomorrow →
    /// now; weekday → next occurrence; month name (full or abbreviated) +
    /// day → current year, +1 year when already past (a year written in the
    /// mail is IGNORED — Lazy's regexes never captured one); 12h time
    /// first, then `at HH:MM` 24h; no time → 00:00. `extract_meeting_details`
    /// never fed this — its date/time strings remain display-only.
    static func eventStart(in body: String, hasEvent: Bool, now: Date, sourceZone: TimeZone? = nil) -> Date? {
        guard hasEvent else { return nil }
        guard let datePart = extractStartDate(text: body, now: now) else { return nil }
        let timePart = extractStartTime(text: body) ?? "00:00"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // M4.5c: when the mail states its own zone ("4:15 PM ET") the parsed
        // components belong to THAT zone — materialising them in `.current`
        // stamped a US school's meeting time as the user's own and fired the
        // banner hours late. No zone written → local, exactly as Lazy did.
        formatter.timeZone = sourceZone ?? .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let start = formatter.date(from: "\(datePart)T\(timePart)") else { return nil }
        // Clicky-only guard Lazy never needed: Lazy returned early on
        // `_initial_sync` (backfill mail was never analysed), while Clicky
        // analyses it — a meeting that already started must not sit past-due
        // in the reminder table, where the 15 s scheduler would fire it as a
        // banner flood at connect instead of at the meeting itself.
        guard start > now else { return nil }
        return start
    }

    // MARK: - Mail-stated timezone (M4.5c)

    /// Zone tokens, most specific first. Every code is case-insensitive
    /// ("4:15pm est" is common in real mail) and MUST sit directly after a
    /// clock time — `looksLikeTime` is strict about that, so a stray acronym
    /// or a URL elsewhere in the mail can never be mistaken for one.
    private static let zoneTokens: [(pattern: String, label: String, zoneID: String)] = [
        ( #"\beastern (?:standard |daylight )?time\b"#, "ET", "America/New_York" ),
        ( #"\bcentral (?:standard |daylight )?time\b"#, "CT", "America/Chicago" ),
        ( #"\bmountain (?:standard |daylight )?time\b"#, "MT", "America/Denver" ),
        ( #"\bpacific (?:standard |daylight )?time\b"#, "PT", "America/Los_Angeles" ),
        ( #"\bgreenwich (?:mean |standard )?time\b"#, "GMT", "UTC" ),
        ( #"\bET\b"#, "ET", "America/New_York" ),
        ( #"\bEST\b"#, "ET", "America/New_York" ),
        ( #"\bEDT\b"#, "ET", "America/New_York" ),
        ( #"\bCT\b"#, "CT", "America/Chicago" ),
        ( #"\bCST\b"#, "CT", "America/Chicago" ),
        ( #"\bCDT\b"#, "CT", "America/Chicago" ),
        ( #"\bMT\b"#, "MT", "America/Denver" ),
        ( #"\bMST\b"#, "MT", "America/Denver" ),
        ( #"\bMDT\b"#, "MT", "America/Denver" ),
        ( #"\bPT\b"#, "PT", "America/Los_Angeles" ),
        ( #"\bPST\b"#, "PT", "America/Los_Angeles" ),
        ( #"\bPDT\b"#, "PT", "America/Los_Angeles" ),
        ( #"\bUTC\b"#, "UTC", "UTC" ),
        ( #"\bGMT\b"#, "GMT", "UTC" ),
        ( #"\bBST\b"#, "BST", "Europe/London" ),
        ( #"\bWAT\b"#, "WAT", "Africa/Lagos" )
    ]

    /// Compiled once at first use, not per call (M4.5d): the freeze fix. The
    /// first version compiled all 21 patterns inside `extractTimezone`, i.e.
    /// 21 NSRegularExpression compilations + full-body scans on the MAIN
    /// thread for every synced message — one large mail body could beachball
    /// the app mid-question. Same patterns, same order, same results.
    private static let compiledZoneTokens: [(regex: NSRegularExpression, label: String, zoneID: String)] =
        zoneTokens.compactMap { token in
            guard let regex = try? NSRegularExpression(pattern: token.pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, token.label, token.zoneID)
        }

    /// M4.5c — an explicit timezone written beside a meeting time. Returns the
    /// short label for display plus the zone to materialise the instant in.
    static func extractTimezone(text: String) -> (label: String, zoneID: String)? {
        for token in compiledZoneTokens {
            let regex = token.regex
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let beforeZone = text[text.startIndex..<matchRange.lowerBound]
                let lookback = beforeZone.count > 16 ? String(beforeZone.suffix(16)) : String(beforeZone)
                if looksLikeTime(lookback) {
                    return (token.label, token.zoneID)
                }
            }
        }
        return nil
    }

    private static let timeTokenRegex = try? NSRegularExpression(
        pattern: #"^\d{1,2}[:.]\d{2}(?:\s*[ap]\.?m\.?)?$|^\d{1,2}\s*[ap]\.?m\.?$"#,
        options: [.caseInsensitive]
    )

    /// The trailing words before the zone token must BE a clock time
    /// ("4:15 pm", "16:15", "4pm"). Deliberately strict: the naive "has a
    /// digit and a colon" test would let a URL (".../2026/est") or a date be
    /// read as a timezone and corrupt the parse Lazy's harness verified.
    private static func looksLikeTime(_ snippet: String) -> Bool {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop trailing punctuation so "4:15 pm," still reads as a time.
        let stripped = String(trimmed.reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
        let tokens = stripped.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let lastToken = tokens.last else { return false }
        // "…at 4:15 pm" → the time spans the last two tokens; "…at 16:15" → one.
        return [tokens.suffix(2).joined(separator: " "), lastToken].contains { candidate in
            guard let regex = timeTokenRegex else { return false }
            return regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
        }
    }

    private static let weekdayNumbers: [String: Int] = [
        "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
        "friday": 4, "saturday": 5, "sunday": 6
    ]
    private static let monthNumbers: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    /// extraction.py `_extract_date` — value port (its ambiguity flags only
    /// fed Lazy's confidence, never the due date itself).
    static func extractStartDate(text: String, now: Date) -> String? {
        let lowered = text.lowercased()
        let calendar = Calendar.current
        if lowered.range(of: #"\btoday\b"#, options: .regularExpression) != nil {
            return isoDateOnly(now)
        }
        if lowered.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil,
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            return isoDateOnly(tomorrow)
        }
        // Weekday → next occurrence: Python `(idx - now.weekday()) % 7 or 7`.
        // Calendar.weekday is Sunday=1…Saturday=7; Python is Monday=0…Sunday=6
        // — so py = (cal + 5) % 7 (harness caught the off-by-one here).
        let todayIndex = (calendar.component(.weekday, from: now) + 5) % 7  // 0 = Monday
        for (name, index) in weekdayNumbers {
            guard lowered.range(of: "\\b\(name)\\b", options: .regularExpression) != nil else { continue }
            var delta = ((index - todayIndex) % 7 + 7) % 7
            if delta == 0 { delta = 7 }
            guard let next = calendar.date(byAdding: .day, value: delta, to: now) else { return nil }
            return isoDateOnly(next)
        }
        // Month + day: full month names first, then Lazy's abbreviated form
        // — stated year never captured (no year group in either regex).
        let monthPatterns = [
            #"\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})\b"#,
            #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})\b"#
        ]
        for pattern in monthPatterns {
            let nsPattern = regex(pattern)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = nsPattern.firstMatch(in: text, options: [], range: range),
                  let monthText = group(1, match, text),
                  let dayText = group(2, match, text),
                  let month = monthNumbers[String(monthText).prefix(3).lowercased()],
                  let day = Int(dayText) else { continue }
            var comps = DateComponents()
            comps.year = calendar.component(.year, from: now)
            comps.month = month
            comps.day = day
            // Invalid dates (Feb 30) → nil, exactly as Python's ValueError
            // returned "date could not be validated".
            guard let candidate = calendar.date(from: comps) else { return nil }
            var year = comps.year!
            if calendar.startOfDay(for: candidate) < calendar.startOfDay(for: now) {
                year += 1  // "month/day in the past this year; assumed next year"
            }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return nil
    }

    /// extraction.py `_extract_time` — value port (12h first, then Lazy's
    /// `at HH:MM` 24h form; no range validation — out-of-range values fall
    /// out of the date parse upstream exactly as Python's `fromisoformat`
    /// raised and left due_at unset).
    static func extractStartTime(text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        let timeRE = regex(#"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\b"#)
        if let match = timeRE.firstMatch(in: text, options: [], range: range),
           let hourText = group(1, match, text),
           let ampm = group(3, match, text) {
            var hour = Int(hourText) ?? 0
            let minute = group(2, match, text).flatMap { Int($0) } ?? 0
            let suffix = ampm.lowercased().replacingOccurrences(of: ".", with: "")
            if suffix == "pm", hour != 12 { hour += 12 }
            if suffix == "am", hour == 12 { hour = 0 }
            return String(format: "%02d:%02d", hour, minute)
        }
        let time24RE = regex(#"\b(?:at\s+)([01]?\d|2[0-3]):([0-5]\d)\b"#)
        if let match = time24RE.firstMatch(in: text, options: [], range: range),
           let hourText = group(1, match, text),
           let minuteText = group(2, match, text) {
            return String(format: "%02d:", Int(hourText) ?? 0) + minuteText
        }
        return nil
    }

    private static func isoDateOnly(_ date: Date) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    // MARK: - Regex plumbing

    private static func matches(_ regexPattern: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regexPattern.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func firstGroup(of pattern: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, options: [], range: range) else { return nil }
        return group(1, match, text)
    }

    private static func group(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func replacing(in text: String, pattern: String, with template: String) -> String {
        guard let regexPattern = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regexPattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func trimmedURL(_ url: String) -> String {
        String(url.reversed().drop(while: { ".,);>".contains($0) }).reversed())
    }
}
