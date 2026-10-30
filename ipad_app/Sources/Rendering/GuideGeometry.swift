import Foundation
import CoreGraphics

enum GuideGeometry {
    static func segment(_ guide: CanvasGuide, viewport: CanvasViewport, documentSize: CGSize) -> (CGPoint, CGPoint) {
        let a = guide.axis == .vertical ? CGPoint(x: guide.position, y: 0) : CGPoint(x: 0, y: guide.position)
        let b = guide.axis == .vertical ? CGPoint(x: guide.position, y: documentSize.height) : CGPoint(x: documentSize.width, y: guide.position)
        return (viewport.viewPoint(from: a, documentSize: documentSize), viewport.viewPoint(from: b, documentSize: documentSize))
    }
    static func distance(from point: CGPoint, to guide: CanvasGuide, viewport: CanvasViewport, documentSize: CGSize) -> CGFloat {
        let (a, b) = segment(guide, viewport: viewport, documentSize: documentSize)
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0, length.isFinite else { return .infinity }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
    }
}
