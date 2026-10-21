import XCTest
import CoreGraphics
@testable import CompositorKit

final class LayerOrganizationTests: XCTestCase {
    private func layer(_ name: String, parent: UUID? = nil, group: Bool = false) -> RasterLayer {
        RasterLayer(name: name, transform: LayerTransform(size: CGSize(width: 8, height: 6)), parentID: parent, isGroup: group)
    }
    private func document(_ layers: [RasterLayer]) -> CanvasDocument {
        CanvasDocument(width: 8, height: 6, layers: layers, activeLayerID: layers.last?.id)
    }
    private func siblings(_ editor: DocumentEditor, _ parent: UUID? = nil) -> [UUID] {
        editor.document.layers.filter { $0.parentID == parent }.map(\.id)
    }
    private func painted(_ name: String, red: CGFloat, blue: CGFloat, parent: UUID? = nil) throws -> RasterLayer {
        let context = try RasterImage.context(width: 8, height: 6)
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        var result = layer(name, parent: parent)
        result.pngData = try RasterImage.png(XCTUnwrap(context.makeImage()))
        result.maskPNGData = try RasterImage.png(RasterImage.solidMask(width: 8, height: 6, white: true))
        return result
    }
    private func assertFailure(_ editor: DocumentEditor, _ operation: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        let before = editor.document, undo = editor.undoCount, redo = editor.canRedo
        XCTAssertThrowsError(try operation(), file: file, line: line)
        XCTAssertEqual(editor.document, before, file: file, line: line)
        XCTAssertEqual(editor.undoCount, undo, file: file, line: line)
        XCTAssertEqual(editor.canRedo, redo, file: file, line: line)
    }

    func testBatchAcrossParentsUsesVisualOrderAndPreservesSubtreeAndRawAssets() throws {
        let firstGroup = layer("组一", group: true), secondGroup = layer("组二", group: true)
        let nested = layer("嵌套", parent: firstGroup.id, group: true)
        var red = try painted("红", red: 1, blue: 0, parent: nested.id)
        red.transform.rotation = 27; red.transform.flipX = true; red.maskEnabled = false
        let blue = try painted("蓝", red: 0, blue: 1, parent: secondGroup.id)
        // Raw storage order is deliberately the reverse of visual branch order.
        let editor = try DocumentEditor(document: document([firstGroup, secondGroup, blue, nested, red]))
        let before = editor.document
        try editor.moveLayers([blue.id, nested.id, red.id], into: nil, position: .bottom)
        XCTAssertEqual(siblings(editor), [nested.id, blue.id, firstGroup.id, secondGroup.id])
        XCTAssertEqual(siblings(editor, nested.id), [red.id])
        XCTAssertEqual(editor.document.layers.first { $0.id == red.id }, red)
        XCTAssertEqual(editor.document.layers.first { $0.id == blue.id }?.pngData, blue.pngData)
        XCTAssertEqual(editor.document.id, before.id); XCTAssertEqual(editor.undoCount, 1)
        let moved = editor.document
        try editor.undo(); XCTAssertEqual(editor.document.layers, before.layers)
        try editor.redo(); XCTAssertEqual(editor.document.layers, moved.layers)
    }

    func testEveryInsertionPositionUsesSiblingRatherThanRawDescendantSlot() throws {
        let target = layer("目标组", group: true), a = layer("下", parent: target.id)
        let nested = layer("中组", parent: target.id, group: true), b = layer("上", parent: target.id)
        let late = layer("晚添加后代", parent: nested.id), moving = layer("移动")
        let original = document([target, moving, a, nested, b, late])
        let cases: [(LayerInsertionPosition, [UUID])] = [
            (.bottom, [moving.id, a.id, nested.id, b.id]),
            (.top, [a.id, nested.id, b.id, moving.id]),
            (.above(nested.id), [a.id, nested.id, moving.id, b.id]),
            (.below(nested.id), [a.id, moving.id, nested.id, b.id])
        ]
        for (position, expected) in cases {
            let editor = try DocumentEditor(document: original)
            try editor.moveLayers([moving.id], into: target.id, position: position)
            XCTAssertEqual(siblings(editor, target.id), expected)
            XCTAssertEqual(editor.document.layers.first { $0.id == late.id }, late)
        }
    }

