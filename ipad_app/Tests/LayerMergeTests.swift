import XCTest
import CoreGraphics
@testable import CompositorKit

final class LayerMergeTests: XCTestCase {
    private func image(width: Int = 8, height: Int = 6, seed: Int = 0) throws -> Data {
        let context = try RasterImage.context(width: width, height: height)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * context.bytesPerRow + x * 4
                let a = 64 + (x * 19 + y * 37 + seed * 11) % 192
                bytes[i] = UInt8((x * 23 + seed * 29) % (a + 1))
                bytes[i + 1] = UInt8((y * 43 + seed * 17) % (a + 1))
                bytes[i + 2] = UInt8((x * 7 + y * 11 + seed * 41) % (a + 1))
                bytes[i + 3] = UInt8(a)
            }
        }
        return try RasterImage.png(XCTUnwrap(context.makeImage()))
    }

    private func mask(width: Int = 4, height: Int = 3, black: Bool = false) throws -> Data {
        let context = try RasterImage.context(width: width, height: height, gray: true)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width { bytes[y * context.bytesPerRow + x] = black ? 0 : UInt8((x * 71 + y * 47) % 256) }
        }
        return try RasterImage.png(XCTUnwrap(context.makeImage()))
    }

    private func layer(_ name: String, seed: Int = 0, parent: UUID? = nil,
                       origin: CGPoint = CGPoint(x: 8, y: 9), opacity: Double = 1) throws -> RasterLayer {
        RasterLayer(name: name, pngData: try image(seed: seed),
                    transform: LayerTransform(origin: origin, size: CGSize(width: 8, height: 6)),
                    opacity: opacity, parentID: parent)
    }

    private func group(_ name: String, parent: UUID? = nil, opacity: Double = 1) -> RasterLayer {
        RasterLayer(name: name, transform: LayerTransform(size: CGSize(width: 32, height: 32)),
                    opacity: opacity, parentID: parent, isGroup: true)
    }

    private func document(_ layers: [RasterLayer]) -> CanvasDocument {
        CanvasDocument(width: 32, height: 32, layers: layers, activeLayerID: layers.last?.id)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try RasterImage.context(width: image.width, height: image.height)
        context.setBlendMode(.copy)
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: context.bytesPerRow * image.height))
    }

    private func assertAppearance(_ a: CanvasDocument, _ b: CanvasDocument, tolerance: Int = 2,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let renderer = DocumentRenderer()
        let first = try pixels(renderer.render(a)), second = try pixels(renderer.render(b))
        XCTAssertEqual(first.count, second.count, file: file, line: line)
        let difference = zip(first, second).map { abs(Int($0) - Int($1)) }.max() ?? 0
        // Factoring source-over into a separately encoded 8-bit layer introduces
        // one additional quantization; this is not a backdrop or alpha change.
        XCTAssertLessThanOrEqual(difference, tolerance, "Maximum premultiplied RGBA difference: \(difference)/255",
                                 file: file, line: line)
    }

    private func merge(_ source: CanvasDocument, ids: Set<UUID>) throws -> CanvasDocument {
        let plan = try LayerMerge.plan(document: source, selectedIDs: ids)
        let merged = try LayerMerge.render(plan: plan, document: source, renderer: DocumentRenderer())
        var result = source
        try LayerMerge.apply(plan: plan, mergedLayer: merged, to: &result)
        try result.validate()
        return result
    }

    private func assertError(_ expected: LayerMergeError, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? LayerMergeError, expected, file: file, line: line)
        }
    }

    func testAdjacentLayersBakeMasksAndOpacityOnceWithoutChangingUnselectedLayers() throws {
        let background = try layer("背景", seed: 6)
        var first = try layer("第一层", seed: 1, opacity: 0.67)
        first.maskPNGData = try mask()
        var second = try layer("第二层", seed: 2, origin: CGPoint(x: 9, y: 10), opacity: 0.43)
        second.maskPNGData = try mask(black: true)
        second.maskEnabled = false
        let above = try layer("未选的上层", seed: 8, opacity: 0.37)
        var original = document([background, first, second, above])
        original.selectionMaskPNGData = try mask(width: 32, height: 32, black: true)
        let result = try merge(original, ids: [first.id, second.id])
        XCTAssertEqual(result.layers.count, 3)
        XCTAssertEqual(result.layers.first, background)
        XCTAssertEqual(result.layers.last, above)
        XCTAssertNil(result.layers[1].maskPNGData)
        XCTAssertEqual(result.layers[1].opacity, 1)
        XCTAssertEqual(result.layers[1].blendMode, .normal)
        XCTAssertEqual(result.selectionMaskPNGData, original.selectionMaskPNGData)
        try assertAppearance(original, result)
    }

    func testGroupMergeTraversesHierarchyInsteadOfRawArrayAndBakesInternalOpacity() throws {
        let below = try layer("组下方", seed: 4)
        let outer = group("待合并组", opacity: 0.57)
        let above = try layer("组上方", seed: 5)
        let child = try layer("晚加入的子层", seed: 2, parent: outer.id, opacity: 0.73)
        let inner = group("内部组", parent: outer.id, opacity: 0.41)
        let grandchild = try layer("孙图层", seed: 9, parent: inner.id)
        let original = document([below, outer, above, child, inner, grandchild])
        let result = try merge(original, ids: [outer.id, child.id, grandchild.id])
        XCTAssertEqual(result.layers.count, 3)
        XCTAssertEqual(result.layers[0], below)
        XCTAssertEqual(result.layers[2], above)
        XCTAssertEqual(result.layers[1].name, outer.name)
        XCTAssertNil(result.layers[1].parentID)
        try assertAppearance(original, result)
    }

    func testAdjacentSiblingRootsRemainWithinTheirUnchangedParent() throws {
        let outer = group("保留父组")
        let first = try layer("第一层", seed: 1, parent: outer.id)
        let nested = group("第二项组", parent: outer.id, opacity: 0.72)
        let unselected = try layer("同组上层", seed: 7, parent: outer.id)
        let top = try layer("外部上层", seed: 3)
        let child = try layer("晚加入子层", seed: 4, parent: nested.id)
        let original = document([outer, first, nested, top, unselected, child])
        let plan = try LayerMerge.plan(document: original, selectedIDs: [first.id, nested.id, child.id])
        XCTAssertEqual(plan.rootIDs, [first.id, nested.id])
        XCTAssertEqual(plan.removedIDs, [first.id, nested.id, child.id])
        let result = try merge(original, ids: [first.id, nested.id, child.id])
        XCTAssertEqual(result.layers[0], outer)
        XCTAssertEqual(result.layers[1].parentID, outer.id)
        XCTAssertEqual(result.layers[2], top)
        XCTAssertEqual(result.layers[3], unselected)
        try assertAppearance(original, result)
    }

    func testNonAdjacentAndCrossGroupSelectionsGiveActionableErrors() throws {
        let first = try layer("第一层"), middle = try layer("未选中的中间层"), last = try layer("第三层")
        let original = document([first, middle, last])
        assertError(.nonAdjacent) { _ = try LayerMerge.plan(document: original, selectedIDs: [first.id, last.id]) }
        let parent = group("组")
        let child = try layer("子层", parent: parent.id)
        assertError(.differentParents) {
            _ = try LayerMerge.plan(document: document([first, parent, child]), selectedIDs: [first.id, child.id])
        }
        XCTAssertEqual(original.layers, [first, middle, last])
        XCTAssertTrue(LayerMergeError.nonAdjacent.localizedDescription.contains("连续"))
    }

    func testTranslucentExternalParentRejectedButMergingTheParentIsFaithful() throws {
        let parent = group("透明父组", opacity: 0.4)
        let a = try layer("甲", seed: 1, parent: parent.id)
        let b = try layer("乙", seed: 2, parent: parent.id)
        let original = document([parent, a, b])
        assertError(.externalOpacity) { _ = try LayerMerge.plan(document: original, selectedIDs: [a.id, b.id]) }
        let result = try merge(original, ids: [parent.id])
        try assertAppearance(original, result)
    }

    func testHiddenNodesAndLockedDescendantsAreNeverSilentlyRemoved() throws {
        let root = group("组")
        var a = try layer("甲", parent: root.id)
        let b = try layer("乙", parent: root.id)
        a.isVisible = false
        assertError(.hiddenContent) {
            _ = try LayerMerge.groupPlan(document: document([root, a, b]), groupID: root.id)
        }
        a.isVisible = true
        a.isLocked = true
        assertError(.locked) { _ = try LayerMerge.groupPlan(document: document([root, a, b]), groupID: root.id) }
        var lockedRoot = root
        lockedRoot.isLocked = true
        a.isLocked = false
        assertError(.locked) {
            _ = try LayerMerge.plan(document: document([lockedRoot, a, b]), selectedIDs: [a.id, b.id])
        }
    }

    func testHiddenExternalParentRemainsHiddenAndKeepsContentForWhenShown() throws {
        var parent = group("隐藏的外部父组")
        parent.isVisible = false
        let first = try layer("甲", seed: 1, parent: parent.id)
        let second = try layer("乙", seed: 2, parent: parent.id)
        let original = document([parent, first, second])
        let merged = try merge(original, ids: [first.id, second.id])
        XCTAssertEqual(merged.layers[0], parent)
        try assertAppearance(original, merged, tolerance: 0)
        var beforeShown = original, afterShown = merged
        beforeShown.layers[0].isVisible = true
        afterShown.layers[0].isVisible = true
        try assertAppearance(beforeShown, afterShown)
    }

    func testBackdropDependentModesRejectedInsteadOfChangingAppearance() throws {
        let first = try layer("底层")
        for mode in LayerBlendMode.allCases where mode != .normal {
            var second = try layer("混合层")
            second.blendMode = mode
            assertError(.backdropBlend) {
                _ = try LayerMerge.plan(document: document([first, second]), selectedIDs: [first.id, second.id])
            }
        }
    }

    func testFullRotatedFlippedMaskedBoundsSurviveOutsideCanvas() throws {
        var first = try layer("画布左外", seed: 1, origin: CGPoint(x: -12.25, y: -7.5), opacity: 0.67)
        first.transform.size = CGSize(width: 14, height: 9)
        first.transform.rotation = 37
        first.transform.flipX = true
        first.maskPNGData = try mask()
        var second = try layer("画布右外", seed: 4, origin: CGPoint(x: 29.75, y: 25.25))
        second.transform.size = CGSize(width: 12, height: 15)
        second.transform.rotation = -21
        second.transform.flipY = true
        let original = document([first, second])
        let result = try merge(original, ids: [first.id, second.id])
        XCTAssertLessThan(result.layers[0].transform.origin.x, 0)
        XCTAssertLessThan(result.layers[0].transform.origin.y, 0)
        XCTAssertGreaterThan(result.layers[0].transform.origin.x + result.layers[0].transform.size.width, 32)
        XCTAssertGreaterThan(result.layers[0].transform.origin.y + result.layers[0].transform.size.height, 32)
        // Bring the entire untrimmed result into view after merging.
        var movedOriginal = original, movedResult = result
        for i in movedOriginal.layers.indices {
            movedOriginal.layers[i].transform.origin.x += 24
            movedOriginal.layers[i].transform.origin.y += 24
        }
        movedResult.layers[0].transform.origin.x += 24
        movedResult.layers[0].transform.origin.y += 24
        movedOriginal.width = 80; movedOriginal.height = 80
        movedResult.width = 80; movedResult.height = 80
        try assertAppearance(movedOriginal, movedResult)
    }

    func testMergeDownUsesNearestSiblingEvenWhenItsChildrenWereAppendedLater() throws {
        let root = group("父组")
        let lower = group("下方组", parent: root.id)
        let upper = try layer("当前图层", seed: 2, parent: root.id)
        let unrelated = try layer("外部图层", seed: 8)
        let child = try layer("晚到的下方组子层", seed: 4, parent: lower.id)
        let original = document([root, lower, upper, unrelated, child])
        let plan = try LayerMerge.mergeDownPlan(document: original, layerID: upper.id)
        XCTAssertEqual(plan.rootIDs, [lower.id, upper.id])
        XCTAssertEqual(plan.name, lower.name)
        XCTAssertEqual(plan.actionName, "向下合并")
        let merged = try LayerMerge.render(plan: plan, document: original, renderer: DocumentRenderer())
        var result = original
        try LayerMerge.apply(plan: plan, mergedLayer: merged, to: &result)
        XCTAssertEqual(result.layers.map(\.id), [root.id, merged.id, unrelated.id])
        try assertAppearance(original, result)
        assertError(.noLayerBelow) {
            _ = try LayerMerge.mergeDownPlan(document: original, layerID: lower.id)
        }
    }

    func testStampCapturesActualVisibleCanvasAndStartsHiddenWithoutRemovingSources() throws {
        let root = group("透明组", opacity: 0.61)
        var a = try layer("甲", seed: 1, parent: root.id, origin: CGPoint(x: -3, y: 7))
        a.maskPNGData = try mask()
        var b = try layer("乙", seed: 3, parent: root.id)
        b.blendMode = .multiply
        var hidden = try layer("隐藏图层", seed: 7)
        hidden.isVisible = false
        var original = document([root, a, hidden, b])
        original.selectionMaskPNGData = try mask(width: 32, height: 32, black: true)
        let stamp = try LayerMerge.stampVisible(document: original, renderer: DocumentRenderer())
        XCTAssertFalse(stamp.isVisible)
        XCTAssertNil(stamp.parentID)
        XCTAssertNil(stamp.maskPNGData)
        XCTAssertEqual(stamp.transform.origin, .zero)
        XCTAssertEqual(stamp.transform.size, original.size)
        var result = original
        result.layers.append(stamp)
        XCTAssertEqual(Array(result.layers.dropLast()), original.layers)
        try assertAppearance(original, result, tolerance: 0)
        var shown = stamp
        shown.isVisible = true
        try assertAppearance(original, document([shown]), tolerance: 1)
        let png = try XCTUnwrap(stamp.pngData)
        XCTAssertEqual(try PNGAsset.inspect(png, requireRGBA: true), PNGAsset.Size(width: 32, height: 32))
    }

    func testOneTransactionUndoRedoAndPackageReopenPreserveSourcesAndSelection() throws {
        var first = try layer("带蒙版", seed: 1)
        first.maskPNGData = try mask()
        let second = try layer("上层", seed: 2, opacity: 0.6)
        var original = document([first, second])
        original.selectionMaskPNGData = try mask(width: 32, height: 32)
        original.appliedAIResults = [AIResultKey(jobID: "synthetic", resultID: "0")]
        let editor = try DocumentEditor(document: original)
        let plan = try LayerMerge.plan(document: editor.document, selectedIDs: [first.id, second.id])
        let merged = try LayerMerge.render(plan: plan, document: editor.document, renderer: DocumentRenderer())
        try editor.transaction(plan.actionName) { try LayerMerge.apply(plan: plan, mergedLayer: merged, to: &$0) }
        XCTAssertEqual(editor.undoCount, 1)
        XCTAssertEqual(editor.document.layers, [merged])
        try editor.undo()
        XCTAssertEqual(editor.document.layers, original.layers)
        XCTAssertEqual(editor.document.selectionMaskPNGData, original.selectionMaskPNGData)
        try editor.redo()
        XCTAssertEqual(editor.document.layers, [merged])
        XCTAssertEqual(editor.document.appliedAIResults, original.appliedAIResults)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("merged.comp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DocumentStore.save(editor.document, to: url)
        let reopened = try DocumentStore.load(from: url)
        XCTAssertEqual(reopened, editor.document)
        try assertAppearance(original, reopened)
    }

    func testStalePlansRejectRevisionAndSameRevisionLayerChangesBeforeMutation() throws {
        let first = try layer("甲"), second = try layer("乙")
        let original = document([first, second])
        let plan = try LayerMerge.plan(document: original, selectedIDs: [first.id, second.id])
        let rendered = try LayerMerge.render(plan: plan, document: original, renderer: DocumentRenderer())
        var revised = original
        revised.revision += 1
        assertError(.stalePlan) { _ = try LayerMerge.render(plan: plan, document: revised, renderer: DocumentRenderer()) }
        var changed = original
        changed.layers[0].opacity = 0.5
        let before = changed
        assertError(.stalePlan) { try LayerMerge.apply(plan: plan, mergedLayer: rendered, to: &changed) }
        XCTAssertEqual(changed, before)
    }

    func testResourceLimitIsCheckedBeforeRenderingAndPlansRejectMissingOrEmptyInput() throws {
        var first = try layer("甲"), second = try layer("乙")
        first.transform.size = CGSize(width: 4096, height: 4096)
        XCTAssertThrowsError(try LayerMerge.plan(document: document([first, second]), selectedIDs: [first.id, second.id])) {
            guard case RasterError.oversized = $0 else { return XCTFail("Expected allocation guard") }
        }
        let root = group("空组")
        assertError(.noRasterContent) { _ = try LayerMerge.groupPlan(document: document([root]), groupID: root.id) }
        assertError(.nothingSelected) { _ = try LayerMerge.plan(document: document([second]), selectedIDs: []) }
        assertError(.missingLayer) { _ = try LayerMerge.plan(document: document([second]), selectedIDs: [UUID()]) }
        assertError(.singleLayer) { _ = try LayerMerge.plan(document: document([second]), selectedIDs: [second.id]) }
    }
}
