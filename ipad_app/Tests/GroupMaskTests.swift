import XCTest
import CoreGraphics
@testable import CompositorKit

final class GroupMaskTests: XCTestCase {
    private let red: [UInt8] = [255, 0, 0, 255], blue: [UInt8] = [0, 0, 255, 255]
    private func png(_ pixel: [UInt8], width: Int = 8, height: Int = 6) throws -> Data {
        let data = Data((0..<width * height).flatMap { _ in pixel })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try RasterImage.png(image)
    }
    private func mask(_ value: UInt8, width: Int = 1, height: Int = 1, values: [UInt8]? = nil) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(values ?? Array(repeating: value, count: width * height)) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try RasterImage.png(image)
    }
    private func group(_ value: UInt8 = 128, parent: UUID? = nil) throws -> RasterLayer {
        RasterLayer(name: "组", transform: .init(size: CGSize(width: 8, height: 6), sampling: .nearest), parentID: parent,
                    isGroup: true, maskPNGData: try mask(value))
    }
    private func layer(_ pixel: [UInt8], parent: UUID? = nil) throws -> RasterLayer {
        RasterLayer(name: "图层", pngData: try png(pixel), transform: .init(size: CGSize(width: 8, height: 6), sampling: .nearest), parentID: parent)
    }
    private func document(_ layers: [RasterLayer]) -> CanvasDocument {
        CanvasDocument(width: 8, height: 6, layers: layers, activeLayerID: layers.last?.id)
    }
    private func pixels(_ image: CGImage) throws -> [[UInt8]] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.width * image.height).map { i in Array(UnsafeBufferPointer(start: bytes + i * 4, count: 4)) }
    }
    private func assertPixel(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(zip(a,b).map { abs(Int($0) - Int($1)) }.max() ?? 0, tolerance, file: file, line: line)
    }
    private func assertSame(_ a: CGImage, _ b: CGImage, tolerance: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws {
        let lhs = try pixels(a), rhs = try pixels(b)
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (a,b) in zip(lhs,rhs) { assertPixel(a,b,tolerance:tolerance,file:file,line:line) }
    }

    func testOverlappingOpaqueChildrenGetOneGroupCoverage() throws {
        let g = try group(), a = try layer(red, parent: g.id), b = try layer(blue, parent: g.id)
        let output = try pixels(DocumentRenderer().render(document([g,a,b])))
        XCTAssertTrue(output.allSatisfy { $0 == [0,0,128,128] }, "Per-child masking would incorrectly give alpha 192")
    }
    func testWhiteAndDisabledMasksKeepPassThroughBlendAndOpacityExactly() throws {
        let renderer = DocumentRenderer()
        for mode in LayerBlendMode.allCases {
            let background = try layer([75,110,145,200])
            var g = try group(255); g.opacity = 0.63
            var a = try layer([100,20,70,150], parent:g.id); a.blendMode = mode
            let b = try layer([20,80,40,100], parent:g.id)
            let withMask = document([background,g,a,b])
            var without = withMask; without.layers[1].maskPNGData = nil
            try assertSame(renderer.render(withMask),renderer.render(without))
            var disabled = withMask; disabled.layers[1].maskPNGData = try mask(0); disabled.layers[1].maskEnabled = false
            try assertSame(renderer.render(disabled),renderer.render(without))
        }
    }
    func testBlackMaskRestoresBackdropIncludingItsAlpha() throws {
        let background = try layer([0,0,90,128]), g = try group(0), a = try layer(red,parent:g.id)
        let renderer = DocumentRenderer()
        try assertSame(renderer.render(document([background,g,a])),renderer.render(document([background])))
    }
    func testNestedGroupMasksApplyOnceAtEachBoundary() throws {
        let outer = try group(), inner = try group(parent:outer.id)
        let a = try layer(red,parent:inner.id), b = try layer(blue,parent:inner.id)
        let output = try pixels(DocumentRenderer().render(document([outer,inner,a,b])))
        XCTAssertTrue(output.allSatisfy { $0 == [0,0,64,64] })
    }
    func testGroupOpacityRemainsPerDescendantBeforeOneGroupMask() throws {
        var g = try group(); g.opacity = 0.5
        let a = try layer(red,parent:g.id), b = try layer(blue,parent:g.id)
        for pixel in try pixels(DocumentRenderer().render(document([g,a,b]))) {
            assertPixel(pixel,[32,0,64,96],tolerance:1)
        }
    }
    func testClippingStackBaseCoverageIsNotRepeatedByGroupMask() throws {
        let g = try group(), base = try layer([128,0,0,128],parent:g.id)
        var child = try layer(blue,parent:g.id); child.maskSourceID = base.id
        for pixel in try pixels(DocumentRenderer().render(document([g,base,child]))) {
            assertPixel(pixel,[0,0,64,64])
        }
    }
    func testNumericMaskPlacementUsesTopLeftRowsAndLeavesExteriorBackdrop() throws {
        let values: [UInt8] = [0,64,128,192,255,0]
        var g = try group(); g.transform = .init(origin:CGPoint(x:2,y:1),size:CGSize(width:3,height:2),sampling:.nearest)
        g.maskPNGData = try mask(0,width:3,height:2,values:values)
        let background = try layer([0,0,128,128]), a = try layer(red,parent:g.id)
        let output = try pixels(DocumentRenderer().render(document([background,g,a])))
        for y in 0..<6 { for x in 0..<8 {
            let weight = x >= 2 && x < 5 && y >= 1 && y < 3 ? Int(values[(y-1)*3+x-2]) : 0
            let expected: [UInt8] = [UInt8(weight),0,UInt8((128*(255-weight)+127)/255),UInt8((128*(255-weight)+255*weight+127)/255)]
            assertPixel(output[y*8+x],expected)
        } }
    }
    func testRotatedFlippedGroupCoverageMatchesPlacedLayerMask() throws {
        var g = try group(); g.transform = .init(origin:CGPoint(x:2,y:1),size:CGSize(width:3,height:2),rotation:90,flipX:true,sampling:.nearest)
        g.maskPNGData = try mask(0,width:3,height:2,values:[0,128,255,64,192,255])
        let content = try layer(blue,parent:g.id), background = try layer([90,0,0,128])
        var expected = try layer(blue); expected.transform = g.transform; expected.maskPNGData = g.maskPNGData
        try assertSame(DocumentRenderer().render(document([background,g,content])),
                       DocumentRenderer().render(document([background,expected])),tolerance:1)
    }
    func testMaskPreviewMatchesCommitAndDoesNotPoisonOriginalCache() throws {
        let g = try group(), a = try layer(red,parent:g.id), b = try layer(blue,parent:g.id)
        let original = document([g,a,b]), renderer = DocumentRenderer()
        let before = try renderer.render(original), replacement = try RasterImage.decode(mask(255))
        let preview = try renderer.render(original,replacing:g.id,with:nil,replacementMask:replacement)
        var committed = original; committed.layers[0].maskPNGData = try mask(255)
        try assertSame(preview,renderer.render(committed))
        try assertSame(before,renderer.render(original))
        var disabled = original; disabled.layers[0].maskEnabled = false
        try assertSame(renderer.render(disabled,replacing:g.id,with:nil,replacementMask:try RasterImage.decode(mask(0))),renderer.render(committed))
    }
    func testMaskedGroupMergeKeepsAppearanceFullBoundsUndoAndOriginalBytes() throws {
        let g = try group()
        var a = try layer(red,parent:g.id); a.transform.origin = CGPoint(x:-2,y:-1)
        let b = try layer(blue,parent:g.id), original = document([g,a,b]), editor = try DocumentEditor(document:original)
        let renderer = DocumentRenderer(), plan = try LayerMerge.groupPlan(document:original,groupID:g.id)
        let merged = try LayerMerge.render(plan:plan,document:original,renderer:renderer)
        XCTAssertEqual(merged.transform.origin,CGPoint(x:-2,y:-1))
        try editor.transaction("合并") { try LayerMerge.apply(plan:plan,mergedLayer:merged,to:&$0) }
        try assertSame(renderer.render(original),renderer.render(editor.document),tolerance:1)
        try editor.undo(); XCTAssertEqual(editor.document.layers,original.layers)
        try editor.redo(); try assertSame(renderer.render(original),renderer.render(editor.document),tolerance:1)
    }

    func testProjectRoundTripAndArchiveKeepNumericMasksAndSemantics() throws {
        let g = try group(), a = try layer(red,parent:g.id), b = try layer(blue,parent:g.id)
        var original = document([g,a,b]); original.selectionMaskPNGData = try mask(128,width:8,height:6)
        original.appliedAIResults = [AIResultKey(jobID:"synthetic-job",resultID:"synthetic-result")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".comp")
        defer { try? FileManager.default.removeItem(at:url) }
        try DocumentStore.save(original,to:url)
        XCTAssertEqual(try DocumentStore.load(from:url),original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url.appendingPathComponent("ipad-state.json"))) as? [String:Any])
        XCTAssertEqual(json["groupMaskCompositing"] as? String,GroupMaskRules.semantics)
        let archive = try ProjectArchive.zip(contentsOf:url)
        XCTAssertNotNil(archive.range(of:Data(GroupMaskRules.semantics.utf8)))
        XCTAssertNotNil(archive.range(of:try XCTUnwrap(g.maskPNGData)))
    }

    func testForeignOrUnknownGroupMaskSemanticsAreRejected() throws {
        let g = try group(), a = try layer(red,parent:g.id), original = document([g,a])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".comp")
        defer { try? FileManager.default.removeItem(at:url) }
        try DocumentStore.save(original,to:url)
        let stateURL = url.appendingPathComponent("ipad-state.json"), state = try Data(contentsOf:stateURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:state) as? [String:Any])
        json.removeValue(forKey:"groupMaskCompositing")
        try JSONSerialization.data(withJSONObject:json).write(to:stateURL)
        XCTAssertThrowsError(try DocumentStore.load(from:url))
        json["groupMaskCompositing"] = "unknown-future-mode"
        try JSONSerialization.data(withJSONObject:json).write(to:stateURL)
        XCTAssertThrowsError(try DocumentStore.load(from:url))
        try FileManager.default.removeItem(at:stateURL)
        XCTAssertThrowsError(try DocumentStore.load(from:url))
        XCTAssertEqual(try Data(contentsOf:url.appendingPathComponent("images/"+g.id.uuidString+".mask.png")),g.maskPNGData)
    }

    func testDuplicatingAndReparentingGroupPreserveMaskAndClippingAssets() throws {
        let g = try group(), destination = RasterLayer(name:"目标",transform:.init(size:CGSize(width:8,height:6)),isGroup:true)
        let base = try layer(red,parent:g.id)
        var clipped = try layer(blue,parent:g.id); clipped.maskSourceID = base.id
        let editor = try DocumentEditor(document:document([g,destination,base,clipped]))
        let duplicate = try editor.duplicateLayer(g.id)
        XCTAssertEqual(editor.document.layers.first { $0.id == duplicate }?.maskPNGData,g.maskPNGData)
        try editor.moveLayers([g.id,clipped.id],into:destination.id)
        XCTAssertEqual(editor.document.layers.first { $0.id == g.id }?.transform,g.transform)
        XCTAssertEqual(editor.document.layers.first { $0.id == clipped.id },clipped)
        try editor.undo(); XCTAssertEqual(editor.document.layers.first { $0.id == g.id },g)
    }

    func testGrowingCanvasPadsGroupMaskWhiteWithoutCreatingGroupPixels() throws {
        var g = try group(); g.transform = .init(size:CGSize(width:2,height:2),sampling:.nearest)
        g.maskPNGData = try mask(0,width:2,height:2,values:[0,128,255,64]); g.maskEnabled = false
        let original = CanvasDocument(width:2,height:2,layers:[g],activeLayerID:g.id), editor = try DocumentEditor(document:original)
        let renderer = DocumentRenderer()
        try editor.transaction("扩大画布") { try renderer.resizeCanvas(&$0,width:4,height:3,resample:false) }
        let changed = try XCTUnwrap(editor.document.activeLayer)
        XCTAssertNil(changed.pngData); XCTAssertFalse(changed.maskEnabled)
        XCTAssertEqual(changed.transform.size,CGSize(width:4,height:3))
        let image = try RasterImage.decode(XCTUnwrap(changed.maskPNGData))
        let data = try XCTUnwrap(image.dataProvider?.data), bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let values = (0..<image.height).flatMap { y in (0..<image.width).map { x in bytes[y*image.bytesPerRow+x] } }
        XCTAssertEqual(values,[0,128,255,255,255,64,255,255,255,255,255,255])
        try editor.undo(); XCTAssertEqual(editor.document.layers,original.layers)
        try editor.redo(); XCTAssertEqual(editor.document.activeLayer,changed)
    }

    func testImageResizeScalesGroupMaskPlacementAndKeepsEncodedSamples() throws {
        let g = try group(), a = try layer(red,parent:g.id), editor = try DocumentEditor(document:document([g,a]))
        try editor.transaction("缩放图像") { try DocumentRenderer().resizeCanvas(&$0,width:16,height:12,resample:true) }
        XCTAssertEqual(editor.document.layers[0].transform.size,CGSize(width:16,height:12))
        XCTAssertEqual(editor.document.layers[0].maskPNGData,g.maskPNGData)
        XCTAssertNil(editor.document.layers[0].pngData)
        XCTAssertEqual(editor.document.layers[1].pngData,a.pngData)
    }

    func testWorkspaceBudgetRejectsBeforeCommitOrAllocation() throws {
        var outer = try group(), inner = try group(parent:outer.id)
        outer.maskPNGData = nil; inner.maskPNGData = nil
        outer.transform.size = CGSize(width:3000,height:3000); inner.transform.size = outer.transform.size
        let original = CanvasDocument(width:3000,height:3000,layers:[outer,inner]), editor = try DocumentEditor(document:original)
        let data = try mask(128)
        XCTAssertThrowsError(try editor.transaction("不应提交") { doc in
            doc.layers[0].maskPNGData = data; doc.layers[1].maskPNGData = data
        })
        XCTAssertEqual(editor.document,original); XCTAssertEqual(editor.undoCount,0)
        let smallGroup = try group(), content = try layer(red,parent:smallGroup.id)
        XCTAssertThrowsError(try DocumentRenderer(groupMaskWorkingByteLimit:100).render(document([smallGroup,content])))
    }
}
