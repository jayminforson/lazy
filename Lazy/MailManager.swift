//
//  MailManager.swift
//  Clicky
//
//  M6.1 — ties mail together: connect/disconnect (browser OAuth), the 90 s
//  sync loop with cursors + exponential backoff + retention purge, and the
//  published per-provider status Home → Settings shows. Port of Lazy's
//  Phase 4 sync service (QTimer poll → Task loop here).
//

import Combine
import Foundation

@MainActor
final class MailManager: ObservableObject {

    // MARK: - Published status (Settings card)

    struct ProviderStatus {
        var isConnected = false
        var email = ""
        var lastSyncAt: Date?
        var messageCount = 0
        var isSyncing = false
        var isConnecting = false
        var lastErrorText: String?
    }

    @Published private(set) var gmailStatus = ProviderStatus()
    @Published private(set) var outlookStatus = ProviderStatus()

    func status(for provider: MailProvider) -> ProviderStatus {
        switch provider {
        case .gmail: return gmailStatus
        case .outlook: return outlookStatus
        }
    }

    // MARK: - Tunables (Lazy's config defaults)

    static let pollIntervalSeconds: TimeInterval = 90
    static let initialLookbackDays = 7
    static let maxNewMessagesPerSync = 60
    static let bodyRetentionDays = 30

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Pieces

    private let store = MailStore()
    private let gmail = GmailClient()
    private let outlook = OutlookClient()
    private var pollTask: Task<Void, Never>?
    private var syncingProviders: Set<MailProvider> = []
    private var connectingProviders: Set<MailProvider> = []
    private var lastErrors: [MailProvider: String] = [:]

    /// M6.3: the 15 s reminder ticker (Lazy's scheduler.py port).
    private(set) lazy var reminderScheduler = ReminderScheduler(store: store)

    // MARK: - Lifecycle

    func start() {
        store.open()
        restoreAccountStates()
        startPolling()
        reminderScheduler.start()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        reminderScheduler.stop()
        store.close()
    }

    private func restoreAccountStates() {
        for provider in MailProvider.allCases {
            publishState(for: provider)
            let row = store.account(for: provider)
            if row?.status == "connected", MailOAuthService.storedTokens(for: provider) == nil {
                // Account row without a Keychain token (e.g. token deleted
                // externally) — the user must re-connect.
                store.setAccountStatus("disconnected", for: provider)
                lastErrors[provider] = "Needs reconnecting — tokens are gone."
                print("📧 Mail(\(provider.rawValue)): connected row without tokens → marked disconnected")
                publishState(for: provider)
            }
        }
    }

    // MARK: - Connect / disconnect

    func connect(_ provider: MailProvider) {
        guard !connectingProviders.contains(provider), !isConnected(provider) else { return }
        connectingProviders.insert(provider)
        lastErrors[provider] = nil
        publishState(for: provider)
        print("📧 Mail(\(provider.rawValue)): starting browser sign-in")

        Task {
            let tokens = await MailOAuthService.connect(provider)
            connectingProviders.remove(provider)
            guard let tokens else {
                lastErrors[provider] = "Sign-in was cancelled or didn't finish."
                publishState(for: provider)
                return
            }
            let profile = await fetchProfile(provider, accessToken: tokens.accessToken)
            let email = profile ?? "(address unknown)"
            store.upsertConnectedAccount(provider: provider, email: email)
            print("📧 Mail(\(provider.rawValue)): connected as \(email)")
            publishState(for: provider)
            await syncProvider(provider)
        }
    }

    func disconnect(_ provider: MailProvider) {
        print("📧 Mail(\(provider.rawValue)): disconnecting — revoking + wiping local rows")
        MailOAuthService.revoke(provider)
        MailOAuthService.deleteTokens(for: provider)
        store.setAccountStatus("disconnected", for: provider)
        store.setSyncCursor(nil, for: provider)
        lastErrors[provider] = nil
        publishState(for: provider)
    }

