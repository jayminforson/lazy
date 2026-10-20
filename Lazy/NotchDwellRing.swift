//
//  NotchDwellRing.swift
//  Clicky
//
//  Hover-dwell indicator for the notch pill: a ring that fills around the
//  status dot while the pointer rests on the pill; completing the fill opens
//  the notch sheet (the HeyClicky "hover-rest" peek, recreated).
//

import SwiftUI
import Combine

struct NotchDwellRingView: View {
    /// Fill amount 0...1.
    var progress: CGFloat
    /// Dot color shown at the ring's center (the pill status color).
    var dotColor: Color

    private let ringSize: CGFloat = 20

    var body: some View {
        ZStack {
            // Track.
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 2)

            // Fill arc, starting at 12 o'clock.
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(
                    LinearGradient(
                        colors: [
                            DS.Colors.accentText,
                            DS.Colors.accent
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: DS.Colors.accent.opacity(0.7), radius: progress > 0.02 ? 4 : 0)

            // Center status dot.
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: dotColor.opacity(0.7), radius: 3)
        }
        .frame(width: ringSize, height: ringSize)
        // A nearly-invisible halo keeps hover targeting generous.
        .frame(width: ringSize + 8, height: ringSize + 8)
        .contentShape(Circle())
        .scaleEffect(progress > 0.99 ? 1.12 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: progress > 0.99)
    }
}

// MARK: - Dwell Driver

/// Drives dwell progress while a surface is hovered: 0 → 1 over
/// `duration` seconds, resetting fast on hover exit.
@MainActor
final class NotchDwellController: ObservableObject {
    @Published private(set) var progress: CGFloat = 0

    private let duration: TimeInterval
    private var timer: Timer?

    init(duration: TimeInterval = 0.6) {
        self.duration = duration
    }

    var isComplete: Bool { progress >= 1 }

    func hoverBegan(onComplete: @escaping () -> Void) {
        guard timer == nil, progress < 1 else { return }
        let step = 0.03 / duration
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progress = min(1, self.progress + CGFloat(step))
                if self.progress >= 1 {
                    self.timer?.invalidate()
                    self.timer = nil
                    onComplete()
                }
            }
        }
    }

    func hoverEnded() {
        timer?.invalidate()
        timer = nil
        withAnimation(.easeOut(duration: 0.18)) {
            progress = 0
        }
    }

    /// Resets without animation (called when the peek/sheet opens).
    func reset() {
        timer?.invalidate()
        timer = nil
        progress = 0
    }
}
