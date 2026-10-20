//
//  GelStyles.swift
//  Clicky
//
//  The "gel" visual language: glossy dark plates with a top-light sweep,
//  inner shadow, and soft outer lift — buttons, switches, and surfaces all
//  share the same candy-shell treatment. Recreated from the HeyClicky
//  reference (GelButton/GelSwitch/GelSurface); no shipped assets.
//

import SwiftUI
import AppKit

// MARK: - Gel Surface

/// A glossy dark plate: subtle vertical gradient, top gloss line, inner
/// top shadow, and a soft outer drop — the base card/window material.
struct GelSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    var fillBase: Color = DS.Colors.surface1
    var fillTop: Color = DS.Colors.surface2

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [fillTop, fillBase],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    // Top gloss sweep — the wet-gel highlight.
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.07),
                                        Color.white.opacity(0.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: cornerRadius * 2.2)
                            .clipped(),
                        alignment: .top
                    )
                    // Hairline: bright at top, dark at bottom — reads as an
                    // edge catching light.
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.14),
                                        Color.white.opacity(0.04),
                                        Color.black.opacity(0.25)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 10)
                    .shadow(color: Color.black.opacity(0.20), radius: 4, x: 0, y: 2)
            )
    }
}

extension View {
    /// Applies the shared gel plate treatment.
    func gelSurface(cornerRadius: CGFloat = 20, fillBase: Color = DS.Colors.surface1, fillTop: Color = DS.Colors.surface2) -> some View {
        self.modifier(GelSurfaceModifier(cornerRadius: cornerRadius, fillBase: fillBase, fillTop: fillTop))
    }
}

// MARK: - Gel Button

/// Glossy candy-shell button: rest gradient with top gloss, accent-tinted
/// glow on hover, squish on press.
struct GelButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 14
    var accentTint: Bool = false

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: plateColors(isPressed: configuration.isPressed),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(configuration.isPressed ? 0.03 : 0.09),
                                        Color.white.opacity(0.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 22)
                            .clipped(),
                        alignment: .top
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isHovered ? 0.22 : 0.13),
                                        Color.white.opacity(0.03),
                                        Color.black.opacity(0.30)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(
                color: (accentTint ? DS.Colors.accent : Color.black).opacity(isHovered ? 0.35 : 0.22),
                radius: isHovered ? 10 : 6,
                x: 0,
                y: 3
            )
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovered ? 1.02 : 1.0))
            .animation(.easeOut(duration: configuration.isPressed ? 0.08 : 0.18), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func plateColors(isPressed: Bool) -> [Color] {
        if isPressed {
            return [DS.Colors.surface4, DS.Colors.surface3]
        }
        if isHovered {
            return accentTint
                ? [DS.Colors.accent.blendedWithWhite(fraction: 0.12), DS.Colors.accent]
                : [DS.Colors.surface4, DS.Colors.surface3]
        }
        return [DS.Colors.surface3, DS.Colors.surface2]
    }
}

// MARK: - Gel Switch

/// Glossy toggle: inner-shadowed track, glossy thumb, accent when on.
struct GelSwitchStyle: ToggleStyle {
    @State private var isHovered = false

    private let trackWidth: CGFloat = 42
    private let trackHeight: CGFloat = 25
    private let thumbSize: CGFloat = 19

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        Capsule()
            .fill(
                LinearGradient(
                    colors: isOn
                        ? [DS.Colors.accent.blendedWithWhite(fraction: 0.10), DS.Colors.accent]
                        : [DS.Colors.surface4, DS.Colors.surface3],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isOn ? 0.30 : 0.14),
                                Color.white.opacity(0.03),
                                Color.black.opacity(0.35)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                GeometryReader { geometry in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color.white.opacity(0.82)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1.5)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                        )
                        .offset(
                            x: isOn
                                ? geometry.size.width - thumbSize - 3
                                : 3,
                            y: (geometry.size.height - thumbSize) / 2
                        )
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
                }
            )
            .frame(width: trackWidth, height: trackHeight)
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture {
                withAnimation { configuration.$isOn.wrappedValue.toggle() }
            }
    }
}

// MARK: - Gel Checkmark

/// Small glossy success disc with a check — used in skills lists and
/// completion rows.
struct GelCheckmark: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            DS.Colors.success.blendedWithWhite(fraction: 0.18),
                            DS.Colors.success
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                )
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundColor(Color.black.opacity(0.75))
        }
        .frame(width: size, height: size)
        .shadow(color: DS.Colors.success.opacity(0.45), radius: 4, y: 1)
    }
}

// MARK: - Gel Switch Convenience

extension ToggleStyle where Self == GelSwitchStyle {
    static var gel: GelSwitchStyle { GelSwitchStyle() }
}
