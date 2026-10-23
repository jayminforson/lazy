//
//  AXElementIndexer.swift
//  Clicky
//
//  M4 AX-tree grounding for computer-use runs: walks the frontmost app's
//  Accessibility tree, numbers the pressable elements that sit on the
//  captured cursor screen (reading order), burns amber badges into the
//  screenshot sent to the model, and resolves [GUI_CLICK_EL:n] tags back
//  to AXPress — which presses elements without moving the mouse, so it
//  works on background/occluded windows too. Coordinates-only GUI_CLICK
//  stays as the fallback path.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One numbered, pressable AX element for the current GUI step.
/// @unchecked Sendable: the stored AXUIElement is a CF object whose message
/// calls are thread-safe (each is an independent IPC); M10.b runs the walk
/// and presses off the main actor so a busy target app can never freeze the
/// UI — refs are only transported across, never shared mutably.
struct IndexedAXElement: @unchecked Sendable {
    /// 1-based reading-order number — the n in [GUI_CLICK_EL:n].
    let index: Int
    /// The live AX element reference (valid only for this step's app state).
    let element: AXUIElement
    /// Raw AX role, e.g. "AXButton".
    let role: String
    /// Title or description, e.g. "Save".
    let title: String
    /// Frame in CG global coordinates (top-left origin, y downward).
    let cgFrame: CGRect
}

enum AXElementIndexer {

    // MARK: - Caps

    // All constants below are nonisolated: the walk runs off the main
    // actor (M10.b) and reads these — plain Sendable values, no isolation.

    /// Badges burned onto one screenshot — beyond this the model falls back
    /// to coordinates rather than drowning in numbers.
    nonisolated static let maximumIndexedElementCount = 40
    /// AX walk budget per step (bounded so a pathological tree can't stall
    /// the run loop).
    nonisolated static let maximumVisitedElementCount = 500
    nonisolated static let maximumTreeDepth = 8

