// Adapted from Compositor LayerTransform.swift (TransformDrag) and TransformOverlay.swift.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// Upstream: 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477.
import Foundation
import CoreGraphics

/// Handles refer to the rotated bounds, independently of the image's horizontal or vertical flips.
public enum TransformHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case rotate, translate

    public var unitPoint: CGPoint? {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomRight: CGPoint(x: 1, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        case .rotate, .translate: nil
        }
    }
}

/// One immutable drag in document pixels (top-left origin). Preview from the same starting state
/// on every update; the caller decides whether to commit the final placement as one history entry.
public struct FreeTransformGesture: Sendable {
    public let original: LayerTransform
    public let handle: TransformHandle
    public let start: CGPoint
    public let lockAspect: Bool

    public init(transform: LayerTransform, handle: TransformHandle, start: CGPoint, lockAspect: Bool = false) {
        self.original = transform
        self.handle = handle
        self.start = start
        self.lockAspect = lockAspect
    }

    /// Invalid inputs, a rotation point at the center, or a placement outside LayerTransform's
    /// supported limits return nil. A handle crossing its opposite edge stops at one pixel;
    /// it does not toggle the source image's flips.
    public func updated(to point: CGPoint) -> LayerTransform? {
        guard original.isValid, [start.x, start.y, point.x, point.y].allSatisfy(\.isFinite) else { return nil }
        let dx = point.x - start.x, dy = point.y - start.y
        guard dx.isFinite, dy.isFinite else { return nil }
        var result = original
        switch handle {
        case .translate:
            result.origin.x += dx
            result.origin.y += dy
        case .rotate:
            let center = original.center
            let from = CGPoint(x: start.x - center.x, y: start.y - center.y)
            let to = CGPoint(x: point.x - center.x, y: point.y - center.y)
            guard [from.x, from.y, to.x, to.y].allSatisfy(\.isFinite),
                  from != .zero, to != .zero else { return nil }
            // Keep exact no-op values, including an existing angle outside the normalized range.
            guard dx != 0 || dy != 0 else { return original }
            let delta = (atan2(to.y, to.x) - atan2(from.y, from.x)) * 180 / .pi
            guard delta != 0 else { return original }
            // Reduce the original first, so even a large finite imported angle cannot overflow.
            result.rotation = Self.normalizedAngle(original.rotation.truncatingRemainder(dividingBy: 360) + delta)
        default:
            guard dx != 0 || dy != 0 else { return original }
            guard let unit = handle.unitPoint else { return nil }
            let cosine = cos(original.radians), sine = sin(original.radians)
            let localX = dx * cosine + dy * sine
            let localY = -dx * sine + dy * cosine
            guard localX.isFinite, localY.isFinite else { return nil }
            let sx = unit.x * 2 - 1, sy = unit.y * 2 - 1
            // Pointer delta, rather than pointer location, avoids a jump when grabbing near a handle.
            let rawWidth = sx == 0 ? original.size.width : original.size.width + localX * sx
            let rawHeight = sy == 0 ? original.size.height : original.size.height + localY * sy
            guard rawWidth.isFinite, rawHeight.isFinite else { return nil }
            var width = max(1, rawWidth), height = max(1, rawHeight)
            if lockAspect {
                let factor: CGFloat
                if sx == 0 { factor = rawHeight / original.size.height }
                else if sy == 0 { factor = rawWidth / original.size.width }
                else {
                    // The closest proportional size is the pointer's projection onto the original diagonal.
                    factor = (rawWidth * original.size.width + rawHeight * original.size.height)
                        / (original.size.width * original.size.width + original.size.height * original.size.height)
                }
                guard factor.isFinite else { return nil }
                let scale = max(1 / min(original.size.width, original.size.height), factor)
                width = max(1, original.size.width * scale)
                height = max(1, original.size.height * scale)
            }
            guard width.isFinite, height.isFinite else { return nil }
            guard width != original.size.width || height != original.size.height else { return original }
            result.size = CGSize(width: width, height: height)
            // Fix the opposite corner (or opposite edge midpoint) while resizing in the layer's axes.
            // Expressing this as a center delta also avoids subtracting large document-space positions.
            let dw = width - original.size.width, dh = height - original.size.height
            let offsetX = (unit.x - 0.5) * dw, offsetY = (unit.y - 0.5) * dh
            result.origin.x += offsetX * cosine - offsetY * sine - dw / 2
            result.origin.y += offsetX * sine + offsetY * cosine - dh / 2
        }
        return result.isValid ? result : nil
    }

    /// Clockwise degrees in [-180, 180), matching LayerTransform's top-left coordinate system.
    private static func normalizedAngle(_ value: CGFloat) -> CGFloat {
        var angle = value.truncatingRemainder(dividingBy: 360)
        if angle >= 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        return angle
    }
}
