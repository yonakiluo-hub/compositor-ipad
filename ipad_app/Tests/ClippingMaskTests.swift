import XCTest
import CoreGraphics
@testable import CompositorKit

final class ClippingMaskTests: XCTestCase {
    private func raster(_ color: (UInt8, UInt8, UInt8), alpha: UInt8 = 255) throws -> Data {
        let context = try RasterImage.context(width: 8, height: 6)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<6 { for x in 0..<8 {
            let offset = y * context.bytesPerRow + x * 4
            for (index, channel) in [color.0, color.1, color.2].enumerated() {
                bytes[offset + index] = UInt8((Int(channel) * Int(alpha) + 127) / 255)
            }
            bytes[offset + 3] = alpha
        } }
        return try RasterImage.png(XCTUnwrap(context.makeImage()))
    }
    private func mask() throws -> Data {
        let context = try RasterImage.context(width: 4, height: 3, gray: true)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<3 { for x in 0..<4 { bytes[y * context.bytesPerRow + x] = UInt8((x * 47 + y * 31) % 256) } }
        return try RasterImage.png(XCTUnwrap(context.makeImage()))
    }
    private func layer(_ name: String, color: (UInt8, UInt8, UInt8) = (255, 0, 0), alpha: UInt8 = 255,
                       parent: UUID? = nil, base: UUID? = nil) throws -> RasterLayer {
        RasterLayer(name: name, pngData: try raster(color, alpha: alpha),
                    transform: LayerTransform(origin: CGPoint(x: 4, y: 5), size: CGSize(width: 8, height: 6), sampling: .nearest),
                    parentID: parent, maskSourceID: base)
    }
    private func group() -> RasterLayer {
        RasterLayer(name: "组", transform: LayerTransform(size: CGSize(width: 24, height: 20)), isGroup: true)
    }
    private func document(_ layers: [RasterLayer]) -> CanvasDocument {
        CanvasDocument(width: 24, height: 20, layers: layers, activeLayerID: layers.last?.id)
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try RasterImage.context(width: image.width, height: image.height)
        context.setBlendMode(.copy)
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * image.height))
    }
    private func assertSame(_ first: CGImage, _ second: CGImage, tolerance: Int = 0,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try pixels(first), b = try pixels(second)
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        XCTAssertLessThanOrEqual(zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0, tolerance, file: file, line: line)
    }
    private func package() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("Clipping.comp")
    }

    func testSoftBaseAlphaAndMaskRestoredExactlyOnceForSeveralChildren() throws {
        var base = try layer("底", alpha: 128)
        base.maskPNGData = try mask(); base.opacity = 0.5
        let first = try layer("蓝", color: (0, 0, 255), base: base.id)
        let second = try layer("绿", color: (0, 255, 0), alpha: 128, base: base.id)
        let renderer = DocumentRenderer()
        let a = try pixels(renderer.render(document([base])))
        let b = try pixels(renderer.render(document([base, first, second])))
        for index in stride(from: 3, to: a.count, by: 4) { XCTAssertEqual(a[index], b[index], "Base coverage must not thicken or get squared") }
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Array(b.prefix(4)), [0, 0, 0, 0])
    }
    func testOpaqueClippedColorKeepsBaseHalfAlpha() throws {
        let base = try layer("底", alpha: 128), child = try layer("蓝", color: (0, 0, 255), base: base.id)
        let rgba = try pixels(DocumentRenderer().render(document([base, child])))
        let offset = (6 * 24 + 6) * 4
        XCTAssertEqual(Array(rgba[offset..<offset + 4]), [0, 0, 128, 128])
    }
    func testHiddenBaseHidesStackAndHiddenChildDoesNotSplitIt() throws {
        var base = try layer("底", alpha: 128), middle = try layer("隐藏中间", color: (0, 255, 0), base: base.id)
        let top = try layer("蓝", color: (0, 0, 255), base: base.id)
        middle.isVisible = false
        let renderer = DocumentRenderer()
        try assertSame(renderer.render(document([base, middle, top])), renderer.render(document([base, top])))
        base.isVisible = false
        XCTAssertTrue(document([base, middle, top]).renderLayers.isEmpty)
        XCTAssertTrue(try pixels(renderer.render(document([base, middle, top]))).allSatisfy { $0 == 0 })
    }
    func testMasksTransformsFlipsAndGroupOpacityPreserveCoverage() throws {
        var folder = group(); folder.opacity = 0.5
        var base = try layer("底", alpha: 170, parent: folder.id)
        base.maskPNGData = try mask(); base.transform.rotation = 31; base.transform.flipX = true
        base.transform.size = CGSize(width: 13, height: 9); base.transform.sampling = .high
        var child = try layer("蓝", color: (0, 0, 255), parent: folder.id, base: base.id)
        child.maskPNGData = try mask(); child.transform.rotation = -17; child.transform.origin = CGPoint(x: 2, y: 3)
        let renderer = DocumentRenderer(), a = try pixels(renderer.render(document([folder, base])))
        let b = try pixels(renderer.render(document([folder, base, child])))
        for index in stride(from: 3, to: a.count, by: 4) { XCTAssertEqual(a[index], b[index]) }
        XCTAssertNotEqual(a, b)
        var baseOnly = base; baseOnly.maskEnabled = false
        XCTAssertNotEqual(try pixels(renderer.render(document([folder, baseOnly, child]))), b)
    }
    func testSmallRotatedBaseOnLargeCanvasAndOutsideEdgesKeepsExactCoverage() throws {
        let renderer = DocumentRenderer()
        for origin in [CGPoint(x: 237, y: 221), CGPoint(x: -7, y: -3), CGPoint(x: 505, y: 508)] {
            var base = try layer("小底", alpha: 128)
            base.transform.origin = origin; base.transform.rotation = 37
            base.transform.flipY = true; base.transform.sampling = .high
            base.maskPNGData = try mask()
            var child = try layer("全画布蓝", color: (0, 0, 255), base: base.id)
            child.transform = LayerTransform(size: CGSize(width: 512, height: 512))
            let alone = CanvasDocument(width: 512, height: 512, layers: [base])
            let clipped = CanvasDocument(width: 512, height: 512, layers: [base, child])
            let coverage = try pixels(renderer.render(alone)), result = try pixels(renderer.render(clipped))
            for index in stride(from: 0, to: coverage.count, by: 4) {
                XCTAssertEqual(result[index + 3], coverage[index + 3])
                XCTAssertEqual(result[index], 0)
                XCTAssertEqual(result[index + 2], coverage[index + 3])
            }
        }
    }

    func testParentOpacityMultipliesEachMembersColorLikeUpstream() throws {
        var folder = group(); folder.opacity = 0.5
        let base = try layer("红", parent: folder.id)
        let child = try layer("蓝", color: (0, 0, 255), parent: folder.id, base: base.id)
        let bytes = try pixels(DocumentRenderer().render(document([folder, base, child])))
        let offset = (6 * 24 + 6) * 4
        XCTAssertEqual(Double(bytes[offset + 3]), 128, accuracy: 1)
        XCTAssertEqual(Double(bytes[offset]), 64, accuracy: 1)
        XCTAssertEqual(Double(bytes[offset + 2]), 64, accuracy: 1)
    }
    func testBaseBlendModeIsAppliedAfterTheStack() throws {
        let backdrop = try layer("背景", color: (255, 255, 0))
        var base = try layer("底"); base.blendMode = .multiply
        let child = try layer("蓝", color: (0, 0, 255), base: base.id)
        let bytes = try pixels(DocumentRenderer().render(document([backdrop, base, child])))
        let offset = (6 * 24 + 6) * 4
        XCTAssertEqual(Array(bytes[offset..<offset + 4]), [0, 0, 0, 255])
    }
    func testPixelsAndMaskPreviewMatchCommittedBaseAndChild() throws {
        var base = try layer("底", alpha: 180); base.maskPNGData = try mask()
        let child = try layer("蓝", color: (0, 0, 255), base: base.id)
        let original = document([base, child]), renderer = DocumentRenderer()
        let replacement = try raster((0, 255, 0), alpha: 100), image = try RasterImage.decode(replacement)
        let white = try RasterImage.solidMask(width: 4, height: 3, white: true)
        for index in [0, 1] {
            var committed = original
            committed.layers[index].pngData = replacement; committed.layers[index].maskPNGData = try RasterImage.png(white)
            let preview = try renderer.render(original, replacing: original.layers[index].id, with: image, replacementMask: white)
            try assertSame(preview, renderer.render(committed))
            committed.layers[index].maskPNGData = original.layers[index].maskPNGData
            try assertSame(renderer.render(original, replacing: original.layers[index].id, with: image), renderer.render(committed))
        }
    }
    func testMovedTemporaryGeometryKeepsLiveDependency() throws {
        let base = try layer("底", alpha: 128), child = try layer("蓝", color: (0, 0, 255), base: base.id)
        var previewDocument = document([base, child]); previewDocument.layers[0].transform.origin.x += 5
        let source = try RasterImage.decode(XCTUnwrap(base.pngData)), renderer = DocumentRenderer()
        let preview = try renderer.render(previewDocument, replacing: base.id, with: source)
        try assertSame(preview, renderer.render(previewDocument))
        XCTAssertNotEqual(try pixels(preview), try pixels(renderer.render(document([base, child]))))
    }
    func testToggleSharesBaseReleaseSuffixAndHistoryPreservesRawPixels() throws {
        let base = try layer("底"), first = try layer("一"), second = try layer("二")
        let editor = try DocumentEditor(document: document([base, first, second]))
        try editor.setClipping(layerID: first.id, enabled: true); try editor.setClipping(layerID: second.id, enabled: true)
        XCTAssertEqual(editor.document.layers[2].maskSourceID, base.id)
        let clipped = editor.document
        try editor.setClipping(layerID: first.id, enabled: false)
        XCTAssertTrue(editor.document.layers.allSatisfy { $0.maskSourceID == nil })
        XCTAssertEqual(editor.document.layers.map(\.pngData), clipped.layers.map(\.pngData))
        try editor.undo(); XCTAssertEqual(editor.document.layers, clipped.layers)
        try editor.redo(); XCTAssertTrue(editor.document.layers.allSatisfy { $0.maskSourceID == nil })
        XCTAssertEqual(editor.undoCount, 3)
    }
    func testLockedSuffixReleaseAndInvalidMutationsAreAtomic() throws {
        let base = try layer("底"), first = try layer("一", base: base.id)
        var second = try layer("锁定二", base: base.id); second.isLocked = true
        let folder = group(), editor = try DocumentEditor(document: document([base, first, second, folder]))
        let original = editor.document
        XCTAssertThrowsError(try editor.setClipping(layerID: first.id, enabled: false))
        XCTAssertThrowsError(try editor.clippingBase(for: base.id))
        XCTAssertThrowsError(try editor.deleteLayer(base.id))
        XCTAssertThrowsError(try editor.reorderLayer(base.id, offset: 1))
        XCTAssertThrowsError(try editor.reorderLayer(folder.id, offset: -2))
        XCTAssertThrowsError(try editor.moveLayer(first.id, into: folder.id))
        XCTAssertEqual(editor.document, original); XCTAssertFalse(editor.canUndo)
    }
    func testDuplicateBaseAndChildKeepExistingStackAndGroupCopyRemapsIDs() throws {
        let folder = group(), base = try layer("底", parent: folder.id), child = try layer("蓝", parent: folder.id, base: base.id)
        let top = try layer("外部"), editor = try DocumentEditor(document: document([folder, top, base, child]))
        let baseCopy = try editor.duplicateLayer(base.id)
        XCTAssertEqual(editor.document.layers.filter { $0.parentID == folder.id }.map(\.id), [base.id, child.id, baseCopy])
        let childCopy = try editor.duplicateLayer(child.id)
        XCTAssertEqual(editor.document.layers.first { $0.id == childCopy }?.maskSourceID, base.id)
        let groupCopy = try editor.duplicateLayer(folder.id), copies = editor.document.layers.filter { $0.parentID == groupCopy }
        let copiedBase = try XCTUnwrap(copies.first { $0.name == base.name })
        XCTAssertNotEqual(copiedBase.id, base.id)
        XCTAssertEqual(copies.filter { $0.maskSourceID != nil }.map(\.maskSourceID), [copiedBase.id, copiedBase.id])
        XCTAssertEqual(editor.document.layers.filter { $0.parentID == nil }.map(\.id), [folder.id, groupCopy, top.id])
        try editor.document.validate(); try editor.deleteLayer(groupCopy)
        XCTAssertFalse(editor.document.layers.contains { $0.parentID == groupCopy })
    }
    func testGraphRejectsCyclesDanglingCrossParentChainedAndDetachedReferences() throws {
        let folder = group(), base = try layer("底"), child = try layer("子", base: base.id), top = try layer("顶", base: base.id)
        var invalid = document([base, child]); invalid.layers[0].maskSourceID = child.id
        XCTAssertThrowsError(try invalid.validate())
        invalid = document([base, child]); invalid.layers[1].maskSourceID = UUID()
        XCTAssertThrowsError(try invalid.validate())
        invalid = document([folder, base, child]); invalid.layers[1].parentID = folder.id
        XCTAssertThrowsError(try invalid.validate())
        invalid = document([base, child, top]); invalid.layers[2].maskSourceID = child.id
        XCTAssertThrowsError(try invalid.validate())
        invalid = document([base, try layer("隔层"), child]); XCTAssertThrowsError(try invalid.validate())
    }
    func testNativeManifestRoundTripUsesMaskSourceIDAndVersionGuard() throws {
        let base = try layer("底", alpha: 128), child = try layer("子", base: base.id)
        let original = document([base, child]), url = try package()
        try DocumentStore.save(original, to: url); XCTAssertEqual(try DocumentStore.load(from: url), original)
        let manifestURL = url.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[1]["maskSourceID"] as? String, base.id.uuidString)
        try FileManager.default.removeItem(at: url.appendingPathComponent("ipad-state.json"))
        XCTAssertEqual(try DocumentStore.load(from: url).layers, original.layers)
        json["version"] = 4; try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        XCTAssertThrowsError(try DocumentStore.load(from: url))
    }
    func testWholeStackMergePreservesOffCanvasAppearanceAndUndo() throws {
        var base = try layer("底", alpha: 128); base.transform.origin = CGPoint(x: -3, y: -2); base.maskPNGData = try mask()
        var child = try layer("蓝", color: (0, 0, 255), base: base.id); child.transform.origin = CGPoint(x: -1, y: 0)
        let original = document([base, child]), renderer = DocumentRenderer()
        let plan = try LayerMerge.plan(document: original, selectedIDs: [base.id, child.id])
        let merged = try LayerMerge.render(plan: plan, document: original, renderer: renderer)
        XCTAssertEqual(merged.transform.origin, CGPoint(x: -3, y: -2))
        let editor = try DocumentEditor(document: original)
        try editor.transaction("合并") { try LayerMerge.apply(plan: plan, mergedLayer: merged, to: &$0) }
        XCTAssertNil(editor.document.layers[0].maskSourceID)
        try assertSame(renderer.render(original), renderer.render(editor.document), tolerance: 1)
        try assertSame(renderer.render(layers: original.layers, bounds: plan.bounds), renderer.render(layers: editor.document.layers, bounds: plan.bounds), tolerance: 1)
        try editor.undo(); XCTAssertEqual(editor.document.layers, original.layers)
        try editor.redo(); XCTAssertEqual(editor.document.layers.count, 1)
    }
    func testMergeRejectsEitherSideOfExternalDependencyButWholeGroupWorks() throws {
        let folder = group(), base = try layer("底", parent: folder.id), child = try layer("一", parent: folder.id, base: base.id)
        let second = try layer("二", parent: folder.id, base: base.id), bottom = try layer("其他", parent: folder.id)
        let source = document([folder, bottom, base, child, second])
        let selections: [Set<UUID>] = [[child.id, second.id], [bottom.id, base.id], [base.id, child.id]]
        for ids in selections {
            XCTAssertThrowsError(try LayerMerge.plan(document: source, selectedIDs: ids)) { XCTAssertEqual($0 as? LayerMergeError, .clippingDependency) }
        }
        let plan = try LayerMerge.groupPlan(document: source, groupID: folder.id)
        let renderer = DocumentRenderer(), merged = try LayerMerge.render(plan: plan, document: source, renderer: renderer)
        var result = source; try LayerMerge.apply(plan: plan, mergedLayer: merged, to: &result)
        try assertSame(renderer.render(source), renderer.render(result), tolerance: 1)
    }
}
