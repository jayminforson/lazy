//
//  CompanionManager+Conversations.swift
//  Lazy
//
//  M8 — chats become real conversations: each one owns its transcript AND
//  its brain memory (per-conversation Gemini history key), the notch sheet
//  always opens on a fresh (empty) draft, and the header's Recents toggle
//  lists past chats grouped ChatGPT-style (Today / Yesterday / Previous
//  7 days / Older). One UserDefaults store, JSON-encoded, same pattern the
//  single global transcript used — capped conversations, capped messages.
//

import Foundation

extension CompanionManager {

    /// One chat conversation: its transcript plus Recents metadata (title
    /// from the first message, created/updated stamps for grouping).
    struct ChatConversation: Identifiable, Codable {
        let id: UUID
        var title: String
        let createdAt: Date
        var updatedAt: Date
        var messages: [ChatMessage]
    }

    /// A day group in the Recents list.
    struct RecentsSection: Identifiable {
        let title: String
        var id: String { title }
        let items: [RecentsItem]
    }

    /// One row in the Recents list.
    struct RecentsItem: Identifiable {
        let conversation: ChatConversation
        let timeText: String
        var id: UUID { conversation.id }
    }

    // MARK: - Store

    /// M8 — the single store for all conversations (transcripts included;
    /// the legacy `clickyChatMessages` key is migrated away, never written).
    static let persistedConversationsKey = "clickyChatConversations"

    /// Cap on stored conversations — oldest-updated evicted first (the open
    /// conversation is never evicted; its brain key goes with it).
    private static let maximumConversationCount = 60

    /// Startup load: decode the store, migrate the pre-M8 global transcript
    /// + brain blob into one importable conversation, then enforce the cap.
    func loadConversations() {
        if let encoded = UserDefaults.standard.data(forKey: Self.persistedConversationsKey),
           let decoded = try? JSONDecoder().decode([ChatConversation].self, from: encoded) {
            conversations = decoded
        }
        migrateLegacyChatIfNeeded()
        evictOverCap()
    }