    /// Explicit "sync now" (retry button in Settings; also fires right
    /// after connect).
    func syncNow(_ provider: MailProvider) {
        Task { await syncProvider(provider) }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                for provider in MailProvider.allCases {
                    guard isConnected(provider), !syncingProviders.contains(provider) else { continue }
                    if shouldSkipForBackoff(provider) { continue }
                    await syncProvider(provider)
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    /// Failures back the poll off: 90 s × 2^failures, capped at 15 min.
    private func shouldSkipForBackoff(_ provider: MailProvider) -> Bool {
        let state = store.syncState(for: provider)
        guard state.consecutiveFailures > 0, let lastPolled = state.lastPolledAt else { return false }
        let backoff = min(Self.pollIntervalSeconds * pow(2, Double(min(state.consecutiveFailures, 4))), 900)
        return Date().timeIntervalSince(lastPolled) < backoff
    }

    // MARK: - Sync

    private func syncProvider(_ provider: MailProvider) async {
        guard isConnected(provider), !syncingProviders.contains(provider) else { return }
        guard let tokens = await MailOAuthService.validTokens(for: provider) else {
            noteLastError(provider, "Token refresh failed — reconnect in Home → Settings → Mail")
            store.recordSyncPoll(provider: provider, succeeded: false)
            publishState(for: provider)
            return
        }

        syncingProviders.insert(provider)
        publishState(for: provider)
        defer {
            syncingProviders.remove(provider)
            publishState(for: provider)
        }

        // First-ever sync for this account = backfill: analyse silently,
        // never banner (Lazy's `_initial_sync` rule).
        let isBackfill = store.account(for: provider)?.lastSyncAt == nil
        let state = store.syncState(for: provider)
        var messageIDs: [String] = []
        // Normalize a NULL *or* blank cursor to nil: `nextCursor == nil` is
        // what triggers the seeding listing below, so a blank cursor must not
        // slip past it into a do-nothing sync that still reports success.
        var nextCursor: String? = (state.cursor?.isEmpty ?? true) ? nil : state.cursor

        switch provider {
        case .gmail:
            if let cursor = state.cursor, !cursor.isEmpty {
                let history = await gmail.historyChanges(accessToken: tokens.accessToken, startHistoryID: cursor)
                if history.failed {
                    // M6.10: a failed history call is NOT "no changes" — record
                    // a failed poll (→ backoff + last-error chip) and keep the
                    // cursor so the next pass retries the same window instead
                    // of silently skipping mail.
                    noteSyncFailure(provider, "Gmail sync failed — will retry")
                    return
                }
                if history.cursorTooOld {
                    nextCursor = nil  // fall through to a fresh listing below
                } else {
                    nextCursor = history.nextCursor
                    messageIDs = history.messageIDs
                }
            }
            if nextCursor == nil {
                // No cursor yet (first sync) or the history cursor aged out:
                // do the bounded recent-listing and re-seed the cursor.
                let lookbackDate = Calendar.current.date(
                    byAdding: .day, value: -Self.initialLookbackDays, to: Date()
                ) ?? Date().addingTimeInterval(-7 * 86_400)
                let listing = await gmail.recentListing(accessToken: tokens.accessToken, since: lookbackDate)
                if listing.failed {
                    // M6.10: before this, an errored listing looked like a
                    // successful empty sync — mail stopped arriving while
                    // Settings kept showing "synced".
                    noteSyncFailure(provider, "Gmail listing failed — will retry")
                    return
                }
                messageIDs = listing.messageIDs
                if let historyID = listing.historyID {
                    if state.cursor?.isEmpty ?? true {
                        print("📧 Mail(\(provider.rawValue)): cursor seeded — incremental sync from now on")
                    }
                    nextCursor = historyID
                }
            }
        case .outlook:
            let since = state.lastPolledAt ?? Calendar.current.date(
                byAdding: .day, value: -Self.initialLookbackDays, to: Date()
            ) ?? Date().addingTimeInterval(-7 * 86_400)
            messageIDs = await outlook.recentMessageIDs(accessToken: tokens.accessToken, since: since)
            nextCursor = Self.isoFormatter.string(from: Date())
        }

        messageIDs = Array(messageIDs.prefix(Self.maxNewMessagesPerSync))

        var newCount = 0
        var unfetchedIDs: [String] = []
        for messageID in messageIDs {
            if Task.isCancelled { return }
            // M6.10: skip ids already stored BEFORE spending an API call on
            // them — the old loop re-fetched up to 60 known messages every
            // 90 s, exhausting the free quota (which then failed silently).
            if store.messageExists(provider: provider, providerID: messageID) { continue }
            let message: MailStoreMessage?
            switch provider {
            case .gmail:
                message = await gmail.fetchMessage(accessToken: tokens.accessToken, id: messageID)
            case .outlook:
                message = await outlook.fetchMessage(accessToken: tokens.accessToken, id: messageID)
            }
            if let message, store.insertMessageIfNew(message) {
                newCount += 1
                await analyzeNewMessage(message, notifyAllowed: !isBackfill)
            } else if message == nil {
                unfetchedIDs.append(messageID)
            }
        }

        // M6.10: one bounded retry for ids whose fetch failed. The cursor is
        // written after this pass, so a transient blip that dropped a message
        // here would otherwise lose it forever (the school email that never
        // shows up). A still-failing id is logged by authorizedGet and left
        // to the next listing — we never stall the cursor on it, because a
        // permanently-gone message would wedge sync permanently.
        if !unfetchedIDs.isEmpty, !Task.isCancelled {
            print("📧 Mail(\(provider.rawValue)): retrying \(unfetchedIDs.count) failed fetch(es)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for messageID in unfetchedIDs {
                if Task.isCancelled { break }
                if store.messageExists(provider: provider, providerID: messageID) { continue }
                let message: MailStoreMessage?
                switch provider {
                case .gmail:
                    message = await gmail.fetchMessage(accessToken: tokens.accessToken, id: messageID)
                case .outlook:
                    message = await outlook.fetchMessage(accessToken: tokens.accessToken, id: messageID)
                }
                if let message, store.insertMessageIfNew(message) {
                    newCount += 1
                    await analyzeNewMessage(message, notifyAllowed: !isBackfill)
                }
            }
        }

        if let nextCursor {
            store.setSyncCursor(nextCursor, for: provider)
        }
        store.setLastSync(provider: provider, date: Date())
        store.recordSyncPoll(provider: provider, succeeded: true)
        store.purgeBodies(olderThanDays: Self.bodyRetentionDays)
        lastErrors[provider] = nil

        if newCount > 0 {
            print("📧 Mail(\(provider.rawValue)): +\(newCount) new — total \(store.messageCount(for: provider))")
        }
    }

    // MARK: - M6.2 analysis

    /// Lazy's `_on_mail_message`: classify every new message, cache a
    /// summary for board-worthy ones (school / time-sensitive / event),
    /// banner urgent mail — never on the backfill sync.
    private func analyzeNewMessage(_ message: MailStoreMessage, notifyAllowed: Bool) async {
        let trimmedBody = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmedBody.isEmpty ? message.subject : trimmedBody
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let sender = message.senderEmail ?? message.senderName ?? ""
        let classification = MailClassifier.classify(sender: sender, subject: message.subject, body: body)

        var summary = ""
        if classification.shouldBoard {
            summary = await MailSummarizer.summarize(
                subject: message.subject,
                body: body,
                meeting: classification.meeting
            )
        }
        store.applyAnalysis(
            provider: message.provider,
            providerID: message.providerID,
            isSchool: classification.isSchool,
            isTimeSensitive: classification.isTimeSensitive,
            hasEvent: classification.hasEvent,
            summary: summary.isEmpty ? nil : summary
        )
        print("📧 classify(\(message.provider.rawValue)): school=\(classification.isSchool) time=\(classification.isTimeSensitive) event=\(classification.hasEvent) urgency=\(classification.urgencyLevel)/\(String(format: "%.2f", classification.urgencyConfidence)) board=\(classification.shouldBoard) — \(message.subject.prefix(60))")

        if classification.shouldBoard {
            mailToBoard(message, classification, summary: summary)
        }

        guard notifyAllowed else { return }
        await maybeBannerUrgent(message, classification)
    }

    /// Lazy's `_notify_urgent_mail`: high urgency + not a bulk sender,
    /// 30-min dedupe via notification_log, quiet hours checked BEFORE
    /// claiming the dedupe key so the banner still fires on the first poll
    /// after quiet hours end.
    private func maybeBannerUrgent(_ message: MailStoreMessage, _ classification: MailClassification) async {
        guard classification.shouldBanner else { return }
        let sender = message.senderEmail ?? message.senderName ?? "unknown"
        guard !MailClassifier.isBulkSender(sender) else { return }
        guard !MailNotifier.inQuietHours() else {
            print("📧 banner skipped (quiet hours): \(message.subject.prefix(50))")
            return
        }
        let dedupeKey = "mail:\(message.provider.rawValue):\(message.providerID)"
        guard store.shouldFireNotification(dedupeKey: dedupeKey, withinMinutes: 30) else { return }
        store.recordNotification(dedupeKey: dedupeKey)
        let reasons = classification.urgencyReasons.prefix(2).joined(separator: ", ")
        let preview = String(message.body.prefix(100))
        await MailNotifier.notify(
            title: "📧 \(message.subject)",
            body: "From: \(sender)\n\(reasons)\n\(preview)",
            subtitle: "Urgent mail"
        )
        print("📧 banner fired: \(message.subject.prefix(50)) (\(classification.urgencyLevel), conf \(String(format: "%.2f", classification.urgencyConfidence)))")
    }

    // MARK: - M6.3 board API (chat intents + the sticky board drive these)

    /// Lazy's `_mail_to_board`: board-worthy mail becomes a sticky reminder
    /// tagged by WHY it landed (🏫 school > 📅 event > ⏰ time-sensitive),
    /// deduped by provider id so resyncs never double-post. Event mail also
    /// carries a real due time (M6.6) — the ⏰ scheduler banners it when the
    /// meeting starts, exactly as Lazy's start_at did.
    private func mailToBoard(_ message: MailStoreMessage, _ classification: MailClassification, summary: String) {
        let tag = classification.isSchool ? "🏫" : (classification.hasEvent ? "📅" : "⏰")
        var title = message.subject
        if title.count > 70 {
            title = String(title.prefix(67)) + "…"
        }
        var parts: [String] = []
        let senderDisplay = message.senderName ?? message.senderEmail ?? ""
        if !senderDisplay.isEmpty {
            parts.append("From: \(senderDisplay)")
        }
        parts.append("Received: \(message.receivedAt.formatted(date: .abbreviated, time: .shortened))")
        if classification.meeting.date != nil || classification.meeting.time != nil {
            let when = [classification.meeting.date, classification.meeting.time].compactMap { $0 }.joined(separator: " · ")
            parts.append("When: \(when)")
        }
        if let link = classification.meeting.link {
            parts.append("Join → \(link)")
        }
        if !summary.isEmpty {
            parts.append(summary)
        }
        store.addReminder(
            title: "\(tag) \(title)",
            note: parts.joined(separator: "\n"),
            dueAt: classification.meetingStart,
            dedupeKey: "mail:\(message.provider.rawValue):\(message.providerID)",
            receivedAt: message.receivedAt
        )
        let dueLine = classification.meetingStart
            .map { " due \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        print("🗒 Board: +mail card \(tag) \(title.prefix(40))\(dueLine)")
    }

    func addTodoItem(title: String, dueAt: Date? = nil, details: String? = nil) {
        store.addTodo(title: title, dueAt: dueAt, details: details, reminderID: nil)
        print("🗒 Board: +todo \"\(title.prefix(50))\"")
    }

    func addReminderItem(title: String, note: String? = nil, dueAt: Date? = nil) {
        store.addReminder(title: title, note: note, dueAt: dueAt, dedupeKey: nil)
        print("🗒 Board: +reminder \"\(title.prefix(50))\"")
    }

    func boardTodos() -> [MailStore.BoardTodoRow] {
        store.listBoardTodos()
    }

    func boardReminders() -> [MailStore.BoardReminderRow] {
        store.listBoardReminders()
    }

    /// M6.11: mail cards, newest-received first (the board's top group).
    func boardMailReminders() -> [MailStore.BoardReminderRow] {
        store.listBoardMailReminders()
    }

    func setBoardItemDone(kind: String, id: Int64, done: Bool) {
        if kind == "reminder" {
            store.setReminderState(done ? "completed" : "open", id: id)
        } else {
            store.setTodoState(done ? "completed" : "open", id: id)
        }
    }

    func editBoardItemTitle(kind: String, id: Int64, title: String) {
        if kind == "reminder" {
            store.updateReminderTitle(title, id: id)
        } else {
            store.updateTodoTitle(title, id: id)
        }
    }

    func deleteBoardItem(kind: String, id: Int64) {
        if kind == "reminder" {
            store.setReminderState("deleted", id: id)
        } else {
            store.setTodoState("deleted", id: id)
        }
    }

    func snoozeBoardReminder(id: Int64, minutes: Int) {
        store.snoozeReminder(id: id, until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    // MARK: - M6.4 draft lifecycle (Lazy's DraftService port)

    /// A generated reply parked for approval — the notch sheet's card and
    /// the M5.3 yes/no both act on this. Nil = nothing pending.
    struct MailDraft: Identifiable {
        let id: Int64
        let provider: MailProvider
        let toName: String
        let toAddresses: [String]
        let subject: String
        let body: String
    }

    @Published var pendingDraft: MailDraft?

    enum ReplyDraftOutcome {
        case parked(MailDraft)
        case failed(String)
    }

    /// "reply to X [saying …]" — newest matching message → Gemini fast
    /// draft → parked (approval card + M5.3 yes/no). Never sends alone.
    func createReplyDraft(matching query: String, instruction: String) async -> ReplyDraftOutcome {
        guard let message = store.latestMessage(matching: query) else {
            return .failed("I couldn't find an email matching \(query).")
        }
        guard let tokens = await MailOAuthService.validTokens(for: message.provider) else {
            return .failed("Mail isn't connected anymore — reconnect it in Home → Settings → Mail.")
        }
        _ = tokens  // the token check IS the guard; sending re-fetches.
        guard let toEmail = message.senderEmail ?? EmailDraftService.extractReplyAddress(from: message.senderName ?? "") else {
            return .failed("That email had no reply address.")
        }

        let body = await EmailDraftService.generateReplyBody(
            originalSubject: message.subject,
            originalBody: message.body,
            userInstruction: instruction
        )
        let subject = message.subject.lowercased().hasPrefix("re: ") ? message.subject : "Re: \(message.subject)"
        guard let draftID = store.createDraft(
            provider: message.provider.rawValue,
            toAddresses: [toEmail],
            subject: subject,
            body: body,
            originalMessageRef: "\(message.provider.rawValue):\(message.providerID)"
        ) else {
            return .failed("Saving the draft failed.")
        }

        let draft = MailDraft(
            id: draftID,
            provider: message.provider,
            toName: message.senderName ?? toEmail,
            toAddresses: [toEmail],
            subject: subject,
            body: body
        )
        pendingDraft = draft
        store.recordAudit(action: "draft_created", detail: "draft:\(draftID) → \(toEmail)", result: String(body.prefix(80)))
        print("📧 Draft \(draftID) created for \(toEmail)")
        return .parked(draft)
    }

    /// Lazy's approve → send: the approval binds the exact body's hash,
    /// send re-verifies it (an edit in between = reject + audit), then the
    /// provider call. Returns the line to speak.
    func sendDraft(_ draftID: Int64) async -> String {
        guard let row = store.draftRow(id: draftID) else {
            pendingDraft = nil
            return "That draft is gone."
        }
        if row.status == "sent" {
            pendingDraft = nil
            return "That reply already went out."
        }
        if row.status == "discarded" {
            pendingDraft = nil
            return "That draft was discarded."
        }
        guard row.status == "pending" else {
            return "That draft isn't ready to send."
        }

        // Approve with the exact-content hash (Lazy's F-13 binding), then
        // verify the stored body still hashes to it before sending.
        store.approveDraft(id: draftID, hash: EmailDraftService.hashDraft(row.body))
        guard let approved = store.draftRow(id: draftID),
              approved.bodyHash == EmailDraftService.hashDraft(approved.body)
        else {
            store.recordAudit(action: "draft_send_rejected", detail: "draft:\(draftID)", result: "content_mismatch")
            print("📧 draft \(draftID) send rejected — content changed since approval")
            return "The draft changed since you approved it — I didn't send it."
        }

        let toName = pendingDraft?.toName ?? (approved.toAddresses.first ?? "them")
        guard let provider = MailProvider(rawValue: approved.provider),
              let tokens = await MailOAuthService.validTokens(for: provider)
        else {
            store.recordAudit(action: "draft_send_failed", detail: "draft:\(draftID)", result: "no_tokens")
            return "Mail isn't connected anymore — I couldn't send it."
        }

        let sent: Bool
        switch provider {
        case .gmail:
            let rfc822 = """
            To: \(approved.toAddresses.joined(separator: ", "))\r\n\
            Subject: \(approved.subject)\r\n\
            Content-Type: text/plain; charset="UTF-8"\r\n\
            \r\n\
            \(approved.body)
            """
            sent = await gmail.send(accessToken: tokens.accessToken, rfc822: rfc822)
        case .outlook:
            let messageJSON: [String: Any] = [
                "subject": approved.subject,
                "body": ["contentType": "Text", "content": approved.body],
                "toRecipients": approved.toAddresses.map { ["emailAddress": ["address": $0]] }
            ]
            sent = await outlook.send(accessToken: tokens.accessToken, messageJSON: messageJSON)
        }

        if sent {
            store.markDraftSent(id: draftID)
            store.recordAudit(action: "draft_sent", detail: "draft:\(draftID) → \(approved.toAddresses.joined(separator: ", "))", result: "\(provider.rawValue):sent")
            pendingDraft = nil
            print("📧 Draft \(draftID) sent via \(provider.rawValue)")
            return "Sent to \(toName)."
        }
        store.recordAudit(action: "draft_send_failed", detail: "draft:\(draftID)", result: "\(provider.rawValue)_send_failed")
        print("📧 Draft \(draftID) send failed via \(provider.rawValue)")
        return "Sending failed — \(provider.rawValue) didn't accept it. The draft is still on the card if you want to retry."
    }

    func discardDraft(_ draftID: Int64) {
        store.discardDraft(id: draftID)
        store.recordAudit(action: "draft_discarded", detail: "draft:\(draftID)", result: "user")
        print("📧 Draft \(draftID) discarded")
        pendingDraft = nil
    }

    /// "check my email" — 24 h digest with the M6.2 flags surfaced.
    func mailDigestLine() -> String {
        let connected = [MailProvider.gmail, MailProvider.outlook].filter { isConnected($0) }
        guard !connected.isEmpty else {
            return "Mail isn't connected yet — connect it in Home → Settings → Mail."
        }
        let rows = store.recentDigestRows(sinceHours: 24, limit: 5)
        print("📧 digest: \(rows.count) messages in the last 24h")
        guard !rows.isEmpty else {
            return "No new mail in the last 24 hours."
        }
        var lines = ["Here's your mail from the last 24 hours:"]
        for (index, row) in rows.enumerated() {
            var bullet = "\(index + 1). \(row.subject.isEmpty ? "(no subject)" : row.subject)"
            if !row.senderDisplay.isEmpty {
                bullet += " from \(row.senderDisplay)"
            }
            if row.isUrgent {
                bullet += " — urgent"
            } else if row.isTimeSensitive {
                bullet += " — time-sensitive"
            }
            lines.append(bullet)
        }
        return lines.joined(separator: " ")
    }

    /// M6.4 — compact recent-mail block for brain prompts: the assistant
    /// can answer "did the professor write?" without a separate tool.
    /// Nil when nothing is connected or nothing recent exists (zero bytes).
    func mailAwarenessBlock() -> String? {
        guard [MailProvider.gmail, MailProvider.outlook].contains(where: { isConnected($0) }) else { return nil }
        let rows = store.recentDigestRows(sinceHours: 48, limit: 5)
        guard !rows.isEmpty else { return nil }
        var lines = ["Recent email (last 48h):"]
        for row in rows {
            var line = "· \(row.subject.isEmpty ? "(no subject)" : row.subject) — \(row.senderDisplay.isEmpty ? "unknown sender" : row.senderDisplay)"
            if let summary = row.summary, !summary.isEmpty {
                line += " | \(String(summary.prefix(160)))"
            }
            lines.append(line)
        }
        lines.append("The user can say \"check my email\" for the full digest, or \"reply to <name>\" (optionally \"saying <instruction>\") to draft a reply, which always waits for their approval.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func fetchProfile(_ provider: MailProvider, accessToken: String) async -> String? {
        switch provider {
        case .gmail: return await gmail.fetchProfile(accessToken: accessToken)
        case .outlook: return await outlook.fetchProfile(accessToken: accessToken)
        }
    }

    private func isConnected(_ provider: MailProvider) -> Bool {
        store.account(for: provider)?.status == "connected"
    }

    private func noteLastError(_ provider: MailProvider, _ text: String) {
        print("📧 Mail(\(provider.rawValue)): ⚠️ \(text)")
        lastErrors[provider] = text
    }

    /// M6.10: a real sync failure — surface it (error chip + console), count
    /// it for backoff, and refresh the Settings card. Without this the old
    /// code recorded errored listings as successes, so mail silently stopped
    /// arriving while Settings kept showing "synced".
    private func noteSyncFailure(_ provider: MailProvider, _ text: String) {
        noteLastError(provider, text)
        store.recordSyncPoll(provider: provider, succeeded: false)
        publishState(for: provider)
    }

    private func publishState(for provider: MailProvider) {
        let row = store.account(for: provider)
        var status = ProviderStatus()
        status.isConnected = row?.status == "connected"
        status.email = row?.email ?? ""
        status.lastSyncAt = row?.lastSyncAt
        status.messageCount = store.messageCount(for: provider)
        status.isSyncing = syncingProviders.contains(provider)
        status.isConnecting = connectingProviders.contains(provider)
        status.lastErrorText = lastErrors[provider]
        switch provider {
        case .gmail: gmailStatus = status
        case .outlook: outlookStatus = status
        }
    }
}
