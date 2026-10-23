//
//  ChatView.swift
//  leanring-buddy
//
//  The chat window's SwiftUI content: a scrollable transcript (user and
//  assistant bubbles), a live-streaming assistant bubble with a typing
//  indicator while the brain generates, and a pill input field. Typed
//  replies are silent — they never go through TTS.
//

import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var companionManager: CompanionManager
    /// True when hosted inside the notch sheet — transparent background,
    /// relaxed minimum size, and the input grabs focus on appear so typing
    /// works the moment the sheet springs open.
    var embeddedInNotchSheet: Bool = false
    @State private var draftMessageText: String = ""
    /// Files picked via the + button, held until the next send.
    @State private var pendingFileAttachments: [CompanionManager.ChatFileAttachment] = []
    @FocusState private var isMessageInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcriptScrollView

            inputRow
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .frame(
            minWidth: embeddedInNotchSheet ? 300 : 340,
            minHeight: embeddedInNotchSheet ? 300 : 420
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(embeddedInNotchSheet ? Color.clear : DS.Colors.background)
        .onAppear {
            if embeddedInNotchSheet {
                isMessageInputFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clickyNotchSheetDidOpen)) { _ in
            if embeddedInNotchSheet {
                isMessageInputFocused = true
            }
        }
    }

    // MARK: - Transcript

    private var transcriptScrollView: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if companionManager.chatMessages.isEmpty && !companionManager.chatIsResponding {
                        emptyTranscriptState
                            .padding(.top, 40)
                    }

                    ForEach(companionManager.chatMessages) { message in
                        chatBubbleView(for: message)
                            .id(message.id)
                    }

                    // M8 — the live bubble belongs ONLY to the conversation
                    // whose turn is streaming: a fresh reopen (active nil) or
                    // a switch to another chat must not display an in-flight
                    // reply owned by a different conversation — it appends
                    // there via currentTurnConversationID instead.
                    if companionManager.chatIsResponding,
                       companionManager.currentTurnConversationID == companionManager.activeConversationID {
                        streamingAssistantBubble
                            .id(Self.streamingBubbleAnchorID)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: companionManager.chatMessages.count) {
                scrollToBottom(scrollViewProxy)
            }
            .onChange(of: companionManager.activeConversationID) {
                // M8 — switching conversations (or reopening fresh) moves the
                // view to the (new) end of the transcript.
                scrollToBottom(scrollViewProxy)
            }
            .onChange(of: companionManager.chatIsResponding) {
                scrollToBottom(scrollViewProxy)
            }
            .onChange(of: companionManager.chatStreamingReplyText) {
                scrollToBottom(scrollViewProxy)
            }
        }
    }

    private var emptyTranscriptState: some View {
        VStack(spacing: 6) {
            Text("no messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("type a message below — lazy can see your screen")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chatBubbleView(for message: CompanionManager.ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                messageBubbleText(message.text)
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.helpChatUserBubble)
                    )
            }
        case .assistant:
            HStack {
                messageBubbleText(message.text)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.surface1)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                            )
                    )
                Spacer(minLength: 40)
            }
        }
    }

    private func messageBubbleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 280, alignment: .leading)
    }

    /// Live-updating assistant bubble shown while a typed reply streams in.
    /// Shows typing dots until the first text delta arrives.
    private var streamingAssistantBubble: some View {
        HStack {
            if companionManager.chatStreamingReplyText.isEmpty {
                typingDotsIndicator
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.surface1)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                            )
                    )
            } else {
                messageBubbleText(companionManager.chatStreamingReplyText)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.surface1)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                            )
                    )
            }
            Spacer(minLength: 40)
        }
        .transition(.opacity)
    }

    private var typingDotsIndicator: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { timelineContext in
            let animationPhase = Int(timelineContext.date.timeIntervalSinceReferenceDate / 0.35) % 4
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    Circle()
                        .fill(DS.Colors.textTertiary)
                        .frame(width: 5, height: 5)
                        .opacity(animationPhase == dotIndex + 1 ? 1.0 : 0.35)
                }
            }
        }
    }

    // MARK: - Input

    private static let maximumPendingAttachmentCount = 5

    private var inputRow: some View {
        VStack(spacing: 6) {
            skillSuggestionRow

            if !pendingFileAttachments.isEmpty {
                attachmentChipsRow
            }

            HStack(spacing: 8) {
                Button(action: {
                    presentFileAttachmentPicker()
                }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Attach files — images, text, or code")

                TextField("Message Lazy...", text: $draftMessageText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .onSubmit {
                        sendDraftMessage()
                    }
                    .focused($isMessageInputFocused)

                if companionManager.isAgentRunActive {
                    Button(action: {
                        companionManager.cancelActiveAgentRun()
                    }) {
                        Text("Stop")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Stop the running agent task")
                }

                Button(action: {
                    sendDraftMessage()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(canSendDraftMessage ? DS.Colors.blue400 : DS.Colors.textTertiary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSendDraftMessage)
                .pointerCursor()
            }
        }
    }

    /// Tappable chips for files staged to go with the next message.
    private var attachmentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingFileAttachments) { fileAttachment in
                    HStack(spacing: 5) {
                        Image(systemName: fileAttachment.isImage ? "photo" : "doc.text")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)

                        Text(fileAttachment.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)

                        Button(action: {
                            pendingFileAttachments.removeAll { $0.id == fileAttachment.id }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(
                        Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
            }
        }
    }

    /// Skills whose names match a "/word" draft — one tap completes the draft.
    private var skillMatchesForCurrentDraft: [CompanionManager.UserSkill] {
        let trimmedDraft = draftMessageText.trimmingCharacters(in: .whitespaces)
        guard trimmedDraft.hasPrefix("/") else { return [] }
        let skillQuery = String(trimmedDraft.dropFirst()).lowercased()
        return companionManager.userSkills.filter { userSkill in
            skillQuery.isEmpty ? true : userSkill.name.hasPrefix(skillQuery)
        }
    }

    @ViewBuilder
    private var skillSuggestionRow: some View {
        if draftMessageText.hasPrefix("/"), !skillMatchesForCurrentDraft.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(skillMatchesForCurrentDraft) { userSkill in
                        Button(action: {
                            draftMessageText = "/\(userSkill.name) "
                            isMessageInputFocused = true
                        }) {
                            Text(userSkill.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.blue400)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(DS.Colors.blue400.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
        }
    }

    private func presentFileAttachmentPicker() {
        let fileOpenPanel = NSOpenPanel()
        fileOpenPanel.allowsMultipleSelection = true
        fileOpenPanel.canChooseDirectories = false
        fileOpenPanel.canChooseFiles = true
        fileOpenPanel.message = "Attach files for Lazy to read"
        guard fileOpenPanel.runModal() == .OK else { return }

        for selectedFileURL in fileOpenPanel.urls {
            let fileAttachment = CompanionManager.ChatFileAttachment(fileURL: selectedFileURL)
            guard !pendingFileAttachments.contains(where: { $0.fileURL == fileAttachment.fileURL }) else {
                continue
            }
            pendingFileAttachments.append(fileAttachment)
            if pendingFileAttachments.count > Self.maximumPendingAttachmentCount {
                pendingFileAttachments.removeFirst(
                    pendingFileAttachments.count - Self.maximumPendingAttachmentCount
                )
            }
        }
        isMessageInputFocused = true
    }

    private var canSendDraftMessage: Bool {
        !draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraftMessage() {
        let trimmedDraftMessageText = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraftMessageText.isEmpty else { return }
        // "/skillname extra words" expands to the skill's prompt plus the
        // extra words; plain messages pass through unchanged.
        let expandedDraftMessageText = companionManager.expandedSkillDraftText(from: trimmedDraftMessageText)
            ?? trimmedDraftMessageText
        let sentFileAttachments = pendingFileAttachments
        draftMessageText = ""
        pendingFileAttachments = []
        companionManager.submitTypedMessage(expandedDraftMessageText, fileAttachments: sentFileAttachments)
    }

    // MARK: - Scrolling

    private static let streamingBubbleAnchorID = "streaming-assistant-bubble"

    private func scrollToBottom(_ scrollViewProxy: ScrollViewProxy) {
        if companionManager.chatIsResponding {
            withAnimation(.easeOut(duration: 0.15)) {
                scrollViewProxy.scrollTo(Self.streamingBubbleAnchorID, anchor: .bottom)
            }
        } else if let lastMessageID = companionManager.chatMessages.last?.id {
            withAnimation(.easeOut(duration: 0.15)) {
                scrollViewProxy.scrollTo(lastMessageID, anchor: .bottom)
            }
        }
    }
}