    func testGroupingConsecutiveRootsKeepsPixelsOrderAndOneUndo() throws {
        let low = try painted("下", red: 1, blue: 0), a = try painted("一", red: 0, blue: 1)
        let nested = layer("内组", group: true), child = try painted("子", red: 1, blue: 0, parent: nested.id)
        let high = try painted("上", red: 0, blue: 1)
        let editor = try DocumentEditor(document: document([low, a, nested, high, child]))
        let original = editor.document, renderer = DocumentRenderer(), pixels = try RasterImage.png(renderer.render(original))
        let id = try editor.groupLayers([a.id, nested.id, child.id])
        XCTAssertEqual(siblings(editor), [low.id, id, high.id])
        XCTAssertEqual(siblings(editor, id), [a.id, nested.id])
        XCTAssertEqual(siblings(editor, nested.id), [child.id])
        XCTAssertEqual(editor.document.activeLayerID, id)
        XCTAssertEqual(try RasterImage.png(renderer.render(editor.document)), pixels)
        XCTAssertEqual(editor.undoCount, 1)
        try editor.undo(); XCTAssertEqual(editor.document.layers, original.layers)
        XCTAssertEqual(editor.document.activeLayerID, original.activeLayerID)
        try editor.redo(); XCTAssertEqual(siblings(editor), [low.id, id, high.id])
    }

    func testGroupingAcrossParentsAndGapsRejectsWithoutLosingRedo() throws {
        let g = layer("组", group: true), child = layer("子", parent: g.id)
        let a = layer("下"), gap = layer("间隔"), b = layer("上")
        let editor = try DocumentEditor(document: document([a, gap, b, g, child]))
        try editor.setOpacity(layerID: a.id, opacity: 0.5); try editor.undo()
        assertFailure(editor) { _ = try editor.groupLayers([a.id, b.id]) }
        assertFailure(editor) { _ = try editor.groupLayers([b.id, child.id]) }
        XCTAssertTrue(editor.canRedo)
    }

    func testCompleteClippingStackMovesGroupsAndReopensWithoutRebinding() throws {
        let g = layer("目标", group: true)
        var base = try painted("底", red: 1, blue: 0)
        base.transform.rotation = 12
        var clip = try painted("剪贴一", red: 0, blue: 1); clip.maskSourceID = base.id
        var top = layer("剪贴二"); top.maskSourceID = base.id; top.isVisible = false
        let editor = try DocumentEditor(document: document([base, clip, top, g]))
        let original = editor.document
        try editor.moveLayers([base.id, clip.id, top.id], into: g.id)
        XCTAssertEqual(siblings(editor, g.id), [base.id, clip.id, top.id])
        let wrapper = try editor.groupLayers([base.id, clip.id, top.id])
        XCTAssertEqual(siblings(editor, g.id), [wrapper])
        XCTAssertEqual(siblings(editor, wrapper), [base.id, clip.id, top.id])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentStore.save(editor.document, to: url)
        let loaded = try DocumentStore.load(from: url)
        XCTAssertEqual(loaded, editor.document)
        for source in original.layers {
            var actual = try XCTUnwrap(loaded.layers.first { $0.id == source.id })
            actual.parentID = source.parentID
            XCTAssertEqual(actual, source)
        }
        try editor.undo(); try editor.undo(); XCTAssertEqual(editor.document.layers, original.layers)
        try editor.redo(); try editor.redo(); XCTAssertEqual(editor.document.layers, loaded.layers)
    }

    func testIncompleteDependencyAndInsertionInsideOtherStackRejectAtomically() throws {
        let g = layer("组", group: true), base = layer("底")
        var clip = layer("剪贴"); clip.maskSourceID = base.id
        let moving = layer("移动")
        let editor = try DocumentEditor(document: document([base, clip, g, moving]))
        assertFailure(editor) { try editor.moveLayers([base.id], into: g.id) }
        assertFailure(editor) { try editor.moveLayers([clip.id], into: g.id) }
        assertFailure(editor) { _ = try editor.groupLayers([clip.id]) }
        assertFailure(editor) { try editor.moveLayers([moving.id], into: nil, position: .above(base.id)) }
        assertFailure(editor) { try editor.moveLayers([moving.id], into: nil, position: .below(clip.id)) }
        XCTAssertEqual(editor.document.layers[1].maskSourceID, base.id)
    }