    func persistConversations() {
        guard let encoded = try? JSONEncoder().encode(conversations) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.persistedConversationsKey)
    }

    /// One-time import (user decision: nothing is lost): the old global
    /// transcript + old single brain blob become ONE conversation titled
    /// from its first message (or the brain's first user turn when the
    /// transcript was empty). Both legacy keys are removed either way.
    private func migrateLegacyChatIfNeeded() {
        let legacyMessagesKey = "clickyChatMessages"
        let legacyMessagesData = UserDefaults.standard.data(forKey: legacyMessagesKey)
        let legacyBrainData = GeminiBrainTransport.legacyHistoryData()
        guard legacyMessagesData != nil || legacyBrainData != nil else { return }

        if conversations.isEmpty {
            var messages: [ChatMessage] = []
            if let legacyMessagesData,
               let decoded = try? JSONDecoder().decode([ChatMessage].self, from: legacyMessagesData) {
                messages = decoded
            }
            var title = Self.title(from: messages.first(where: { $0.role == .user })?.text)
                ?? Self.title(from: messages.first?.text)
            if title == nil, let legacyBrainData {
                title = Self.title(from: Self.firstUserTurn(inBrainHistoryData: legacyBrainData))
            }
            if !messages.isEmpty || legacyBrainData != nil {
                let now = Date()
                let imported = ChatConversation(
                    id: UUID(),
                    title: title ?? "Earlier chat",
                    createdAt: messages.first?.sentAt ?? now,
                    updatedAt: messages.last?.sentAt ?? now,
                    messages: messages
                )
                conversations = [imported]
                if let legacyBrainData {
                    GeminiBrainTransport.storeHistoryData(legacyBrainData, for: imported.id)
                }
            }
        }

        UserDefaults.standard.removeObject(forKey: legacyMessagesKey)
        GeminiBrainTransport.removeLegacyHistoryData()
        persistConversations()
    }

    /// First `{"role":"user", ...}` turn of a legacy brain blob — used only
    /// to title the imported conversation.
    private static func firstUserTurn(inBrainHistoryData data: Data) -> String? {
        struct LegacyTurn: Codable { let role: String; let content: String }
        guard let turns = try? JSONDecoder().decode([LegacyTurn].self, from: data) else { return nil }
        return turns.first(where: { $0.role == "user" })?.content
    }

    // MARK: - Lifecycle

    /// Every sheet open lands here (NotchChatManager.openSheet): empty
    /// transcript, empty brain memory, serve context cleared. Nothing empty
    /// is persisted — the next conversation is created by its first turn.
    /// A reply still in flight keeps its OWN conversation (turn ownership
    /// is never reassigned by this reset).
    func beginFreshChat() {
        activeConversationID = nil
        if !isTurnInFlight {
            currentTurnConversationID = nil
        }
        conversationHistory = []
        geminiBrainTransport.activateBrainHistory(for: nil)
    }

    /// Creates + activates a conversation. Called from respond() when the
    /// draft has no conversation yet (title seeded from the first message —
    /// the only place voice turns get one, since their transcript is never
    /// written) and from appendChatMessage when nothing exists at all.
    @discardableResult
    func createConversation(titledFrom titleText: String?) -> ChatConversation {
        let now = Date()
        let conversation = ChatConversation(
            id: UUID(),
            title: Self.title(from: titleText) ?? "",
            createdAt: now,
            updatedAt: now,
            messages: []
        )
        conversations.append(conversation)
        activeConversationID = conversation.id
        conversationHistory = []
        geminiBrainTransport.activateBrainHistory(for: conversation.id)
        evictOverCap(keeping: conversation.id)
        persistConversations()
        return conversation
    }

    /// Opens a past chat from Recents: transcript switches, serve context
    /// rebuilds from it, brain memory swaps to ITS per-conversation history.
    /// A completed turn's ownership is cleared here so later non-turn
    /// appends (scheduled suggestions) target the conversation on screen.
    func openConversation(id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        if !isTurnInFlight {
            currentTurnConversationID = nil
        }
        activeConversationID = id
        conversationHistory = Self.servePairs(from: conversation.messages)
        geminiBrainTransport.activateBrainHistory(for: id)
    }

    /// Hover-✕ in Recents. Deleting the open conversation drops back to the
    /// fresh draft; the brain key is removed with it.
    func deleteConversation(id: UUID) {
        conversations.removeAll { $0.id == id }
        GeminiBrainTransport.deleteBrainHistory(for: id)
        if currentTurnConversationID == id {
            currentTurnConversationID = nil
        }
        if activeConversationID == id {
            activeConversationID = nil
            conversationHistory = []
            geminiBrainTransport.activateBrainHistory(for: nil)
        }
        persistConversations()
    }

    // MARK: - Transcript append (the old appendChatMessage, re-routed)

    /// Appends to THE conversation that owns the write: the in-flight turn's
    /// conversation → the open one → the most recently updated → a passive
    /// new one (created without activation: only respond() activates, so a
    /// stray append can never hijack the fresh draft on screen).
    func appendChatMessage(role: ChatMessageRole, text: String) {
        let message = ChatMessage(id: UUID(), role: role, text: text, sentAt: Date())
        var index = currentConversationIndex()
        if index == nil {
            conversations.append(ChatConversation(
                id: UUID(),
                title: "",
                createdAt: message.sentAt,
                updatedAt: message.sentAt,
                messages: []
            ))
            index = conversations.count - 1
        }
        guard let index else { return }

        conversations[index].messages.append(message)
        conversations[index].updatedAt = message.sentAt
        if conversations[index].title.isEmpty, role == .user,
           let title = Self.title(from: text) {
            conversations[index].title = title
        }
        if conversations[index].messages.count > Self.maximumPersistedChatMessageCount {
            conversations[index].messages.removeFirst(
                conversations[index].messages.count - Self.maximumPersistedChatMessageCount
            )
        }
        evictOverCap(keeping: conversations[index].id)
        persistConversations()
    }

    private func currentConversationIndex() -> Int? {
        if let turnID = currentTurnConversationID,
           let turnIndex = conversations.firstIndex(where: { $0.id == turnID }) {
            return turnIndex
        }
        if let activeID = activeConversationID,
           let activeIndex = conversations.firstIndex(where: { $0.id == activeID }) {
            return activeIndex
        }
        return conversations.indices.max { conversations[$0].updatedAt < conversations[$1].updatedAt }
    }

    private func evictOverCap(keeping protectedID: UUID? = nil) {
        var excess = conversations.count - Self.maximumConversationCount
        guard excess > 0 else { return }
        // Oldest-updated first, never the protected (open/just-written) one.
        let oldestFirst = conversations.sorted { $0.updatedAt < $1.updatedAt }
        for conversation in oldestFirst where excess > 0 && conversation.id != protectedID {
            conversations.removeAll { $0.id == conversation.id }
            GeminiBrainTransport.deleteBrainHistory(for: conversation.id)
            excess -= 1
        }
    }

    // MARK: - Recents grouping

    /// ChatGPT-style day groups over updatedAt desc: Today · Yesterday ·
    /// Previous 7 days · Older, each row carrying its own time label.
    func recentsSections() -> [RecentsSection] {
        let calendar = Calendar.current
        let now = Date()
        let timeOnly = DateFormatter()
        timeOnly.dateFormat = "h:mm a"
        let fullStamp = DateFormatter()
        fullStamp.dateFormat = "MMM d, h:mm a"

        var buckets: [(title: String, items: [RecentsItem])] = [
            ("Today", []), ("Yesterday", []), ("Previous 7 days", []), ("Older", [])
        ]
        for conversation in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let dayDelta = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: conversation.updatedAt),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
            let bucketIndex = dayDelta <= 0 ? 0 : dayDelta == 1 ? 1 : dayDelta <= 7 ? 2 : 3
            let label = dayDelta <= 1
                ? timeOnly.string(from: conversation.updatedAt)
                : fullStamp.string(from: conversation.updatedAt)
            buckets[bucketIndex].items.append(RecentsItem(conversation: conversation, timeText: label))
        }
        return buckets
            .filter { !$0.items.isEmpty }
            .map { RecentsSection(title: $0.title, items: $0.items) }
    }

    // MARK: - Helpers

    /// Recents/Brain title: first line of the message, ≤48 chars (+…).
    static func title(from text: String?) -> String? {
        guard let text else { return nil }
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
    }

    /// Serve-fallback pairs rebuilt from a conversation's typed transcript
    /// (voice exchanges live in the brain's per-conversation history — the
    /// transcript rule keeps them unwritten). Orphan assistants skipped.
    private static func servePairs(from messages: [ChatMessage]) -> [(userTranscript: String, assistantResponse: String)] {
        var pairs: [(userTranscript: String, assistantResponse: String)] = []
        var pendingUser: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingUser = message.text
            case .assistant:
                if let user = pendingUser {
                    pairs.append((userTranscript: user, assistantResponse: message.text))
                    pendingUser = nil
                }
            }
        }
        return Array(pairs.suffix(10))
    }
}