    /// Roles accepted as click targets even when AX reports no AXPress
    /// action (text-ish controls focus via press in most apps).
    private nonisolated static let fieldRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider"
    ]

    // MARK: - Enumeration

    /// AX IPC budget: any single AX message to a busy/wedged target app is
    /// cut off after this many seconds (M10.b — the 2026-10-23 drill froze
    /// the whole app for ~16 s inside one blocked AXUIElementCopyAttributeValue
    /// call on the main thread; the stall dump named it exactly).
    nonisolated static let messagingTimeoutSeconds: Float = 2.0
    /// Whole-walk wall-clock budget checked between visits: bounds a
    /// pathological tree (many timing-out calls) to ~this long, then the
    /// walk returns what it has — the run falls back to coordinate clicks.
    nonisolated static let walkDeadlineSeconds: TimeInterval = 3.5

    /// Numbers the frontmost app's pressable elements whose centers fall on
    /// the captured cursor screen, in reading order (top rows first, left to
    /// right). Returns [] when AX is unavailable or the frontmost app is
    /// Clicky itself — callers keep the coordinate path.
    ///
    /// M10.b: runs OFF the main actor via a detached task — a busy target
    /// app can no longer freeze the UI mid-run (healthy apps: the same
    /// 10–100 ms walk, one task hop). Per-call timeout + walk deadline cap
    /// the worst case; on timeout the walk just returns fewer badges.
    static func indexElements(capture: CompanionScreenCapture) async -> [IndexedAXElement] {
        await Task.detached(priority: .userInitiated) {
            performIndexWalk(capture: capture)
        }.value
    }

    // MARK: - M11 pointing snap

    /// Snap a model-guessed point (CG top-left global) to the real AX element
    /// it sits on, or the nearest small control just off its edge. Run clicks
    /// are AX-grounded, but chat [POINT:...] trusted the vision model's raw
    /// pixel estimate — imprecise enough to land on the wrong element, which
    /// is why pointing was the inaccurate one. Fail-open: nil when nothing
    /// real is near, so callers keep the model's coordinate exactly as before
    /// (this can only sharpen a point, never replace a working one). The walk
    /// is off-main and bounded via `indexElements` (M10.b): healthy apps
    /// cost one 10–100 ms hop, and this runs after the reply has spoken.
    static func snapToElement(near cgPoint: CGPoint,
                              capture: CompanionScreenCapture) async -> CGPoint? {
        let elements = await indexElements(capture: capture)
        guard !elements.isEmpty else { return nil }

        let screenArea = capture.displayFrame.width * capture.displayFrame.height
        // Never snap to a window/panel's middle — pointing at the center of a
        // big container is worse than the model's own coordinate.
        let sizeCap = screenArea * 0.4
        /// Nearest-control tolerance: only corrects a point that fell just off
        /// an element's edge, never leaps across a gap to a different one.
        let nearestTolerance: CGFloat = 35

        func area(of element: IndexedAXElement) -> CGFloat {
            element.cgFrame.width * element.cgFrame.height
        }
        func distanceToFrame(of element: IndexedAXElement) -> CGFloat {
            let frame = element.cgFrame
            let deltaX = max(frame.minX - cgPoint.x, 0, cgPoint.x - frame.maxX)
            let deltaY = max(frame.minY - cgPoint.y, 0, cgPoint.y - frame.maxY)
            return hypot(deltaX, deltaY)
        }

        // Pass A — the smallest element containing the point (the specific
        // control the model meant), as long as it isn't window-sized.
        let containing = elements.filter {
            $0.cgFrame.insetBy(dx: -6, dy: -6).contains(cgPoint) && area(of: $0) <= sizeCap
        }
        if let best = containing.min(by: { area(of: $0) < area(of: $1) }) {
            return CGPoint(x: best.cgFrame.midX, y: best.cgFrame.midY)
        }

        // Pass B — nearest small control within tolerance (the point fell
        // just off the edge / into the gap beside the element it aimed at).
        let smallControls = elements.filter { area(of: $0) <= sizeCap }
        guard let nearest = smallControls.min(by: { distanceToFrame(of: $0) < distanceToFrame(of: $1) }),
              distanceToFrame(of: nearest) <= nearestTolerance else {
            return nil
        }
        return CGPoint(x: nearest.cgFrame.midX, y: nearest.cgFrame.midY)
    }

    /// The walk itself — nonisolated: pure AX IPC + CoreGraphics reads, no
    /// main-actor state. Called only from `indexElements`'s detached task.
    nonisolated static func performIndexWalk(capture: CompanionScreenCapture) -> [IndexedAXElement] {
        let walkStartDate = Date()
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return []
        }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        // Caps EVERY AX message to this app while the target is busy — a
        // wedged app costs ≤2 s per call instead of blocking indefinitely.
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)

        var candidates: [(element: AXUIElement, role: String, title: String, frame: CGRect)] = []
        var visitedCount = 0
        let walkDeadline = walkStartDate.addingTimeInterval(walkDeadlineSeconds)
        collectPressable(appElement, depth: 0, visitedCount: &visitedCount, deadline: walkDeadline, into: &candidates)

        let mainDisplayHeight = CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
        let screenCGRect = CGRect(
            x: capture.displayFrame.origin.x,
            y: mainDisplayHeight - capture.displayFrame.maxY,
            width: capture.displayFrame.width,
            height: capture.displayFrame.height
        )

        let onCursorScreen = candidates.filter { candidate in
            screenCGRect.contains(CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
        }

        // Reading order: horizontal bands top-down, then left-right.
        let bandHeight: CGFloat = 48
        let sorted = onCursorScreen.sorted { lhs, rhs in
            let lhsBand = Int(floor(lhs.frame.minY / bandHeight))
            let rhsBand = Int(floor(rhs.frame.minY / bandHeight))
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            return lhs.frame.minX < rhs.frame.minX
        }

        let indexed = sorted.prefix(maximumIndexedElementCount).enumerated().map { offset, candidate in
            IndexedAXElement(
                index: offset + 1,
                element: candidate.element,
                role: candidate.role,
                title: candidate.title,
                cgFrame: candidate.frame
            )
        }
        let walkElapsed = Date().timeIntervalSince(walkStartDate)
        if !indexed.isEmpty {
            print("🧩 AX index: \(indexed.count) element(s) in \(capture.label) (visited \(visitedCount), \(String(format: "%.0f", walkElapsed * 1000))ms)")
        } else if walkElapsed >= walkDeadlineSeconds * 0.8 || visitedCount >= maximumVisitedElementCount {
            // Evidence line: the walk was cut short — badges missing on this
            // step is expected, a UI freeze is not (the walk is off-main now).
            BrainLog.line("ax: walk degraded in \(capture.label) — visited \(visitedCount), \(String(format: "%.2f", walkElapsed))s (busy app; badges may be incomplete)")
        }
        return indexed
    }

    nonisolated private static func collectPressable(
        _ element: AXUIElement,
        depth: Int,
        visitedCount: inout Int,
        deadline: Date,
        into candidates: inout [(element: AXUIElement, role: String, title: String, frame: CGRect)]
    ) {
        guard depth <= maximumTreeDepth, visitedCount < maximumVisitedElementCount else { return }
        // Wall-clock bail: a wedged app timing out per call would otherwise
        // stretch the walk to visits × timeout; stop and keep what we have.
        guard Date() <= deadline else { return }
        visitedCount += 1

        if let candidate = pressableCandidate(from: element) {
            candidates.append(candidate)
        }

        guard let children = copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement] else { return }
        for child in children {
            collectPressable(child, depth: depth + 1, visitedCount: &visitedCount, deadline: deadline, into: &candidates)
        }
    }

    nonisolated private static func pressableCandidate(
        from element: AXUIElement
    ) -> (element: AXUIElement, role: String, title: String, frame: CGRect)? {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else { return nil }
        if boolAttribute(kAXEnabledAttribute, from: element) == false { return nil }
        if boolAttribute(kAXHiddenAttribute, from: element) == true { return nil }
        guard let frame = frame(of: element),
              frame.width >= 6, frame.height >= 6 else { return nil }

        let actionNames = copyActionNames(of: element)
        guard actionNames.contains("AXPress") || fieldRoles.contains(role) else { return nil }

        let title = stringAttribute(kAXTitleAttribute, from: element)
            ?? stringAttribute(kAXDescriptionAttribute, from: element)
            ?? ""
        return (element, role, title, frame)
    }

    // MARK: - AX attribute helpers (nonisolated: pure AX IPC, callable from
    // the detached walk; each call is bounded by the app-element timeout)

    nonisolated private static func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    nonisolated private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        copyAttribute(attribute, from: element) as? Bool
    }

    nonisolated private static func copyActionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else { return [] }
        return (names as? [String]) ?? []
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(kAXPositionAttribute, from: element),
              let sizeValue = copyAttribute(kAXSizeAttribute, from: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: - Badge overlay

    /// Burns amber numbered badges at element centers into a copy of the
    /// step screenshot. Returns the original data untouched when there is
    /// nothing to draw or decoding fails (the run just loses grounding).
    static func overlayBadges(
        on imageData: Data,
        elements: [IndexedAXElement],
        capture: CompanionScreenCapture
    ) -> Data {
        guard !elements.isEmpty,
              let bitmap = NSBitmapImageRep(data: imageData),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return imageData
        }

        let imageWidth = CGFloat(bitmap.pixelsWide)
        let imageHeight = CGFloat(bitmap.pixelsHigh)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        guard imageWidth > 0, imageHeight > 0, displayWidth > 0, displayHeight > 0 else { return imageData }

        let mainDisplayHeight = CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
        let ratioX = imageWidth / displayWidth
        let ratioY = imageHeight / displayHeight
        let badgeRadius = max(9, imageWidth * 0.014)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let fill = NSColor(calibratedRed: 1.0, green: 0.698, blue: 0.141, alpha: 0.95)
        for element in elements {
            // CG global (top-left) → display-local → screenshot pixels (top-left).
            let appKitY = mainDisplayHeight - element.cgFrame.midY
            let localX = element.cgFrame.midX - capture.displayFrame.origin.x
            let localY = appKitY - capture.displayFrame.origin.y
            var pixelX = localX * ratioX
            var pixelYTopDown = (displayHeight - localY) * ratioY
            pixelX = min(max(pixelX, badgeRadius + 3), imageWidth - badgeRadius - 3)
            pixelYTopDown = min(max(pixelYTopDown, badgeRadius + 3), imageHeight - badgeRadius - 3)

            // Bitmap contexts are bottom-left origin — flip for drawing.
            let drawY = imageHeight - pixelYTopDown
            let badgeRect = CGRect(
                x: pixelX - badgeRadius,
                y: drawY - badgeRadius,
                width: badgeRadius * 2,
                height: badgeRadius * 2
            )
            NSBezierPath(ovalIn: badgeRect).fill()
            fill.setStroke()
            let ring = NSBezierPath(ovalIn: badgeRect)
            ring.lineWidth = max(1.5, badgeRadius * 0.12)
            ring.stroke()

            let label = NSString(string: "\(element.index)")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: badgeRadius * 1.2),
                .foregroundColor: NSColor.white,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    return style
                }()
            ]
            let labelSize = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: pixelX - labelSize.width / 2, y: drawY - labelSize.height / 2),
                withAttributes: attributes
            )
        }

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) ?? imageData
    }

    // MARK: - Legend + press

    /// The per-step text part describing the badges, injected next to the
    /// screenshot so the model can map numbers to controls.
    static func legendText(for elements: [IndexedAXElement]) -> String {
        let entries = elements.map { element -> String in
            var role = element.role
            if role.hasPrefix("AX") { role = String(role.dropFirst(2)) }
            role = role.lowercased()
            return element.title.isEmpty
                ? "\(element.index) \(role)"
                : "\(element.index) \(role) \"\(element.title)\""
        }
        return "amber numbered badges mark clickable elements — when your target has a badge, prefer [GUI_CLICK_EL:n] for it: "
            + entries.joined(separator: "; ")
    }

    /// Presses the indexed element via AX — no cursor movement, so clicks
    /// land in background windows too. Returns false when the action is
    /// rejected (verification then flags the step as no-effect).
    ///
    /// M10.b: off the main actor with the per-app messaging timeout — a
    /// busy target app costs ≤2 s and returns false, never a UI freeze.
    static func performPress(_ element: AXUIElement) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            // The timeout is per-app (set on any element of that app); the
            // walk may not have run for this app, so set it here too.
            AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }.value
    }
}
