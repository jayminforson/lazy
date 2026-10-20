//
//  HomeView.swift
//  Clicky
//
//  The Home dashboard shell: gel card, header with eyes, left icon rail, and
//  the four pages (Clickys / Suggestions / Skills / Settings). Recreated from
//  the HeyClicky reference's Home-space layout (icon rail + paged content);
//  all art is drawn, nothing shipped from the DMG.
//

import SwiftUI

enum HomePage: String, CaseIterable, Identifiable {
    case clickys
    case suggestions
    case skills
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clickys: return "Companions"
        case .suggestions: return "Suggestions"
        case .skills: return "Skills"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .clickys: return "person.2.fill"
        case .suggestions: return "lightbulb.fill"
        case .skills: return "puzzlepiece.extension.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct HomeView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var manager: HomeWindowManager
    let onReplayTour: () -> Void

    @State private var page: HomePage = .clickys

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            HStack(spacing: 0) {
                rail

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)

                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                topTrailingRadius: 24,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [DS.Colors.surface2, DS.Colors.surface1],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 24,
                    bottomLeadingRadius: 24,
                    bottomTrailingRadius: 24,
                    topTrailingRadius: 24,
                    style: .continuous
                )
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.13),
                            Color.white.opacity(0.03),
                            Color.black.opacity(0.30)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.45), radius: 40, x: 0, y: 18)
        )
        .padding(10)
        // Reveal: mounts collapsed (manager.isOpen starts false in show()),
        // springs to full size once the panel is on screen.
        .scaleEffect(manager.isOpen ? 1 : 0.94)
        .opacity(manager.isOpen ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: manager.isOpen)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            NotchEyesPairView()

            Text("Home")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Button(action: { manager.close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Close Home")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Icon Rail

    private var rail: some View {
        VStack(spacing: 6) {
            ForEach(HomePage.allCases) { item in
                let isSelected = page == item

                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        page = item
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 15, weight: .medium))
                        Text(item.title)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(
                        isSelected ? DS.Colors.accentText : DS.Colors.textTertiary
                    )
                    .frame(width: 64, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                isSelected
                                    ? AnyShapeStyle(DS.Colors.accent.opacity(0.18))
                                    : AnyShapeStyle(Color.white.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(
                                        isSelected
                                            ? DS.Colors.accent.opacity(0.55)
                                            : Color.white.opacity(0.05),
                                        lineWidth: 1
                                    )
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(item.title)
            }

            Spacer()
        }
        .padding(.vertical, 16)
        .frame(width: 88)
    }

    // MARK: - Page Content

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .clickys:
            HomeCompanionsPage(companionManager: companionManager)
        case .suggestions:
            HomeSuggestionsPage(engine: companionManager.proactiveEngine)
        case .skills:
            HomeSkillsPage(companionManager: companionManager)
        case .settings:
            HomeSettingsPage(companionManager: companionManager, mailManager: companionManager.mailManager, onReplayTour: onReplayTour)
        }
    }
}
