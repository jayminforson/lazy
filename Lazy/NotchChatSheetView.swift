//
//  NotchChatSheetView.swift
//  leanring-buddy
//
//  The chat sheet that springs down from the notch pill. Near-black with
//  only the bottom corners rounded so it reads as the notch extending
//  downward. Header carries Home and close; the body hosts the regular
//  ChatView in embedded mode.
//

import SwiftUI

struct NotchChatSheetView: View {
    @ObservedObject var notchChatManager: NotchChatManager
    @ObservedObject var companionManager: CompanionManager
    let onOpenHome: () -> Void
    let onClose: () -> Void

    /// Matches the fake-notch pill's near-black so pill and sheet look like
    /// one continuous shape when open.
    private static let sheetFillColor = Color(
        red: 0x0A / 255.0,
        green: 0x0B / 255.0,
        blue: 0x0B / 255.0
    )

    /// Collapsed scale: x matches the pill's width relative to the sheet
    /// (128/420 ≈ 0.3) and y ≈ 0 so the sheet extrudes out of the notch as
    /// one unit, anchored at the top edge — HeyClicky's open/close feel.
    private var isExtrudedOpen: Bool { notchChatManager.isSheetOpen }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            if !companionManager.activeGuideSteps.isEmpty {
                GuideWalkthroughCard(companionManager: companionManager)
            }

            if let pendingMailDraft = companionManager.mailManager.pendingDraft {
                DraftApprovalCardView(
                    mailManager: companionManager.mailManager,
                    companionManager: companionManager,
                    draft: pendingMailDraft
                )
            }

            ChatView(companionManager: companionManager, embeddedInNotchSheet: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 20,
                bottomTrailingRadius: 20,
                style: .continuous
            )
            .fill(Self.sheetFillColor)
            .overlay(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: 20,
                    bottomTrailingRadius: 20,
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
        )
        // Extrusion: the whole sheet scales up from the notch. Anchor .top
        // pins the top edge at the screen edge so the body grows downward.
        .scaleEffect(
            x: isExtrudedOpen ? 1 : 0.3,
            y: isExtrudedOpen ? 1 : 0.01,
            anchor: .top
        )
        .opacity(isExtrudedOpen ? 1 : 0)
        .animation(.spring(response: 0.38, dampingFraction: 0.75), value: isExtrudedOpen)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 6, height: 6)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.7), radius: 3)

            Text("lazy")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Button(action: onOpenHome) {
                Image(systemName: "house.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Open Home")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Walkthrough checklist card

/// Checklist shown while a [GUIDE:...] walkthrough is active: steps with the
/// current one highlighted, Next (or Done on the last step) advancing
/// locally without a brain call. Taps behave like typed "next"/"done".
private struct GuideWalkthroughCard: View {
    @ObservedObject var companionManager: CompanionManager

    private var isOnLastStep: Bool {
        companionManager.activeGuideStepIndex >= companionManager.activeGuideSteps.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("walkthrough")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(companionManager.activeGuideStepIndex + 1)/\(companionManager.activeGuideSteps.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            ForEach(Array(companionManager.activeGuideSteps.enumerated()), id: \.offset) { enumeratedStep in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(enumeratedStep.offset + 1).")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(enumeratedStep.offset == companionManager.activeGuideStepIndex ? DS.Colors.overlayCursorBlue : DS.Colors.textTertiary)
                    Text(enumeratedStep.element.text)
                        .font(.system(size: 12, weight: enumeratedStep.offset == companionManager.activeGuideStepIndex ? .medium : .regular))
                        .foregroundColor(enumeratedStep.offset == companionManager.activeGuideStepIndex ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .strikethrough(enumeratedStep.offset < companionManager.activeGuideStepIndex, color: DS.Colors.textTertiary)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                Button {
                    companionManager.deliverGuideIntentAndSpeak(.advance)
                } label: {
                    Text(isOnLastStep ? "last step" : "next")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isOnLastStep ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(isOnLastStep ? 0.04 : 0.10))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(isOnLastStep)

                Button {
                    companionManager.deliverGuideIntentAndSpeak(.finish)
                } label: {
                    Text("done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(DS.Colors.overlayCursorBlue.opacity(0.22))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Colors.overlayCursorBlue.opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// M6.4 — the email-draft approval card. The reply body is reviewed right
/// here in the sheet; "send" runs the hash-verified send (a physical click
/// IS the approval), "discard" drops the draft. The voice/typed "reply to
/// X" path parks the same draft behind the M5.3 yes/no instead.
private struct DraftApprovalCardView: View {
    @ObservedObject var mailManager: MailManager
    var companionManager: CompanionManager
    let draft: MailManager.MailDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("draft reply to \(draft.toName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
            }

            Text(draft.subject)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)

            Text(draft.body)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )

            HStack(spacing: 8) {
                Button {
                    let draftID = draft.id
                    Task {
                        let outcomeLine = await mailManager.sendDraft(draftID)
                        await companionManager.speakOutcomeLine(outcomeLine)
                    }
                } label: {
                    Text("send")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(DS.Colors.overlayCursorBlue.opacity(0.22))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button {
                    mailManager.discardDraft(draft.id)
                } label: {
                    Text("discard")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
