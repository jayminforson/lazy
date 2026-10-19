//
//  NotchEyes.swift
//  Clicky
//
//  The pair of cartoon eyes that live in the notch pill: they blink on a
//  random schedule, glance around when the pointer is far, and track the
//  pointer when it comes near. Recreated from the HeyClicky reference
//  (NotchEyeView / eyeDartX / pupilOffset / eyesShut behavior).
//

import AppKit
import SwiftUI

// MARK: - Single Eye

struct NotchEyeView: View {
    /// Pupil offset in unit space (-1...1); x grows right, y grows down.
    var pupilOffset: CGSize = .zero
    /// Squashed shut (mid-blink or resting close).
    var isShut: Bool = false

    private let eyeWidth: CGFloat = 17
    private let eyeHeight: CGFloat = 20
    private let pupilTravel: CGFloat = 4.5

    var body: some View {
        ZStack {
            // Sclera — white jelly bean.
            RoundedRectangle(cornerRadius: eyeWidth * 0.48, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(white: 0.90)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: eyeWidth * 0.48, style: .continuous)
                        .stroke(Color.black.opacity(0.14), lineWidth: 0.6)
                )

            // Pupil + catchlight.
            ZStack {
                Circle()
                    .fill(Color(white: 0.10))
                    .frame(width: 7.5, height: 7.5)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.4, height: 2.4)
                    .offset(x: 1.6, y: -1.8)
            }
            .offset(
                x: pupilOffset.width * pupilTravel,
                y: pupilOffset.height * pupilTravel
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: pupilOffset)
        }
        .frame(width: eyeWidth, height: eyeHeight)
        // Blink: squash vertically to a line.
        .scaleEffect(x: 1.0, y: isShut ? 0.08 : 1.0, anchor: .center)
        .animation(.easeInOut(duration: 0.07), value: isShut)
    }
}

// MARK: - Eyes Pair (owns blink + look behavior)

struct NotchEyesPairView: View {
    /// When true the eyes shut (unused by the pill today; kept for parity
    /// with the reference's eyesShut state for later surfaces).
    var forceShut: Bool = false

    @State private var isLeftShut = false
    @State private var isRightShut = false
    @State private var pupilTarget: CGSize = .zero
    @State private var idleDart: CGSize = .zero

    @State private var blinkTimer: Timer?
    @State private var lookTimer: Timer?
    @State private var dartTimer: Timer?

    var body: some View {
        HStack(spacing: 5) {
            NotchEyeView(pupilOffset: pupilTarget, isShut: forceShut || isLeftShut)
            NotchEyeView(pupilOffset: pupilTarget, isShut: forceShut || isRightShut)
        }
        .onAppear { startBehaviors() }
        .onDisappear { stopBehaviors() }
    }

    // MARK: Behaviors

    private func startBehaviors() {
        scheduleNextBlink(after: randomizedBlinkDelay())
        startLookPolling()
        scheduleNextDart()
    }

    private func stopBehaviors() {
        blinkTimer?.invalidate()
        lookTimer?.invalidate()
        dartTimer?.invalidate()
        blinkTimer = nil
        lookTimer = nil
        dartTimer = nil
    }

    /// Random 2.4–5.6 s between blinks; double-blinks occasionally.
    private func randomizedBlinkDelay() -> TimeInterval {
        2.4 + Double.random(in: 0...3.2)
    }

    private func scheduleNextBlink(after delay: TimeInterval) {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in
                performBlink()
            }
        }
    }

    private func performBlink() {
        guard !forceShut else {
            scheduleNextBlink(after: randomizedBlinkDelay())
            return
        }
        withAnimation(.easeInOut(duration: 0.07)) {
            isLeftShut = true
            isRightShut = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.easeInOut(duration: 0.09)) {
                isLeftShut = false
                isRightShut = false
            }
            // ~12% chance of an immediate double blink.
            if Double.random(in: 0...1) < 0.12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    performBlink()
                }
            } else {
                scheduleNextBlink(after: randomizedBlinkDelay())
            }
        }
    }

    /// Polls the global pointer location ~12 Hz: within 340 pt of the notch
    /// the pupils track it; beyond that they rest on a slow idle dart.
    private func startLookPolling() {
        lookTimer?.invalidate()
        lookTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { _ in
            Task { @MainActor in
                updatePupilTarget()
            }
        }
    }

    private func updatePupilTarget() {
        let mouseLocation = NSEvent.mouseLocation
        guard let eyeScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main else { return }
        // The eyes live in the top-center pill of that screen.
        let eyeCenter = CGPoint(x: eyeScreen.frame.midX, y: eyeScreen.frame.maxY - 17)
        let dx = mouseLocation.x - eyeCenter.x
        let dy = mouseLocation.y - eyeCenter.y
        let distance = (dx * dx + dy * dy).squareRoot()

        if distance < 340 {
            pupilTarget = CGSize(
                width: max(-1, min(1, dx / 170)),
                // AppKit y grows up; SwiftUI offset y grows down.
                height: max(-1, min(1, -dy / 90))
            )
        } else {
            pupilTarget = idleDart
        }
    }

    /// Occasional small random glances while nobody is near.
    private func scheduleNextDart() {
        dartTimer?.invalidate()
        dartTimer = Timer.scheduledTimer(
            withTimeInterval: Double.random(in: 2.8...5.4),
            repeats: false
        ) { _ in
            Task { @MainActor in
                idleDart = CGSize(
                    width: CGFloat.random(in: -0.55...0.55),
                    height: CGFloat.random(in: -0.35...0.45)
                )
                scheduleNextDart()
            }
        }
    }
}