    func testNestedClippingGroupMovesAsUnitWithDescendantDeduplication() throws {
        let g = layer("组", group: true), dest = layer("目标", group: true), base = layer("底", parent: g.id)
        var clip = layer("剪贴", parent: g.id); clip.maskSourceID = base.id
        let editor = try DocumentEditor(document: document([g, dest, base, clip]))
        try editor.moveLayers([g.id, clip.id], into: dest.id)
        XCTAssertEqual(siblings(editor, dest.id), [g.id])
        XCTAssertEqual(siblings(editor, g.id), [base.id, clip.id])
        XCTAssertEqual(editor.document.layers.first { $0.id == clip.id }, clip)
    }

    func testLockedDescendantSourceAncestorAndTargetAncestorReject() throws {
        let g = layer("组", group: true), target = layer("目标", group: true)
        var child = layer("子", parent: g.id); child.isLocked = true
        let editor = try DocumentEditor(document: document([g, target, child]))
        assertFailure(editor) { try editor.moveLayers([g.id], into: target.id) }
        assertFailure(editor) { _ = try editor.groupLayers([g.id]) }
        try editor.setLocked(layerID: child.id, isLocked: false)
        try editor.setLocked(layerID: g.id, isLocked: true)
        assertFailure(editor) { try editor.moveLayers([child.id], into: target.id) }
        let moving = layer("外部")
        _ = try editor.addLayer(moving)
        assertFailure(editor) { try editor.moveLayers([moving.id], into: g.id) }
        // Locked sibling anchors are allowed; their records remain untouched.
        try editor.moveLayers([moving.id], into: nil, position: .below(g.id))
        XCTAssertEqual(siblings(editor), [moving.id, g.id, target.id])
    }

    func testHiddenItemsCanMoveAndNewAncestorVisibilityAndOpacityTakeEffect() throws {
        var source = layer("源组", group: true); source.opacity = 0.5
        var dest = layer("隐藏目标", group: true); dest.isVisible = false; dest.opacity = 0.25
        let red = try painted("红", red: 1, blue: 0, parent: source.id)
        var hidden = layer("隐藏层", parent: source.id); hidden.isVisible = false
        let editor = try DocumentEditor(document: document([source, dest, red, hidden]))
        try editor.moveLayers([red.id, hidden.id], into: dest.id)
        XCTAssertTrue(editor.document.renderLayers.isEmpty)
        XCTAssertFalse(try XCTUnwrap(editor.document.layers.first { $0.id == hidden.id }).isVisible)
        try editor.setVisibility(layerID: dest.id, isVisible: true)
        XCTAssertEqual(editor.document.renderLayers.first?.effectiveOpacity, 0.25)
        XCTAssertEqual(editor.document.layers.first { $0.id == red.id }?.opacity, 1)
        XCTAssertEqual(editor.document.layers.first { $0.id == red.id }?.pngData, red.pngData)
    }

    func testMoveOutPlacesBatchAboveParentAndKeepsEmptyGroup() throws {
        let outer = layer("外", group: true), g = layer("内", parent: outer.id, group: true)
        let above = layer("更上方", parent: outer.id), a = layer("一", parent: g.id), b = layer("二", parent: g.id)
        let editor = try DocumentEditor(document: document([outer, g, above, a, b]))
        try editor.moveLayersOutOfGroup([b.id, a.id])
        XCTAssertEqual(siblings(editor, outer.id), [g.id, a.id, b.id, above.id])
        XCTAssertTrue(siblings(editor, g.id).isEmpty)
        XCTAssertEqual(editor.undoCount, 1)
        assertFailure(editor) { try editor.moveLayersOutOfGroup([outer.id]) }
        assertFailure(editor) { try editor.moveLayersOutOfGroup([outer.id, a.id]) }
    }

