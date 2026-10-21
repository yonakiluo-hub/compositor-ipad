import Foundation
import CoreGraphics

// Document-coordinate draft and quarter-pixel sampling adapted from Compositor-ZH
// Compositor/Document/Selection.swift at 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477.
// Copyright (c) 2026 Wonder Assembly LLC. MIT license: licenses/Compositor-MIT.txt.
// Touch-up vertices, frozen options and command handling are iPad adaptations.

struct SelectionGestureCommand: Equatable {
    enum Action { case finish, undoPoint, cancel }
    let id = UUID()
    let action: Action
    init(_ action: Action) { self.action = action }
}

struct SelectionGestureDraft {
    enum Kind { case freehand, polygonal, rectangle, ellipse }
    let kind: Kind
    let documentID: UUID
    let revision: Int64
    let mode: SelectionCombineMode
    let feather: Double
    private(set) var points: [CGPoint]
    private(set) var cursor: CGPoint?
    private(set) var exceedsPointLimit = false
    private let pointLimit = 20_000

    init(kind: Kind, at point: CGPoint, documentID: UUID, revision: Int64,
         mode: SelectionCombineMode, feather: Double) {
        self.kind = kind; self.documentID = documentID; self.revision = revision
        self.mode = mode; self.feather = feather
        points = kind == .polygonal ? [] : [point]
        cursor = point
    }

    func matches(documentID: UUID, revision: Int64, kind: Kind?) -> Bool {
        self.documentID == documentID && self.revision == revision && self.kind == kind
    }

    mutating func move(to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        cursor = point
        if kind == .freehand { append(point) }
    }

    /// Polygon vertices become final only on touch-up, so a pan/pinch recognizer
    /// can cancel the active touch without accidentally adding another corner.
    mutating func end(at point: CGPoint, closingDistance: CGFloat) -> SelectionShape? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        move(to: point)
        if kind == .polygonal {
            if let first = points.first, points.count >= 3,
               hypot(point.x - first.x, point.y - first.y) <= max(0, closingDistance), let shape = finishedShape() {
                return shape
            }
            append(point); cursor = nil
            return nil
        }
        return finishedShape()
    }

    mutating func cancelPointer() { cursor = nil }
    mutating func undoPoint() {
        guard kind == .polygonal, !points.isEmpty else { return }
        points.removeLast(); cursor = nil
    }

    var rectangle: CGRect? {
        guard let first = points.first, let cursor else { return nil }
        return CGRect(x: min(first.x, cursor.x), y: min(first.y, cursor.y),
                      width: abs(cursor.x - first.x), height: abs(cursor.y - first.y))
    }

    func finishedShape() -> SelectionShape? {
        guard !exceedsPointLimit else { return nil }
        switch kind {
        case .rectangle, .ellipse:
            guard let rectangle, rectangle.width > 0, rectangle.height > 0 else { return nil }
            return kind == .ellipse ? .ellipse(rectangle) : .rectangle(rectangle)
        case .freehand, .polygonal:
            // Do not use signed polygon area: a valid even-odd bow-tie can have
            // zero signed area. Reject only fewer than three/non-collinear points.
            guard points.count >= 3, let first = points.first,
                  let second = points.dropFirst().first(where: { $0 != first }),
                  points.dropFirst(2).contains(where: {
                      abs((second.x - first.x) * ($0.y - first.y) - (second.y - first.y) * ($0.x - first.x)) > 0.000_001
                  }) else { return nil }
            return .polygon(points)
        }
    }

    private mutating func append(_ point: CGPoint) {
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 0.25 { return }
        // A bounded draft must never commit just the prefix of a long outline.
        guard points.count < pointLimit else { exceedsPointLimit = true; return }
        points.append(point)
    }
}
