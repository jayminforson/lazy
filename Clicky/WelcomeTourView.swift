//
//  WelcomeTourView.swift
//  Clicky
//
//  The tour card: eyes up top, one beat per screen, progress dots, and
//  Skip / Next / Done. Dimmed backdrop; gel card treatment.
//

import SwiftUI

struct WelcomeTourView: View {
    @ObservedObject var manager: WelcomeTourManager

    private struct Beat {
        let title: String
        let body: String
    }

    private static let beats: [Beat] = [
        Beat(
            title: "I live in your Mac's notch.",
            body: "Click the eyes — or rest your pointer on them for a beat — and I'll peek out to chat."
        ),
        Beat(
            title: "Hold Control + Option to talk.",
            body: "Let go and I'll answer out loud. Prefer typing? The notch sheet has a text field."
        ),
        Beat(
            title: "Home has everything in one place.",
            body: "Companions, suggestions, skills, and settings — the house button in the notch sheet opens it."
        ),
        Beat(
            title: "That's the tour.",
            body: "Press Control + Option anytime — I'm listening. Settings → Replay the welcome tour brings this back."
        )
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            card
                .frame(width: 440)
                .scaleEffect(manager.isShowing ? 1 : 0.92)
                .opacity(manager.isShowing ? 1 : 0)
                .animation(.spring(response: 0.38, dampingFraction: 0.8), value: manager.isShowing)
        }
    }

    // MARK: - Card

    private var card: some View {
        let beat = Self.beats[min(manager.beatIndex, Self.beats.count - 1)]

        return VStack(spacing: 0) {
            VStack(spacing: 16) {
                NotchEyesPairView()
                    .frame(height: 34)
                    .padding(.top, 6)

                Text(beat.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(beat.body)
                    .font(.system(size: 14))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)

                // Progress dots.
                HStack(spacing: 7) {
                    ForEach(0..<WelcomeTourManager.beatCount, id: \.self) { index in
                        Circle()
                            .fill(
                                index == manager.beatIndex
                                    ? DS.Colors.accent
                                    : Color.white.opacity(index < manager.beatIndex ? 0.45 : 0.16)
                            )
                            .frame(width: 7, height: 7)
                            .scaleEffect(index == manager.beatIndex ? 1.25 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: manager.beatIndex)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            HStack {
                if !manager.isLastBeat {
                    Button {
                        manager.skip()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    Spacer()
                        .frame(height: 1)
                }

                Spacer()

                Button {
                    manager.advance()
                } label: {
                    Text(manager.isLastBeat ? "Done" : "Next")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(GelButtonStyle(cornerRadius: 12, accentTint: true))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .gelSurface(cornerRadius: 24)
    }
}
