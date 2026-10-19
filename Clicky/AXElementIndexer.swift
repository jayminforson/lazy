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
struct IndexedAXElement {
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

    /// Badges burned onto one screenshot — beyond this the model falls back
    /// to coordinates rather than drowning in numbers.
    static let maximumIndexedElementCount = 40
    /// AX walk budget per step (bounded so a pathological tree can't stall
    /// the run loop).
    static let maximumVisitedElementCount = 500
    static let maximumTreeDepth = 8

    /// Roles accepted as click targets even when AX reports no AXPress
    /// action (text-ish controls focus via press in most apps).
    private static let fieldRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSlider"
    ]

    // MARK: - Enumeration

    /// Numbers the frontmost app's pressable elements whose centers fall on
    /// the captured cursor screen, in reading order (top rows first, left to
    /// right). Returns [] when AX is unavailable or the frontmost app is
    /// Clicky itself — callers keep the coordinate path.
    static func indexElements(capture: CompanionScreenCapture) -> [IndexedAXElement] {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return []
        }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        var candidates: [(element: AXUIElement, role: String, title: String, frame: CGRect)] = []
        var visitedCount = 0
        collectPressable(appElement, depth: 0, visitedCount: &visitedCount, into: &candidates)

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
        if !indexed.isEmpty {
            print("🧩 AX index: \(indexed.count) element(s) in \(capture.label) (visited \(visitedCount))")
        }
        return indexed
    }

    private static func collectPressable(
        _ element: AXUIElement,
        depth: Int,
        visitedCount: inout Int,
        into candidates: inout [(element: AXUIElement, role: String, title: String, frame: CGRect)]
    ) {
        guard depth <= maximumTreeDepth, visitedCount < maximumVisitedElementCount else { return }
        visitedCount += 1

        if let candidate = pressableCandidate(from: element) {
            candidates.append(candidate)
        }

        guard let children = copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement] else { return }
        for child in children {
            collectPressable(child, depth: depth + 1, visitedCount: &visitedCount, into: &candidates)
        }
    }

    private static func pressableCandidate(
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

    // MARK: - AX attribute helpers

    private static func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        copyAttribute(attribute, from: element) as? Bool
    }

    private static func copyActionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else { return [] }
        return (names as? [String]) ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
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
    static func performPress(_ element: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return result == .success
    }
}
