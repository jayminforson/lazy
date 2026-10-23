//
//  HomePages.swift
//  Clicky
//
//  The four Home pages: Clickys (companion overview), Suggestions (locked
//  proactive rules as toggles), Skills (user skill manager), and Settings.
//  Copy is original; the rule set matches the locked M3 suggestion rules.
//

import ServiceManagement
import SwiftUI

// MARK: - Shared bits

/// A titled gel card with a heading — the standard page building block.
struct HomeCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }
}

private var todayString: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

// MARK: - Clickys Page

struct HomeCompanionsPage: View {
    @ObservedObject var companionManager: CompanionManager

    private var voiceEngineLine: String {
        let lockedDate = UserDefaults.standard.string(forKey: "clickyTTSQuotaExhaustedDate")
        if lockedDate == todayString {
            return "System voice (ElevenLabs resets daily)"
        }
        return "ElevenLabs (free tier)"
    }

    private var statusChipText: String {
        switch companionManager.notchPillStatus {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .working: return "Working"
        }
    }

    private var statusChipColor: Color {
        switch companionManager.notchPillStatus {
        case .idle: return DS.Colors.overlayCursorBlue
        case .listening: return DS.Colors.success
        case .working: return DS.Colors.warning
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Companions")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                // Hero card — the live companion (named by its persona).
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [DS.Colors.surface4, DS.Colors.surface3],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                Circle().stroke(
                                    Color(hex: companionManager.activePersona.accentHex).opacity(0.75),
                                    lineWidth: 2
                                )
                            )
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        NotchEyesPairView()
                    }
                    .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(companionManager.activePersona.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(companionManager.activePersona.quip)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textSecondary)
                        // M7.1 — Pip's tier lock is a behavior change; say it
                        // out loud on the card so Smart-vs-fast is never a
                        // mystery ("why did Pip answer like the fast model?").
                        if companionManager.activePersona.id == LazyPersona.pipID {
                            Text("runs fast by design")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary.opacity(0.8))
                        }
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusChipColor)
                                .frame(width: 6, height: 6)
                            Text(statusChipText)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(statusChipColor)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(statusChipColor.opacity(0.12))
                                .overlay(Capsule().stroke(statusChipColor.opacity(0.35), lineWidth: 1))
                        )
                    }

                    Spacer()

                    Text("Hold Control + Option to talk.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.trailing, 4)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )

                // Quick stats.
                HStack(spacing: 12) {
                    HomeStatCard(
                        label: "Model",
                        value: companionManager.selectedModel == "smart" ? "Smart" : "Fast"
                    )
                    HomeStatCard(label: "Brain", value: "Free chain")
                    HomeStatCard(label: "Voice", value: voiceEngineLine)
                }

                // Personas — the Clickys you can switch between. Selection
                // changes the prompt addendum (how Clicky speaks) and the hero.
                Text("Switch companion")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(LazyPersona.builtIns) { persona in
                        Button {
                            companionManager.setActivePersona(id: persona.id)
                        } label: {
                            HStack(spacing: 10) {
                                personaDisc(persona)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(persona.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(DS.Colors.textPrimary)
                                    Text(persona.quip)
                                        .font(.system(size: 11))
                                        .foregroundColor(DS.Colors.textTertiary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(
                                        isPersonaActive(persona)
                                            ? personaAccent(persona).opacity(0.08)
                                            : Color.white.opacity(0.04)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(
                                                isPersonaActive(persona)
                                                    ? personaAccent(persona).opacity(0.45)
                                                    : Color.white.opacity(0.06),
                                                lineWidth: 1
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isPersonaActive(_ persona: LazyPersona) -> Bool {
        persona.id == companionManager.activePersonaID
    }

    private func personaAccent(_ persona: LazyPersona) -> Color {
        Color(hex: persona.accentHex)
    }

    private func personaDisc(_ persona: LazyPersona) -> some View {
        let accent = personaAccent(persona)
        let active = isPersonaActive(persona)
        return ZStack {
            Circle().fill(accent.opacity(0.20))
            Text(persona.initial)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(accent)
        }
        .frame(width: 36, height: 36)
        .overlay(
            Circle().stroke(
                active ? accent : Color.white.opacity(0.10),
                lineWidth: active ? 2 : 1
            )
        )
    }
}

private struct HomeStatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

// MARK: - Suggestions Page

struct HomeSuggestionsPage: View {
    /// Observed directly so cards, pause state, and sensing status update live.
    @ObservedObject var engine: ProactiveSuggestionEngine

    /// Locked M3 rule set — toggles persist here so the sensing reads them.
    @AppStorage("clickySuggestionRule_breaks") private var ruleBreaks = true
    @AppStorage("clickySuggestionRule_routines") private var ruleRoutines = true
    @AppStorage("clickySuggestionRule_daily") private var ruleDaily = true
    @AppStorage("clickySuggestionRule_dnd") private var ruleDnd = true

    @State private var newRoutineName = ""
    @State private var newRoutineInterval: Double = 24
    @State private var newRoutineDueNow = false

    private static let cadenceOptions: [(hours: Double, label: String)] = [
        (1, "Hourly"),
        (6, "Every 6h"),
        (12, "Every 12h"),
        (24, "Daily"),
        (72, "Every 3 days"),
        (168, "Weekly")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Suggestions")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                // Sensing status — one quiet line proving the probes are live.
                Text(sensingStatusLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.05)))

                // Pause banner — "ignore breaks until 3pm" landed here.
                if let pausedUntil = engine.pauseUntil, pausedUntil > Date() {
                    HStack(spacing: 10) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.warning)
                        Text("Paused until \(pausedUntil.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        Button("Resume now") {
                            engine.resumeSuggestions()
                        }
                        .buttonStyle(GelButtonStyle(accentTint: true))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DS.Colors.warning.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(DS.Colors.warning.opacity(0.28), lineWidth: 1)
                            )
                    )
                }

                // Cards — routine cards can be settled in place; any card
                // can be dismissed.
                if engine.suggestions.isEmpty {
                    HomeCard {
                        Text("No suggestions right now.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Text("One batch a day after 6 am while you're at your Mac: overdue routines, a take-five after a long stretch, yesterday's most-used app — never while Focus is on. Say “ignore breaks until 3pm” to go quiet on demand.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(engine.suggestions) { card in
                            suggestionCard(card)
                        }
                    }
                }

                // Routines — the raw material for routine cards.
                Text("Routines")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)

                if engine.routines.isEmpty {
                    HomeCard {
                        Text("No routines yet — add one below and its overdue nudge joins the daily batch.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(engine.routines) { routine in
                            routineRow(routine)
                        }
                    }
                }

                HomeCard(title: "Add a routine") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name — e.g. Water the plants", text: $newRoutineName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.black.opacity(0.30))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )

                        HStack(spacing: 12) {
                            Picker("", selection: $newRoutineInterval) {
                                ForEach(Self.cadenceOptions, id: \.hours) { option in
                                    Text(option.label).tag(option.hours)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140)

                            Toggle("", isOn: $newRoutineDueNow)
                                .labelsHidden()
                                .toggleStyle(.gel)
                            Text("Due right now")
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textSecondary)

                            Spacer(minLength: 0)
                        }

                        Button("Add routine") {
                            engine.addRoutine(
                                name: newRoutineName,
                                intervalHours: newRoutineInterval,
                                dueNow: newRoutineDueNow
                            )
                            newRoutineName = ""
                            newRoutineDueNow = false
                        }
                        .buttonStyle(GelButtonStyle(accentTint: true))
                        .disabled(newRoutineName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Text("Rules")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)

                VStack(spacing: 10) {
                    HomeRuleRow(
                        title: "Take-five break cards",
                        caption: "One calm card after a 50-minute stretch — never a nag loop.",
                        isOn: $ruleBreaks
                    )
                    HomeRuleRow(
                        title: "Settle overdue routines",
                        caption: "A routine past due gets one calm nudge — not a nag loop.",
                        isOn: $ruleRoutines
                    )
                    HomeRuleRow(
                        title: "One nudge a day, after 6 am",
                        caption: "At most one proactive suggestion a day, only once you're at your Mac.",
                        isOn: $ruleDaily
                    )
                    HomeRuleRow(
                        title: "Respect Do Not Disturb",
                        caption: "When Focus is on, everything waits quietly.",
                        isOn: $ruleDnd
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // Visiting the page counts as reading — clear the badge.
            engine.markAllRead()
        }
    }

    // MARK: - Pieces

    private var sensingStatusLine: String {
        let focus = engine.isDoNotDisturbActive ? "Focus on" : "Focus off"
        let idle = engine.secondsSinceLastInput
        let input: String
        if idle < 5 {
            input = "you're active"
        } else if idle < 3600 {
            input = "input \(Int(idle))s ago"
        } else {
            input = "input \(Int(idle / 60))m ago"
        }
        let batch = engine.lastDeliveredDay == ProactiveSuggestionEngine.dayString(Date())
            ? "batch sent today"
            : "batch waiting"
        return "\(focus) · \(input) · \(batch)"
    }

    private func suggestionCard(_ card: LazySuggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: card.kind))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.overlayCursorBlue)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(card.body)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let routineID = card.routineID {
                Button("Done") {
                    engine.completeRoutine(id: routineID)
                }
                .buttonStyle(GelButtonStyle(accentTint: true))
            }

            Button {
                engine.dismiss(id: card.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Dismiss")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func icon(for kind: LazySuggestion.Kind) -> String {
        switch kind {
        case .routine: return "arrow.clockwise"
        case .usage: return "clock"
        case .note: return "lightbulb"
        }
    }

    private func routineRow(_ routine: LazyRoutine) -> some View {
        let overdue = routine.isOverdue()
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(routineStatusText(routine))
                    .font(.system(size: 12))
                    .foregroundColor(overdue ? DS.Colors.warning : DS.Colors.textTertiary)
            }
            Spacer()
            Button {
                engine.removeRoutine(id: routine.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove routine")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func routineStatusText(_ routine: LazyRoutine) -> String {
        let cadence = Self.cadenceLabel(hours: routine.intervalHours)
        if routine.isOverdue() {
            return "\(cadence) · was due \(routine.overdueLabel())"
        }
        let relative = RelativeDateTimeFormatter()
            .localizedString(for: routine.nextDueDate(), relativeTo: Date())
        return "\(cadence) · due \(relative)"
    }

    private static func cadenceLabel(hours: Double) -> String {
        cadenceOptions.first { $0.hours == hours }?.label ?? "every \(Int(hours))h"
    }
}

private struct HomeRuleRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.gel)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

// MARK: - Skills Page

struct HomeSkillsPage: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var newSkillName = ""
    @State private var newSkillPrompt = ""
    @State private var addErrorText: String?
    @State private var expandedBundledSkillName: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Skills")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Skills are instructions I always follow — paste-as-plain-text, always-confirm-before-send, that sort of thing.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)

                // B2: bundled MIT skills — tap a row to read the full skill.
                HomeCard(title: "Bundled skills · \(BundledSkills.all.count)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(BundledSkills.all) { entry in
                            let isExpanded = expandedBundledSkillName == entry.name
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedBundledSkillName = isExpanded ? nil : entry.name
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(entry.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(DS.Colors.textPrimary)
                                        Spacer()
                                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(DS.Colors.textTertiary)
                                    }
                                    Text(entry.description)
                                        .font(.system(size: 12))
                                        .foregroundColor(DS.Colors.textTertiary)
                                        .lineLimit(isExpanded ? nil : 2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                    if isExpanded {
                                        Text(entry.body)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(DS.Colors.textSecondary)
                                            .lineLimit(nil)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .fill(Color.black.opacity(0.30))
                                            )
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Existing skills.
                if companionManager.userSkills.isEmpty {
                    HomeCard {
                        Text("No skills yet.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(companionManager.userSkills) { skill in
                            HStack(alignment: .top, spacing: 12) {
                                GelCheckmark(size: 18)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(skill.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(DS.Colors.textPrimary)
                                    Text(skill.promptText)
                                        .font(.system(size: 12))
                                        .foregroundColor(DS.Colors.textTertiary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button {
                                    companionManager.removeUserSkill(id: skill.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(DS.Colors.textTertiary)
                                        .frame(width: 26, height: 26)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(Color.white.opacity(0.05))
                                        )
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .help("Remove skill")
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                    )
                            )
                        }
                    }
                }

                // Add a skill.
                HomeCard(title: "Add a skill") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name — e.g. Plain-text paste", text: $newSkillName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.black.opacity(0.30))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )

                        TextField("Instruction — e.g. Always paste clipboard text without formatting.", text: $newSkillPrompt)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.black.opacity(0.30))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )

                        if let addErrorText {
                            Text(addErrorText)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.warningText)
                        }

                        Button {
                            addSkill()
                        } label: {
                            Text("Add skill")
                        }
                        .buttonStyle(GelButtonStyle(accentTint: true))
                        .disabled(newSkillName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                // MIT attribution (rule 7) — mirrors NOTICE.md at the repo root.
                Text("Bundled skills © Nous Research (hermes-agent, MIT) · blender-toolkit via dev-gom marketplace (MIT)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addSkill() {
        let name = newSkillName.trimmingCharacters(in: .whitespaces)
        let prompt = newSkillPrompt.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !prompt.isEmpty else {
            addErrorText = "Both a name and an instruction are needed."
            return
        }
        if companionManager.addUserSkill(named: name, promptText: prompt) {
            newSkillName = ""
            newSkillPrompt = ""
            addErrorText = nil
        } else {
            addErrorText = "Couldn't add that skill — a skill with the same name may already exist."
        }
    }
}

// MARK: - Settings Page

struct HomeSettingsPage: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var mailManager: MailManager
    let onReplayTour: () -> Void

    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var outlookSetupExpanded = false

    private var voiceEngineLine: String {
        let lockedDate = UserDefaults.standard.string(forKey: "clickyTTSQuotaExhaustedDate")
        if lockedDate == todayString {
            return "System voice — ElevenLabs quota exhausted (retries daily)"
        }
        return "ElevenLabs (free tier)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                HomeCard(title: "Model") {
                    Picker("Model", selection: Binding(
                        get: { companionManager.selectedModel },
                        set: { companionManager.setSelectedModel($0) }
                    )) {
                        Text("Fast").tag("fast")
                        Text("Smart").tag("smart")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                HomeCard(title: "General") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Launch at login")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            if let launchAtLoginError {
                                Text(launchAtLoginError)
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.warningText)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin },
                            set: { setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.gel)
                    }

                    Divider()
                        .overlay(Color.white.opacity(0.06))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Voice engine")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(voiceEngineLine)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    Divider()
                        .overlay(Color.white.opacity(0.06))

                    Button {
                        onReplayTour()
                    } label: {
                        Text("Replay the welcome tour")
                    }
                    .buttonStyle(GelButtonStyle())
                }

                HomeCard(title: "Permissions") {
                    HomePermissionRow(name: "Accessibility", granted: companionManager.hasAccessibilityPermission)
                    HomePermissionRow(name: "Screen Recording", granted: companionManager.hasScreenRecordingPermission)
                    HomePermissionRow(name: "Microphone", granted: companionManager.hasMicrophonePermission)
                    HomePermissionRow(name: "Screen Content", granted: companionManager.hasScreenContentPermission)
                }

                HomeCard(title: "Mail") {
                    mailAccountRow(.gmail)
                    Divider()
                        .overlay(Color.white.opacity(0.06))
                    mailAccountRow(.outlook)
                }

                if let lastError = companionManager.lastErrorText {
                    HomeCard(title: "Last issue") {
                        Text(lastError)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = isEnabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = "Couldn't update login item: \(error.localizedDescription)"
        }
    }

    // MARK: - Mail (M6.1)

    private static let mailTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    @ViewBuilder
    private func mailAccountRow(_ provider: MailProvider) -> some View {
        let status = mailManager.status(for: provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(status.isConnected ? DS.Colors.success : DS.Colors.textTertiary.opacity(0.7))
                    .frame(width: 7, height: 7)
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if status.isConnected {
                    Button {
                        mailManager.syncNow(provider)
                    } label: {
                        Text("Sync now")
                    }
                    .buttonStyle(GelButtonStyle())
                    Button {
                        mailManager.disconnect(provider)
                    } label: {
                        Text("Disconnect")
                    }
                    .buttonStyle(GelButtonStyle())
                } else {
                    Button {
                        if provider == .outlook, MailOAuthClients.config(for: provider) == nil {
                            outlookSetupExpanded.toggle()
                        } else {
                            mailManager.connect(provider)
                        }
                    } label: {
                        Text(status.isConnecting ? "Waiting for browser…" : "Connect")
                    }
                    .buttonStyle(GelButtonStyle())
                    .disabled(status.isConnecting)
                }
            }
            Text(mailStatusLine(status))
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
            if let errorText = status.lastErrorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
            }
            if provider == .outlook, outlookSetupExpanded, !status.isConnected {
                outlookSetupStepsCard
            }
        }
    }

    private func mailStatusLine(_ status: MailManager.ProviderStatus) -> String {
        guard status.isConnected else { return "Not connected" }
        var parts: [String] = []
        if !status.email.isEmpty { parts.append(status.email) }
        parts.append("\(status.messageCount) messages")
        if let lastSync = status.lastSyncAt {
            parts.append("synced \(Self.mailTimeFormatter.string(from: lastSync))")
        } else if status.isSyncing {
            parts.append("syncing…")
        }
        return parts.joined(separator: " · ")
    }

    /// Lazy's Azure steps, adapted (Clicky also asks for Mail.Send so M6.4
    /// can send approved drafts from Outlook too).
    private var outlookSetupStepsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Outlook needs a one-time, free Azure app registration:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("1. portal.azure.com → App registrations → New registration")
            Text("2. Accounts: any organizational directory + personal Microsoft accounts")
            Text("3. Redirect URI: platform Web → http://127.0.0.1")
            Text("4. API permissions → Microsoft Graph → delegated: Mail.Read, Mail.Send, offline_access")
            Text("5. Copy the Application (client) ID into mail-clients.json (outlook.clientId), then Connect")
        }
        .font(.system(size: 11))
        .foregroundColor(DS.Colors.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }
}

private struct HomePermissionRow: View {
    let name: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 7, height: 7)
                .shadow(color: (granted ? DS.Colors.success : DS.Colors.warning).opacity(0.6), radius: 3)
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Text(granted ? "Granted" : "Needed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(granted ? DS.Colors.success : DS.Colors.warningText)
        }
    }
}
