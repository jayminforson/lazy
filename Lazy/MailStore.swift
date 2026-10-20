//
//  MailStore.swift
//  Clicky
//
//  M6.1 — SQLite persistence for the mail/reminder stack (Lazy's Phase 4/9
//  schema, subset). System SQLite (no dependency): account, message,
//  sync_state, notification_log, draft, reminder, todo, action_audit — the
//  tables M6.2–M6.4 will fill; M6.1 uses account/message/sync_state.
//  DB lives in Application Support: mail.db (WAL).
//

import Foundation
import SQLite3

final class MailStore {

    /// SQLITE_TRANSIENT copy semantics for Swift string binds.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var databaseDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yourcompany.leanring-buddy", isDirectory: true)
    }

    var databasePath: String {
        databaseDirectoryURL.appendingPathComponent("mail.db").path
    }

    // MARK: - Lifecycle

    func open() {
        try? FileManager.default.createDirectory(at: databaseDirectoryURL, withIntermediateDirectories: true)
        if sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            print("📧 MailStore: cannot open \(databasePath)")
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        migrateIfNeeded()
        print("📧 MailStore: open at \(databasePath)")
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func migrateIfNeeded() {
        if currentVersion() < 1 {
            // v1 — full schema (all tables created so later milestones only
            // add methods, never migrations, for the initial wave).
            exec("""
        CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS account (
            provider TEXT PRIMARY KEY,
            email TEXT,
            status TEXT NOT NULL DEFAULT 'disconnected',
            scopes TEXT DEFAULT '[]',
            last_sync_at TEXT
        );
        CREATE TABLE IF NOT EXISTS message (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            thread_id TEXT,
            sender_name TEXT,
            sender_email TEXT,
            subject TEXT,
            body TEXT,
            received_at TEXT,
            is_school INTEGER NOT NULL DEFAULT 0,
            is_time_sensitive INTEGER NOT NULL DEFAULT 0,
            has_event INTEGER NOT NULL DEFAULT 0,
            is_urgent INTEGER NOT NULL DEFAULT 0,
            summary TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(provider, provider_id)
        );
        CREATE TABLE IF NOT EXISTS sync_state (
            provider TEXT PRIMARY KEY,
            cursor TEXT,
            last_polled_at TEXT,
            consecutive_failures INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS notification_log (
            id INTEGER PRIMARY KEY,
            dedupe_key TEXT NOT NULL,
            fired_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS draft (
            id INTEGER PRIMARY KEY,
            provider TEXT,
            to_addresses TEXT,
            subject TEXT,
            body TEXT,
            body_hash TEXT,
            original_message_id INTEGER,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS reminder (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            note TEXT,
            due_at TEXT,
            done INTEGER NOT NULL DEFAULT 0,
            sticky INTEGER NOT NULL DEFAULT 1,
            snoozed_until TEXT,
            last_notified_at TEXT,
            dedupe_key TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS todo (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            done INTEGER NOT NULL DEFAULT 0,
            reminder_id INTEGER,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS action_audit (
            id INTEGER PRIMARY KEY,
            action TEXT NOT NULL,
            detail TEXT,
            result TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        INSERT OR IGNORE INTO schema_version (version) VALUES (1);
        """)
        }
        if currentVersion() < 2 {
            // v2 — Lazy-aligned task tables for the sticky board (both were
            // still empty at this point): state-based lifecycle instead of
            // done flags; todo gains due_at/details/reminder_id to match
            // Lazy's repo semantics (open/snoozed/fired, claim + dedupe).
            exec("DROP TABLE IF EXISTS reminder; DROP TABLE IF EXISTS todo;")
            exec("""
            CREATE TABLE IF NOT EXISTS reminder (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                note TEXT,
                due_at TEXT,
                state TEXT NOT NULL DEFAULT 'open',
                snoozed_until TEXT,
                last_notified_at TEXT,
                dedupe_key TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT
            );
            CREATE TABLE IF NOT EXISTS todo (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'open',
                due_at TEXT,
                details TEXT,
                reminder_id INTEGER,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT,
                deleted_at TEXT
            );
            """)
            exec("UPDATE schema_version SET version = 2;")
        }
        if currentVersion() < 3 {
            // v3 — draft table: `original_message_id INTEGER` can't hold
            // provider message ids (both Gmail and Graph ids are strings);
            // the table was still empty (M6.4 not built), so recreate with
            // a TEXT ref instead of ALTERing.
            exec("DROP TABLE IF EXISTS draft;")
            exec("""
            CREATE TABLE IF NOT EXISTS draft (
                id INTEGER PRIMARY KEY,
                provider TEXT,
                to_addresses TEXT,
                subject TEXT,
                body TEXT,
                body_hash TEXT,
                original_message_ref TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            """)
            exec("UPDATE schema_version SET version = 3;")
        }
        if currentVersion() < 4 {
            // v4 — M6.11: mail cards sort newest-received-first at the top of
            // the board, so `reminder` needs the email's actual arrival time.
            // `created_at` is the *sync* moment — a backfill of old mail would
            // share one timestamp and order wrong. Additive ALTER (this table
            // has rows now, unlike v2/v3 — no DROP/recreate), then backfill the
            // cards already on the board from the message table via their
            // mail:<provider>:<provider_id> key so they place correctly at once.
            exec("ALTER TABLE reminder ADD COLUMN received_at TEXT;")
            exec("""
            UPDATE reminder SET received_at = (
                SELECT m.received_at FROM message m
                WHERE 'mail:' || m.provider || ':' || m.provider_id = reminder.dedupe_key
            ) WHERE dedupe_key LIKE 'mail:%' AND received_at IS NULL;
            """)
            exec("UPDATE schema_version SET version = 4;")
        }
    }

    private func currentVersion() -> Int {
        guard let statement = prepare("SELECT COALESCE(MAX(version), 0) FROM schema_version;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Exec / prepare plumbing

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let text = errorMessage.map { String(cString: $0) } ?? "?"
            print("📧 MailStore: exec failed — \(text)")
            sqlite3_free(errorMessage)
        }
        return result == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            print("📧 MailStore: prepare failed — \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return statement
    }

    // MARK: - Bind / column helpers

    private func bind(_ text: String?, to statement: OpaquePointer?, at index: Int32) {
        if let text {
            sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func textColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func dateColumn(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
        guard let text = textColumn(statement, index) else { return nil }
        return Self.isoFormatter.date(from: text)
    }

    // MARK: - Accounts

    struct AccountRow {
        let provider: MailProvider
        let email: String
        let status: String
        let lastSyncAt: Date?
    }

    func account(for provider: MailProvider) -> AccountRow? {
        guard let statement = prepare("SELECT provider, email, status, last_sync_at FROM account WHERE provider = ?;") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let providerValue = textColumn(statement, 0).flatMap({ MailProvider(rawValue: $0) }) else { return nil }
        return AccountRow(
            provider: providerValue,
            email: textColumn(statement, 1) ?? "",
            status: textColumn(statement, 2) ?? "disconnected",
            lastSyncAt: dateColumn(statement, 3)
        )
    }

    func upsertConnectedAccount(provider: MailProvider, email: String) {
        exec("""
        INSERT INTO account (provider, email, status)
        VALUES ('\(provider.rawValue)', '\(email.replacingOccurrences(of: "'", with: "''"))', 'connected')
        ON CONFLICT(provider) DO UPDATE SET email = excluded.email, status = 'connected';
        """)
    }

    func setLastSync(provider: MailProvider, date: Date) {
        guard let statement = prepare("UPDATE account SET last_sync_at = ? WHERE provider = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bind(Self.isoFormatter.string(from: date), to: statement, at: 1)
        bind(provider.rawValue, to: statement, at: 2)
        _ = sqlite3_step(statement) == SQLITE_DONE
    }

    func setAccountStatus(_ status: String, for provider: MailProvider) {
        exec("UPDATE account SET status = '\(status)' WHERE provider = '\(provider.rawValue)';")
    }

    // MARK: - Messages

    @discardableResult
    func insertMessageIfNew(_ message: MailStoreMessage) -> Bool {
        guard let statement = prepare("""
        INSERT OR IGNORE INTO message (provider, provider_id, thread_id, sender_name, sender_email, subject, body, received_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """) else { return false }
        defer { sqlite3_finalize(statement) }
        bind(message.provider.rawValue, to: statement, at: 1)
        bind(message.providerID, to: statement, at: 2)
        bind(message.threadID, to: statement, at: 3)
        bind(message.senderName, to: statement, at: 4)
        bind(message.senderEmail, to: statement, at: 5)
        bind(message.subject, to: statement, at: 6)
        bind(message.body, to: statement, at: 7)
        bind(Self.isoFormatter.string(from: message.receivedAt), to: statement, at: 8)
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    /// M6.10: cheap existence probe so a poll never re-fetches a message it
    /// already stored (the old loop fetched every id in the listing — up to
    /// 60 API calls per 90 s pass — which exhausted the free Gmail quota
    /// and silently stopped mail from arriving).
    func messageExists(provider: MailProvider, providerID: String) -> Bool {
        guard let statement = prepare("SELECT 1 FROM message WHERE provider = ? AND provider_id = ? LIMIT 1;") else { return false }
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: statement, at: 1)
        bind(providerID, to: statement, at: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func messageCount(for provider: MailProvider) -> Int {
        guard let statement = prepare("SELECT COUNT(*) FROM message WHERE provider = ?;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Lazy's retention rule: bodies older than the window are nulled out
    /// (metadata kept for search).
    func purgeBodies(olderThanDays days: Int) {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        guard let statement = prepare("UPDATE message SET body = '' WHERE received_at < ? AND body != '';") else { return }
        defer { sqlite3_finalize(statement) }
        bind(Self.isoFormatter.string(from: cutoffDate), to: statement, at: 1)
        if sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) > 0 {
            print("📧 MailStore: purged bodies older than \(days) days (\(sqlite3_changes(db)) rows)")
        }
    }

    /// M6.2: persist the classifier's verdict + cached summary (M6.3 reads
    /// the flags to place mail on the board; M6.4 reads summaries for
    /// "check my email").
    func applyAnalysis(provider: MailProvider, providerID: String, isSchool: Bool, isTimeSensitive: Bool, hasEvent: Bool, summary: String?) {
        guard let statement = prepare("""
        UPDATE message SET is_school = ?, is_time_sensitive = ?, has_event = ?, summary = ?
        WHERE provider = ? AND provider_id = ?;
        """) else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, isSchool ? 1 : 0)
        sqlite3_bind_int64(statement, 2, isTimeSensitive ? 1 : 0)
        sqlite3_bind_int64(statement, 3, hasEvent ? 1 : 0)
        bind(summary, to: statement, at: 4)
        bind(provider.rawValue, to: statement, at: 5)
        bind(providerID, to: statement, at: 6)
        _ = sqlite3_step(statement) == SQLITE_DONE
    }

    // MARK: - Sync state

    struct SyncStateRow {
        let cursor: String?
        let lastPolledAt: Date?
        let consecutiveFailures: Int
    }

    func syncState(for provider: MailProvider) -> SyncStateRow {
        guard let statement = prepare("SELECT cursor, last_polled_at, consecutive_failures FROM sync_state WHERE provider = ?;") else {
            return SyncStateRow(cursor: nil, lastPolledAt: nil, consecutiveFailures: 0)
        }
        defer { sqlite3_finalize(statement) }
        bind(provider.rawValue, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return SyncStateRow(cursor: nil, lastPolledAt: nil, consecutiveFailures: 0)
        }
        return SyncStateRow(
            cursor: textColumn(statement, 0),
            lastPolledAt: dateColumn(statement, 1),
            consecutiveFailures: Int(sqlite3_column_int64(statement, 2))
        )
    }

    func setSyncCursor(_ cursor: String?, for provider: MailProvider) {
        exec("""
        INSERT INTO sync_state (provider, cursor) VALUES ('\(provider.rawValue)', '\(cursor ?? "")')
        ON CONFLICT(provider) DO UPDATE SET cursor = excluded.cursor;
        """)
    }

    func recordSyncPoll(provider: MailProvider, succeeded: Bool) {
        let failures = succeeded ? 0 : syncState(for: provider).consecutiveFailures + 1
        let now = Self.isoFormatter.string(from: Date())
        exec("""
        INSERT INTO sync_state (provider, last_polled_at, consecutive_failures) VALUES ('\(provider.rawValue)', '\(now)', \(failures))
        ON CONFLICT(provider) DO UPDATE SET last_polled_at = excluded.last_polled_at, consecutive_failures = excluded.consecutive_failures;
        """)
    }

    // MARK: - Notification dedupe (M6.2 fills the fires)

    /// True when this dedupe key hasn't fired within the window (Lazy's
    /// 30-minute F-09 suppression).
    func shouldFireNotification(dedupeKey: String, withinMinutes minutes: Int) -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .minute, value: -minutes, to: Date()) else { return true }
        guard let statement = prepare("SELECT COUNT(*) FROM notification_log WHERE dedupe_key = ? AND fired_at >= ?;") else { return true }
        defer { sqlite3_finalize(statement) }
        bind(dedupeKey, to: statement, at: 1)
        bind(Self.isoFormatter.string(from: cutoff), to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        return sqlite3_column_int64(statement, 0) == 0
    }

    func recordNotification(dedupeKey: String) {
        let now = Self.isoFormatter.string(from: Date())
        exec("INSERT INTO notification_log (dedupe_key, fired_at) VALUES ('\(dedupeKey.replacingOccurrences(of: "'", with: "''"))', '\(now)');")
    }

    // MARK: - Audit (M6.3/M6.4 approve/send entries land here)

    func recordAudit(action: String, detail: String, result: String) {
        exec("""
        INSERT INTO action_audit (action, detail, result)
        VALUES ('\(action.replacingOccurrences(of: "'", with: "''"))',
                '\(detail.replacingOccurrences(of: "'", with: "''"))',
                '\(result.replacingOccurrences(of: "'", with: "''"))');
        """)
    }

    // MARK: - M6.3 board items (todos + reminders, Lazy repo subset)

    /// Posts after any board-visible mutation so the sticky board reloads.
    static let boardDataDidChange = Notification.Name("clickyStickyBoardDataDidChange")

    private func postBoardChanged() {
        NotificationCenter.default.post(name: Self.boardDataDidChange, object: nil)
    }

    struct BoardReminderRow {
        let id: Int64
        let title: String
        let note: String?
        let dueAt: Date?
        let state: String
        /// M6.11: the email's arrival time — set only on mail cards, drives the
        /// newest-first ordering of the board's top group.
        let receivedAt: Date?
    }

    struct BoardTodoRow {
        let id: Int64
        let title: String
        let dueAt: Date?
        let details: String?
        let reminderID: Int64?
    }

    @discardableResult
    func addTodo(title: String, dueAt: Date?, details: String?, reminderID: Int64?) -> Int64? {
        guard let statement = prepare("INSERT INTO todo (title, due_at, details, reminder_id) VALUES (?, ?, ?, ?);") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(title, to: statement, at: 1)
        bind(dueAt.map { Self.isoFormatter.string(from: $0) }, to: statement, at: 2)
        bind(details, to: statement, at: 3)
        if let reminderID {
            sqlite3_bind_int64(statement, 4, reminderID)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        postBoardChanged()
        return sqlite3_last_insert_rowid(db)
    }

    /// `dedupeKey` (e.g. "mail:gmail:provider-id") makes mail→board inserts
    /// idempotent across syncs (Lazy's F-09 dedupe). `receivedAt` (M6.11) is
    /// the email's arrival time — only mail cards pass it; it defaults to nil
    /// so chat-captured reminders are unaffected.
    @discardableResult
    func addReminder(title: String, note: String?, dueAt: Date?, dedupeKey: String?, receivedAt: Date? = nil) -> Int64? {
        if let dedupeKey, hasReminder(dedupeKey: dedupeKey) { return nil }
        guard let statement = prepare("INSERT INTO reminder (title, note, due_at, dedupe_key, received_at) VALUES (?, ?, ?, ?, ?);") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(title, to: statement, at: 1)
        bind(note, to: statement, at: 2)
        bind(dueAt.map { Self.isoFormatter.string(from: $0) }, to: statement, at: 3)
        bind(dedupeKey, to: statement, at: 4)
        bind(receivedAt.map { Self.isoFormatter.string(from: $0) }, to: statement, at: 5)
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        postBoardChanged()
        return sqlite3_last_insert_rowid(db)
    }

    func hasReminder(dedupeKey: String) -> Bool {
        guard let statement = prepare("SELECT COUNT(*) FROM reminder WHERE dedupe_key = ?;") else { return false }
        defer { sqlite3_finalize(statement) }
        bind(dedupeKey, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(statement, 0) > 0
    }

    /// Ordering mirrors Lazy: due-dated first (oldest first), undated after,
    /// newest id on top within each group.
    func listBoardTodos(limit: Int = 100) -> [BoardTodoRow] {
        guard let statement = prepare("""
        SELECT id, title, due_at, details, reminder_id FROM todo
        WHERE state = 'open'
        ORDER BY (due_at IS NULL), due_at ASC, id DESC LIMIT ?;
        """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var rows: [BoardTodoRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(BoardTodoRow(
                id: sqlite3_column_int64(statement, 0),
                title: textColumn(statement, 1) ?? "",
                dueAt: dateColumn(statement, 2),
                details: textColumn(statement, 3),
                reminderID: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4)
            ))
        }
        return rows
    }

    /// Manual reminders only (M6.11): Lazy's exact due-first rule is kept for
    /// everything a human captured — mail cards moved to their own group.
    func listBoardReminders(limit: Int = 100) -> [BoardReminderRow] {
        guard let statement = prepare("""
        SELECT id, title, note, due_at, state, received_at FROM reminder
        WHERE state IN ('open', 'snoozed')
          AND (dedupe_key IS NULL OR dedupe_key NOT LIKE 'mail:%')
        ORDER BY (due_at IS NULL), due_at ASC, id DESC LIMIT ?;
        """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var rows: [BoardReminderRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(BoardReminderRow(
                id: sqlite3_column_int64(statement, 0),
                title: textColumn(statement, 1) ?? "",
                note: textColumn(statement, 2),
                dueAt: dateColumn(statement, 3),
                state: textColumn(statement, 4) ?? "open",
                receivedAt: dateColumn(statement, 5)
            ))
        }
        return rows
    }

    /// M6.11: mail cards form the board's top group, newest-received first —
    /// user decision, overriding Lazy's due-first rule for mail only. SQLite
    /// sorts NULLs last under DESC, so a pre-v4 card with no received time
    /// falls to the bottom of the group (correct: it's the oldest).
    func listBoardMailReminders(limit: Int = 100) -> [BoardReminderRow] {
        guard let statement = prepare("""
        SELECT id, title, note, due_at, state, received_at FROM reminder
        WHERE state IN ('open', 'snoozed') AND dedupe_key LIKE 'mail:%'
        ORDER BY received_at DESC, id DESC LIMIT ?;
        """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var rows: [BoardReminderRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(BoardReminderRow(
                id: sqlite3_column_int64(statement, 0),
                title: textColumn(statement, 1) ?? "",
                note: textColumn(statement, 2),
                dueAt: dateColumn(statement, 3),
                state: textColumn(statement, 4) ?? "open",
                receivedAt: dateColumn(statement, 5)
            ))
        }
        return rows
    }

    func setTodoState(_ state: String, id: Int64) {
        exec("""
        UPDATE todo SET state = '\(state)', updated_at = datetime('now'),
            deleted_at = CASE WHEN '\(state)' = 'deleted' THEN datetime('now') ELSE deleted_at END
        WHERE id = \(id);
        """)
        postBoardChanged()
    }

    func setReminderState(_ state: String, id: Int64) {
        exec("UPDATE reminder SET state = '\(state)', updated_at = datetime('now') WHERE id = \(id);")
        postBoardChanged()
    }

    func updateTodoTitle(_ title: String, id: Int64) {
        guard let statement = prepare("UPDATE todo SET title = ?, updated_at = datetime('now') WHERE id = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bind(title, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, id)
        _ = sqlite3_step(statement) == SQLITE_DONE
        postBoardChanged()
    }

    func updateReminderTitle(_ title: String, id: Int64) {
        guard let statement = prepare("UPDATE reminder SET title = ?, updated_at = datetime('now') WHERE id = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bind(title, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, id)
        _ = sqlite3_step(statement) == SQLITE_DONE
        postBoardChanged()
    }

    func snoozeReminder(id: Int64, until: Date) {
        guard let statement = prepare("UPDATE reminder SET state = 'snoozed', snoozed_until = ?, updated_at = datetime('now') WHERE id = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bind(Self.isoFormatter.string(from: until), to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, id)
        _ = sqlite3_step(statement) == SQLITE_DONE
        postBoardChanged()
    }

    /// Lazy's claim (repositories.claim_due_reminders): reminders whose due
    /// time passed, snooze expired, and not notified within the dedupe
    /// window; claims flip state → fired so nothing double-fires.
    func claimDueReminders(now: Date = Date(), dedupeMinutes: Int = 30) -> [BoardReminderRow] {
        guard let cutoff = Calendar.current.date(byAdding: .minute, value: -dedupeMinutes, to: now),
              let statement = prepare("""
              SELECT id, title, note, due_at, state FROM reminder
              WHERE state IN ('open', 'snoozed')
                AND due_at IS NOT NULL
                AND due_at <= ?
                AND (snoozed_until IS NULL OR snoozed_until <= ?)
                AND (last_notified_at IS NULL OR last_notified_at <= ?)
              ORDER BY due_at ASC;
              """)
        else { return [] }
        let nowString = Self.isoFormatter.string(from: now)
        let cutoffString = Self.isoFormatter.string(from: cutoff)
        defer { sqlite3_finalize(statement) }
        bind(nowString, to: statement, at: 1)
        bind(nowString, to: statement, at: 2)
        bind(cutoffString, to: statement, at: 3)
        var claimed: [BoardReminderRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            claimed.append(BoardReminderRow(
                id: sqlite3_column_int64(statement, 0),
                title: textColumn(statement, 1) ?? "",
                note: textColumn(statement, 2),
                dueAt: dateColumn(statement, 3),
                state: textColumn(statement, 4) ?? "open",
                receivedAt: nil  // firing keys off due_at; arrival time unused here
            ))
        }
        for reminder in claimed {
            guard let update = prepare("UPDATE reminder SET state = 'fired', snoozed_until = NULL, last_notified_at = ?, updated_at = ? WHERE id = ?;") else { continue }
            defer { sqlite3_finalize(update) }
            bind(nowString, to: update, at: 1)
            bind(nowString, to: update, at: 2)
            sqlite3_bind_int64(update, 3, reminder.id)
            _ = sqlite3_step(update) == SQLITE_DONE
        }
        if !claimed.isEmpty {
            postBoardChanged()
        }
        return claimed
    }

    // MARK: - M6.4 drafts (Lazy's DraftService lifecycle: create → approve
    // (exact-body hash binding) → send → audit rows)

    struct DraftRow {
        let id: Int64
        let provider: String
        let toAddresses: [String]
        let subject: String
        let body: String
        let bodyHash: String?
        let originalMessageRef: String?
        let status: String
    }

    @discardableResult
    func createDraft(provider: String, toAddresses: [String], subject: String, body: String, originalMessageRef: String?) -> Int64? {
        guard let statement = prepare("INSERT INTO draft (provider, to_addresses, subject, body, original_message_ref) VALUES (?, ?, ?, ?, ?);") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(provider, to: statement, at: 1)
        bind(toAddresses.joined(separator: ","), to: statement, at: 2)
        bind(subject, to: statement, at: 3)
        bind(body, to: statement, at: 4)
        bind(originalMessageRef, to: statement, at: 5)
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    func draftRow(id: Int64) -> DraftRow? {
        guard let statement = prepare("SELECT id, provider, to_addresses, subject, body, body_hash, original_message_ref, status FROM draft WHERE id = ?;") else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return DraftRow(
            id: sqlite3_column_int64(statement, 0),
            provider: textColumn(statement, 1) ?? "",
            toAddresses: (textColumn(statement, 2) ?? "").split(separator: ",").map(String.init),
            subject: textColumn(statement, 3) ?? "",
            body: textColumn(statement, 4) ?? "",
            bodyHash: textColumn(statement, 5),
            originalMessageRef: textColumn(statement, 6),
            status: textColumn(statement, 7) ?? "pending"
        )
    }

    /// Lazy's approve_draft: the exact content hash is bound to the
    /// approval; send re-verifies it before anything leaves the machine.
    func approveDraft(id: Int64, hash: String) {
        guard let statement = prepare("UPDATE draft SET body_hash = ?, status = 'approved' WHERE id = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bind(hash, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, id)
        _ = sqlite3_step(statement) == SQLITE_DONE
    }

    /// Lazy's edit: any body change invalidates the approval.
    func updateDraftBody(id: Int64, body: String) {
        guard let statement = prepare("UPDATE draft SET body = ?, body_hash = NULL, status = 'pending' WHERE id = ?;") else { return }
        defer { sqlite3_finalize(statement) }
        bind(body, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, id)
        _ = sqlite3_step(statement) == SQLITE_DONE
    }

    func markDraftSent(id: Int64) {
        exec("UPDATE draft SET status = 'sent' WHERE id = \(id);")
    }

    func discardDraft(id: Int64) {
        exec("UPDATE draft SET status = 'discarded' WHERE id = \(id);")
    }

    // MARK: - M6.4 message lookup + digest

    /// Newest message whose sender name/email or subject contains `query`
    /// ("reply to bob", "reply to syllabus"). Body included — it's the
    /// drafting context (bodies purge after 30 days, recent mail has them).
    func latestMessage(matching query: String) -> MailStoreMessage? {
        let cleaned = query
            .replacingOccurrences(of: "%", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let statement = prepare("""
              SELECT provider, provider_id, sender_name, sender_email, subject, body, received_at
              FROM message
              WHERE sender_name LIKE ? OR sender_email LIKE ? OR subject LIKE ?
              ORDER BY received_at DESC LIMIT 1;
              """)
        else { return nil }
        defer { sqlite3_finalize(statement) }
        let pattern = "%\(cleaned)%"
        bind(pattern, to: statement, at: 1)
        bind(pattern, to: statement, at: 2)
        bind(pattern, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let provider = textColumn(statement, 0).flatMap(MailProvider.init(rawValue:))
        else { return nil }
        return MailStoreMessage(
            provider: provider,
            providerID: textColumn(statement, 1) ?? "",
            threadID: nil,
            senderName: textColumn(statement, 2),
            senderEmail: textColumn(statement, 3),
            subject: textColumn(statement, 4) ?? "",
            body: textColumn(statement, 5) ?? "",
            receivedAt: dateColumn(statement, 6) ?? Date()
        )
    }

    /// Source for "check my email" and the brain's awareness block.
    struct MailDigestRow {
        let subject: String
        let senderDisplay: String
        let receivedAt: Date
        let isUrgent: Bool
        let isTimeSensitive: Bool
        let summary: String?
    }

    func recentDigestRows(sinceHours: Int, limit: Int) -> [MailDigestRow] {
        guard let cutoff = Calendar.current.date(byAdding: .hour, value: -sinceHours, to: Date()),
              let statement = prepare("""
              SELECT subject, sender_name, sender_email, received_at, is_urgent, is_time_sensitive, summary
              FROM message
              WHERE received_at >= ?
              ORDER BY received_at DESC LIMIT ?;
              """)
        else { return [] }
        defer { sqlite3_finalize(statement) }
        // Both sides of the compare are ISO8601 (see isoFormatter) —
        // lexicographic order is exact.
        bind(Self.isoFormatter.string(from: cutoff), to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, Int64(limit))
        var rows: [MailDigestRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(MailDigestRow(
                subject: textColumn(statement, 0) ?? "",
                senderDisplay: textColumn(statement, 1) ?? textColumn(statement, 2) ?? "",
                receivedAt: dateColumn(statement, 3) ?? Date(),
                isUrgent: sqlite3_column_int64(statement, 4) > 0,
                isTimeSensitive: sqlite3_column_int64(statement, 5) > 0,
                summary: textColumn(statement, 6)
            ))
        }
        return rows
    }
}
