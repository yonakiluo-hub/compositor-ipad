// From Compositor-ZH 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// iPad extension: rotation-aware viewport geometry and anchored gestures.
import Foundation
import CoreGraphics

/// Document: pixels with top-left origin. View: UIKit points. Zoom 1 means actual display pixels.
struct CanvasViewport: Equatable {
    var viewSize: CGSize = .zero
    var backingScale: CGFloat = 1
    private(set) var zoom: CGFloat = 1
    /// Radians; positive angles appear clockwise in UIKit's downward-y coordinates.
    private(set) var rotation: CGFloat = 0
    var pan: CGSize = .zero
    private(set) var followsFit = true
    static let zoomRange: ClosedRange<CGFloat> = 0.001...32
    static let keyboardZoomLevels: [CGFloat] = [0.125, 1.0 / 6.0, 0.25, 1.0 / 3.0,
                                              0.5, 2.0 / 3.0, 1, 1.25, 1.5, 2,
                                              3, 4, 5, 6, 8, 12, 16]
    var pointsPerPixel: CGFloat { zoom / backingScale }
    var center: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    func documentToViewTransform(documentSize: CGSize) -> CGAffineTransform {
        guard validState, validDocumentSize(documentSize) else { return .identity }
        return CGAffineTransform(translationX: center.x + pan.width, y: center.y + pan.height)
            .rotated(by: rotation)
            .scaledBy(x: pointsPerPixel, y: pointsPerPixel)
            .translatedBy(x: -documentSize.width / 2, y: -documentSize.height / 2)
    }

    /// Axis-aligned bounds only. Draw and clip the rotated canvas with the transform.
    func documentRect(_ size: CGSize) -> CGRect {
        guard validState, validDocumentSize(size) else { return .zero }
        return CGRect(origin: .zero, size: size).applying(documentToViewTransform(documentSize: size))
    }

    func documentPoint(from point: CGPoint, documentSize: CGSize) -> CGPoint {
        point.applying(documentToViewTransform(documentSize: documentSize).inverted())
    }

    func viewPoint(from point: CGPoint, documentSize: CGSize) -> CGPoint {
        point.applying(documentToViewTransform(documentSize: documentSize))
    }

    mutating func fit(documentSize: CGSize) {
        guard validState, validDocumentSize(documentSize) else { return }
        guard viewSize.width > 0, viewSize.height > 0 else { followsFit = true; return }
        // Keep the viewing angle when the available view changes. The explicit
        // fit-and-straighten action can call resetRotation() before fitting.
        let c = abs(cos(rotation)), s = abs(sin(rotation))
        let rotated = CGSize(width: documentSize.width * c + documentSize.height * s,
                             height: documentSize.width * s + documentSize.height * c)
        guard validDocumentSize(rotated) else { return }
        let fitted = min(max(1, viewSize.width - 96) / rotated.width,
                         max(1, viewSize.height - 96) / rotated.height) * backingScale
        guard fitted.isFinite else { return }
        zoom = clamp(fitted)
        pan = .zero
        followsFit = true
    }

    mutating func resize(to size: CGSize, backingScale newScale: CGFloat, documentSize: CGSize?) {
        guard validState, size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0,
              newScale.isFinite, newScale > 0,
              documentSize.map(validDocumentSize) ?? true else { return }
        // Preserve the center document point when moving between displays.
        let oldScale = pointsPerPixel
        var resized = self
        resized.viewSize = size
        resized.backingScale = max(1, newScale)
        if followsFit, let documentSize {
            resized.fit(documentSize: documentSize)
        } else {
            let ratio = resized.pointsPerPixel / oldScale
            resized.pan = CGSize(width: pan.width * ratio, height: pan.height * ratio)
        }
        guard resized.validState else { return }
        self = resized
    }

    mutating func setZoom(_ value: CGFloat, anchoredAt anchor: CGPoint, documentSize: CGSize) {
        guard value.isFinite else { return }
        update(zoom: clamp(value), rotation: rotation, anchoredAt: anchor, documentSize: documentSize)
    }

    mutating func setRotation(_ value: CGFloat, anchoredAt anchor: CGPoint, documentSize: CGSize) {
        guard value.isFinite else { return }
        var normalized = value.truncatingRemainder(dividingBy: 2 * .pi)
        if normalized > .pi { normalized -= 2 * .pi }
        if normalized < -.pi { normalized += 2 * .pi }
        update(zoom: zoom, rotation: normalized == 0 ? 0 : normalized, anchoredAt: anchor, documentSize: documentSize)
    }

    mutating func resetRotation(anchoredAt anchor: CGPoint? = nil, documentSize: CGSize) {
        setRotation(0, anchoredAt: anchor ?? center, documentSize: documentSize)
    }

    private mutating func update(zoom newZoom: CGFloat, rotation newRotation: CGFloat,
                                 anchoredAt anchor: CGPoint, documentSize: CGSize) {
        guard validState, validDocumentSize(documentSize), anchor.x.isFinite, anchor.y.isFinite else { return }
        let pixel = documentPoint(from: anchor, documentSize: documentSize)
        guard pixel.x.isFinite, pixel.y.isFinite else { return }
        var updated = self
        updated.zoom = newZoom; updated.rotation = newRotation
        let moved = updated.viewPoint(from: pixel, documentSize: documentSize)
        updated.pan.width += anchor.x - moved.x
        updated.pan.height += anchor.y - moved.y
        updated.followsFit = false
        guard updated.validState else { return }
        self = updated
    }

    func keyboardZoomTarget(by step: Int) -> CGFloat {
        guard step != 0 else { return zoom }
        let tolerance = max(0.000000001, abs(zoom) * 0.000000001)
        if step > 0 {
            return Self.keyboardZoomLevels.first { $0 > zoom + tolerance } ?? zoom
        }
        return Self.keyboardZoomLevels.last { $0 < zoom - tolerance } ?? zoom
    }

    mutating func translate(by delta: CGSize) {
        guard validState, delta.width.isFinite, delta.height.isFinite else { return }
        let translated = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
        guard translated.width.isFinite, translated.height.isFinite else { return }
        pan = translated
        followsFit = false
    }

    private var validState: Bool {
        let determinant = pointsPerPixel * pointsPerPixel
        return viewSize.width.isFinite && viewSize.height.isFinite && viewSize.width >= 0 && viewSize.height >= 0 &&
        backingScale.isFinite && backingScale > 0 && pointsPerPixel.isFinite && pointsPerPixel > 0 &&
        determinant.isFinite && determinant > 0 &&
        pan.width.isFinite && pan.height.isFinite && rotation.isFinite &&
        (center.x + pan.width).isFinite && (center.y + pan.height).isFinite
    }

    private func validDocumentSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
    }
}