    func testCyclesMissingParentsAndInvalidAnchorsLeaveHistoryIntact() throws {
        let g = layer("组", group: true), sub = layer("后代", parent: g.id, group: true), a = layer("普通")
        let editor = try DocumentEditor(document: document([g, a, sub]))
        assertFailure(editor) { try editor.moveLayers([g.id], into: g.id) }
        assertFailure(editor) { try editor.moveLayers([g.id, sub.id], into: sub.id) }
        assertFailure(editor) { try editor.moveLayers([a.id], into: a.id) }
        assertFailure(editor) { try editor.moveLayers([a.id], into: UUID()) }
        assertFailure(editor) { try editor.moveLayers([a.id], into: nil, position: .above(sub.id)) }
        assertFailure(editor) { try editor.moveLayers([g.id], into: nil, position: .below(sub.id)) }
        assertFailure(editor) { try editor.moveLayers([a.id], into: nil, position: .above(a.id)) }
        assertFailure(editor) { try editor.moveLayers([UUID()], into: nil) }
        assertFailure(editor) { try editor.moveLayers([], into: nil) }
    }

    func testNoOpInterleavedStorageAndNavigationPreserveRevisionAndRedo() throws {
        let g = layer("组", group: true), child = layer("子", parent: g.id), upper = layer("上方")
        let editor = try DocumentEditor(document: document([g, upper, child]))
        try editor.setOpacity(layerID: upper.id, opacity: 0.5); try editor.undo()
        let before = editor.document
        try editor.moveLayers([g.id, child.id], into: nil, position: .below(upper.id))
        XCTAssertEqual(editor.document, before); XCTAssertTrue(editor.canRedo)
        let plan = try LayerOrganization.movePlan(document: editor.document, selectedIDs: [g.id], into: nil, position: .top)
        try editor.selectLayer(child.id)
        try editor.organizeLayers(plan)
        XCTAssertEqual(editor.document.activeLayerID, child.id)
        XCTAssertEqual(siblings(editor), [upper.id, g.id])
    }

    func testStalePlansRejectedAfterEditUndoOrDifferentDocument() throws {
        let a = layer("一"), b = layer("二"), original = document([layer("组", group: true)])
        let editor = try DocumentEditor(document: document([a, b]))
        let plan = try LayerOrganization.movePlan(document: editor.document, selectedIDs: [a.id], into: nil)
        try editor.setOpacity(layerID: b.id, opacity: 0.5); try editor.undo()
        assertFailure(editor) { try editor.organizeLayers(plan) }
        let other = try DocumentEditor(document: original)
        assertFailure(other) { try other.organizeLayers(plan) }
        let fresh = try LayerOrganization.movePlan(document: editor.document, selectedIDs: [a.id], into: nil)
        var altered = editor.document; altered.layers[0].isVisible = false
        XCTAssertThrowsError(try LayerOrganization.apply(fresh, to: &altered))
    }

    func testReorderingChangesOcclusionAndUndoRestoresRenderedPixels() throws {
        let red = try painted("红", red: 1, blue: 0), blue = try painted("蓝", red: 0, blue: 1)
        let g = layer("组", group: true)
        var r = red, b = blue; r.parentID = g.id; b.parentID = g.id
        let editor = try DocumentEditor(document: document([g, r, b])), renderer = DocumentRenderer()
        let before = try RasterImage.png(renderer.render(editor.document))
        try editor.moveLayers([b.id], into: g.id, position: .below(r.id))
        XCTAssertNotEqual(try RasterImage.png(renderer.render(editor.document)), before)
        try editor.undo(); XCTAssertEqual(try RasterImage.png(renderer.render(editor.document)), before)
    }

    func testTooDeepPlacementAndInvalidGroupNameRollBack() throws {
        var chain: [RasterLayer] = []
        for index in 0..<64 { chain.append(layer("组\(index)", parent: chain.last?.id, group: true)) }
        let a = layer("子", parent: chain.last!.id), outside = layer("外部", group: true)
        let editor = try DocumentEditor(document: document(chain + [a, outside]))
        assertFailure(editor) { _ = try editor.groupLayers([a.id]) }
        assertFailure(editor) { try editor.moveLayers([outside.id], into: chain.last!.id) }
        assertFailure(editor) { _ = try editor.groupLayers([outside.id], name: " ") }
    }
}
