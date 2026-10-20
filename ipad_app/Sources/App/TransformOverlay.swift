// Adapted from Compositor TransformOverlay.swift at 7c2a5a4.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// iPad: fixed-size touch handles also follow the rotated canvas viewport.
import UIKit

struct TransformOverlayGeometry {
    let handles: [(TransformHandle, CGPoint)]
    let rotationHandle: CGPoint
    let top: CGPoint

    init(transform: LayerTransform, viewport: CanvasViewport, documentSize: CGSize) {
        handles = TransformHandle.allCases.compactMap { handle in
            handle.unitPoint.map { (handle, viewport.viewPoint(from: transform.point($0), documentSize: documentSize)) }
        }
        top = viewport.viewPoint(from: transform.point(CGPoint(x: 0.5, y: 0)), documentSize: documentSize)
        let angle = transform.radians + viewport.rotation
        rotationHandle = CGPoint(x: top.x + sin(angle) * 36, y: top.y - cos(angle) * 36)
    }

    func hit(_ point: CGPoint, documentPoint: CGPoint, transform: LayerTransform) -> TransformHandle? {
        let targets = handles + [(.rotate, rotationHandle)]
        if let closest = targets.min(by: { distance(point, $0.1) < distance(point, $1.1) }),
           distance(point, closest.1) <= 24 { return closest.0 }
        return transform.contains(documentPoint) ? .translate : nil
    }

    func draw(in context: CGContext) {
        guard let first = handles.first else { return }
        context.saveGState()
        context.setStrokeColor(UIColor.systemTeal.cgColor)
        context.setLineWidth(1.5)
        context.addLines(between: handles.map(\.1) + [first.1]); context.strokePath()
        context.move(to: top); context.addLine(to: rotationHandle); context.strokePath()
        context.setFillColor(UIColor.systemBackground.cgColor)
        for (_, point) in handles {
            let rect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            context.fill(rect); context.stroke(rect)
        }
        let knob = CGRect(x: rotationHandle.x - 9, y: rotationHandle.y - 9, width: 18, height: 18)
        context.fillEllipse(in: knob); context.strokeEllipse(in: knob)
        context.restoreGState()
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
