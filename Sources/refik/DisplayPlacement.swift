import Foundation
import CoreGraphics

/// Screen geometry uses AppKit points, independent of backing pixel scale.
struct DisplayDescriptor: Identifiable, Equatable {
    let id: String
    let legacyID: UInt32
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat
    let isMain: Bool
}

struct DisplayPosition: Codable, Equatable {
    var edge: String
    var vertical: Double
}

/// Pure policy: no cursor reads or NSScreen dependencies, and fallback selection
/// never changes the user's preferred display identity.
enum DisplayPlacementPolicy {
    static func select(displays: [DisplayDescriptor], preferredID: String?, legacyID: UInt32,
                       currentFrame: CGRect?) -> DisplayDescriptor? {
        if let preferredID, let preferred = displays.first(where: { $0.id == preferredID }) { return preferred }
        if preferredID == nil, legacyID != 0, let legacy = displays.first(where: { $0.legacyID == legacyID }) { return legacy }
        if let currentFrame {
            let point = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            return displays.min { a, b in
                let ad = distanceSquared(point, to: a.visibleFrame)
                let bd = distanceSquared(point, to: b.visibleFrame)
                if ad == bd { return a.isMain && !b.isMain }
                return ad < bd
            }
        }
        return displays.first(where: \.isMain) ?? displays.first
    }

    private static func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    static func position(for display: DisplayDescriptor, saved: [String: DisplayPosition],
                         defaultPosition: DisplayPosition) -> DisplayPosition {
        saved[display.id] ?? defaultPosition
    }

    static func mascot(in area: CGRect, position: DisplayPosition, size: CGSize = CGSize(width: 52, height: 52)) -> CGRect {
        let fitted = fittedSize(size, in: area, inset: 0)
        let x = position.edge == "right" ? area.maxX - fitted.width - 4 : area.minX + 4
        let vertical = position.vertical.isFinite ? max(0, min(1, position.vertical)) : 0.5
        let y = area.minY + CGFloat(vertical) * max(0, area.height - fitted.height)
        return clamped(CGRect(origin: CGPoint(x: x, y: y), size: fitted), in: area, inset: 0)
    }

    static func panel(in area: CGRect, mascot: CGRect, requestedSize: CGSize, edge: String) -> CGRect {
        let size = fittedSize(requestedSize, in: area, inset: 4)
        let x = edge == "right" ? mascot.minX - 8 - size.width : mascot.maxX + 8
        return clamped(CGRect(x: x, y: mascot.midY - size.height / 2, width: size.width, height: size.height), in: area, inset: 4)
    }

    static func vertical(for originY: CGFloat, in area: CGRect, height: CGFloat = 52) -> Double {
        Double(max(0, min(1, (originY - area.minY) / max(1, area.height - height))))
    }

    private static func fittedSize(_ size: CGSize, in area: CGRect, inset: CGFloat) -> CGSize {
        CGSize(width: max(0, min(size.width, area.width - inset * 2)),
               height: max(0, min(size.height, area.height - inset * 2)))
    }

    private static func clamped(_ frame: CGRect, in area: CGRect, inset: CGFloat) -> CGRect {
        let dx = min(inset, max(0, (area.width - frame.width) / 2))
        let dy = min(inset, max(0, (area.height - frame.height) / 2))
        return CGRect(x: max(area.minX + dx, min(frame.minX, area.maxX - frame.width - dx)),
                      y: max(area.minY + dy, min(frame.minY, area.maxY - frame.height - dy)),
                      width: frame.width, height: frame.height)
    }
}
