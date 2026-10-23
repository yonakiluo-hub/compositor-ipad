import XCTest
import CoreGraphics
@testable import CompositorKit

final class ColorAdjustmentTests: XCTestCase {
    // Controlled premultiplied samples, including very low alpha, never personal artwork.
    private func png(_ pixels: [[UInt8]]) throws -> Data {
        let context = try RasterImage.context(width: pixels.count, height: 1)
        let p = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for (i, pixel) in pixels.enumerated() { for c in 0..<4 { p[i * 4 + c] = pixel[c] } }
        return try RasterImage.png(XCTUnwrap(context.makeImage()))
    }
    private func mask(_ values: [UInt8]) throws -> Data {
        let context = try RasterImage.context(width: values.count, height: 1, gray: true)
        let p = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for i in values.indices { p[i] = values[i] }
        return try RasterImage.png(XCTUnwrap(context.makeImage()))
    }
    private func layer(_ pixels: [[UInt8]], parent: UUID? = nil) throws -> RasterLayer {
        RasterLayer(pngData: try png(pixels), transform: .init(size: CGSize(width: pixels.count, height: 1), sampling: .nearest), parentID: parent)
    }
    private func invert() -> LayerAdjustment {
        var v = LayerAdjustment(kind: .curves)
        v.curves.channels[0] = [CurvePoint(x: 0, y: 255), CurvePoint(x: 255, y: 0)]
        return v
    }
    private func adjustment(_ value: LayerAdjustment? = nil, width: Int = 4, parent: UUID? = nil) -> RasterLayer {
        RasterLayer(name: "调整", transform: .init(size: CGSize(width: width, height: 1), sampling: .nearest), parentID: parent, adjustment: value ?? invert())
    }
    private func document(_ layers: [RasterLayer], width: Int? = nil, active: UUID? = nil) -> CanvasDocument {
        CanvasDocument(width: width ?? Int(layers[0].transform.size.width), height: 1, layers: layers, activeLayerID: active ?? layers.last?.id)
    }
    private func pixels(_ document: CanvasDocument) throws -> [[UInt8]] {
        let image = try DocumentRenderer().render(document)
        let context = try RasterImage.context(width: image.width, height: image.height)
        context.setBlendMode(.copy); RasterImage.draw(image, in: CGRect(origin: .zero, size: document.size), context: context)
        let p = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.width).map { i in (0..<4).map { p[i * 4 + $0] } }
    }
    private func near(_ a: [[UInt8]], _ b: [[UInt8]], tolerance: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x,y) in zip(a,b) { for (c,d) in zip(x,y) { XCTAssertLessThanOrEqual(abs(Int(c)-Int(d)), tolerance, file: file, line: line) } }
    }

    func testLevelsClippingGammaReversedOutputsAndChannelOrder() throws {
        XCTAssertEqual(LevelRange(black: 64, white: 128).apply(64.0/255), 0)
        XCTAssertEqual(LevelRange(black: 64, white: 128).apply(128.0/255), 1)
        XCTAssertEqual(LevelRange(gamma: 2).apply(0.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LevelRange(outputBlack: 255, outputWhite: 0).apply(0.25), 0.75, accuracy: 1e-12)
        var value = LayerAdjustment(kind: .levels)
        value.levels.ranges[1] = LevelRange(gamma: 2)
        value.levels.ranges[0] = LevelRange(black: 40, white: 210)
        let source = try layer([[64,64,64,255]])
        let result = try pixels(document([source,adjustment(value,width:1)]))[0]
        XCTAssertEqual(Double(result[0]), LevelRange(black:40,white:210).apply(128.0/255)*255, accuracy:1)
        XCTAssertEqual(result[1],result[2]); XCTAssertGreaterThan(result[0],result[1])
    }

    func testHermiteIdentityControlPointsAndNoOvershootAtExtrema() {
        var curves = CurvesSettings()
        for x in stride(from: 0.0, through:255, by:0.25) { XCTAssertEqual(curves.value(x,channel:0),x,accuracy:1e-10) }
        curves.channels[0] = [CurvePoint(x:0,y:10),CurvePoint(x:40,y:200),CurvePoint(x:100,y:40),CurvePoint(x:255,y:240)]
        for p in curves.channels[0] { XCTAssertEqual(curves.value(p.x,channel:0),p.y,accuracy:1e-10) }
        for (a,b) in zip(curves.channels[0],curves.channels[0].dropFirst()) {
            for x in stride(from:a.x,through:b.x,by:0.1) {
                let y = curves.value(x,channel:0)
                XCTAssertGreaterThanOrEqual(y,min(a.y,b.y)-1e-8); XCTAssertLessThanOrEqual(y,max(a.y,b.y)+1e-8)
            }
        }
    }

    func testIdentityPreservesAllPremultipliedBytesExactly() throws {
        let samples: [[UInt8]] = [[51,89,13,128],[1,0,1,1],[17,9,3,32],[0,0,0,0]]
        let base = try layer(samples), original = try pixels(document([base]))
        for kind in AdjustmentKind.allCases { XCTAssertEqual(try pixels(document([base,adjustment(LayerAdjustment(kind:kind))])),original) }
    }

    func testNearlyFlatCurvesKeepFiniteEndpointValuesAndRejectInfiniteSlopes() throws {
        var curves = CurvesSettings()
        curves.channels[0] = [CurvePoint(x:0,y:0),CurvePoint(x:128,y:1e-310),CurvePoint(x:255,y:2e-310)]
        XCTAssertTrue(curves.isValid)
        for x in 0...255 { XCTAssertTrue(curves.value(Double(x),channel:0).isFinite) }
        XCTAssertEqual(curves.value(128,channel:0),1e-310)
        curves.channels[0] = [CurvePoint(x:0,y:10),CurvePoint(x:1e-320,y:255),CurvePoint(x:255,y:0)]
        XCTAssertFalse(curves.isValid)
        var value = LayerAdjustment(kind:.curves); value.curves = curves
        XCTAssertThrowsError(try value.lookupTables())
    }

    func testInverseAndConstantCurvesPreserveAlphaIncludingSoftEdges() throws {
        let base = try layer([[64,32,0,128],[1,0,1,1],[17,9,3,32],[0,0,0,0]])
        let before = try pixels(document([base])), after = try pixels(document([base,adjustment()]))
        for (a,b) in zip(before,after) { XCTAssertEqual(a[3],b[3]); for c in 0..<3 { XCTAssertEqual(Int(a[c])+Int(b[c]),Int(a[3]),accuracy:1) } }
        var white = LayerAdjustment(kind:.curves); white.curves.channels[0] = [CurvePoint(x:0,y:255),CurvePoint(x:255,y:255)]
        let result = try pixels(document([base,adjustment(white)]))
        for (a,b) in zip(before,result) { XCTAssertEqual(b,[a[3],a[3],a[3],a[3]]) }
        XCTAssertEqual(base.pngData,try layer([[64,32,0,128],[1,0,1,1],[17,9,3,32],[0,0,0,0]]).pngData)
    }

    func testAdjustmentOnlyAffectsBelowAndVisibilityRestoresSource() throws {
        let base = try layer([[255,0,0,255],[255,0,0,255]])
        var a = adjustment(width:2)
        let top = try layer([[0,0,255,255],[0,0,0,0]])
        XCTAssertEqual(try pixels(document([base,a,top])),[[0,0,255,255],[0,255,255,255]])
        a.isVisible = false
        XCTAssertEqual(try pixels(document([base,a,top])),[[0,0,255,255],[255,0,0,255]])
    }

    func testSoftMaskAndOpacityInterpolateColorOnceKeepAlpha() throws {
        let base = try layer(Array(repeating:[128,0,0,128],count:4))
        var a = adjustment(); a.maskPNGData = try mask([0,64,128,255]); a.opacity = 0.5
        let output = try pixels(document([base,a]))
        near(output,[[128,0,0,128],[112,16,16,128],[96,32,32,128],[64,64,64,128]])
        a.maskEnabled = false
        near(try pixels(document([base,a])),Array(repeating:[64,64,64,128],count:4))
    }

    func testMaskPlacementAndRotationUseDocumentCoordinates() throws {
        let base = try layer(Array(repeating:[255,0,0,255],count:4))
        var a = adjustment(); a.transform = .init(origin:CGPoint(x:2,y:0),size:CGSize(width:1,height:1),rotation:180,sampling:.nearest)
        a.maskPNGData = try mask([128])
        near(try pixels(document([base,a])),[[255,0,0,255],[255,0,0,255],[127,128,128,255],[255,0,0,255]])
    }

    func testClippedAdjustmentUsesOriginalBaseCoverageOnce() throws {
        let backdrop = try layer(Array(repeating:[0,0,255,255],count:4))
        let base = try layer([[0,255,0,255],[0,128,0,128],[0,32,0,32],[0,0,0,0]])
        var a = adjustment(); a.maskSourceID = base.id
        near(try pixels(document([backdrop,base,a])),[[255,0,255,255],[128,0,255,255],[32,0,255,255],[0,0,255,255]])
        a.maskPNGData = try mask([128])
        let half = try pixels(document([backdrop,base,a]))
        near(half,[[128,127,128,255],[64,64,191,255],[16,16,239,255],[0,0,255,255]],tolerance:2)
        var hidden = base; hidden.isVisible = false
        XCTAssertEqual(try pixels(document([backdrop,hidden,a])),Array(repeating:[0,0,255,255],count:4))
    }

    func testClippedRasterAboveAdjustmentKeepsOrderAndIndependentOpacity() throws {
        let base = try layer([[0,128,0,128]])
        var a = adjustment(width:1); a.maskSourceID = base.id
        var top = try layer([[0,0,255,255]]); top.maskSourceID = base.id; top.opacity = 0.5
        near(try pixels(document([base,a,top])),[[64,0,128,128]])
    }

    func testPassThroughGroupAdjustmentAndNestedMasksUseBeforeAfterRule() throws {
        let base = try layer([[128,0,0,128]])
        var group = RasterLayer(name:"组",transform:.init(size:CGSize(width:1,height:1),sampling:.nearest),opacity:0.5,isGroup:true)
        let a = adjustment(width:1,parent:group.id)
        // Adjustment in a pass-through group sees the existing outside backdrop.
        near(try pixels(document([base,group,a])),[[64,64,64,128]])
        group.maskPNGData = try mask([128])
        near(try pixels(document([base,group,a])),[[96,32,32,128]])
        group.maskPNGData = try mask([0])
        XCTAssertEqual(try pixels(document([base,group,a])),try pixels(document([base])))
        group.maskPNGData = try mask([128])
        let outer = RasterLayer(name:"外组",transform:group.transform,isGroup:true,maskPNGData:try mask([128]))
        group.parentID = outer.id
        near(try pixels(document([base,outer,group,a])),[[112,16,16,128]])
    }

    func testSelectionCapturedAsMaskAndEditingDoesNotApplyItAgain() throws {
        let base = try layer([[255,0,0,255]])
        var source = document([base]); source.selectionMaskPNGData = try mask([128])
        let plan = try AdjustmentLayerEdit(document:source,kind:.curves)
        let next = try plan.preview(invert())
        XCTAssertEqual(next.layers.last?.maskPNGData,source.selectionMaskPNGData)
        near(try pixels(next),[[127,128,128,255]])
        let edit = try AdjustmentLayerEdit(document:next)
        XCTAssertEqual(try pixels(edit.preview(invert())),try pixels(next))
        var black = source; black.selectionMaskPNGData = try mask([0])
        let empty = try AdjustmentLayerEdit(document:black,kind:.curves).preview(invert())
        XCTAssertEqual(try pixels(empty),try pixels(source))
    }

    func testInsertionAboveCompleteStackAndIntoGroupWithInterleavedStorage() throws {
        let base = try layer([[255,0,0,255]])
        var clip = try layer([[0,255,0,255]]); clip.maskSourceID = base.id
        let group = RasterLayer(name:"组",transform:base.transform,isGroup:true)
        let child = try layer([[0,0,255,255]],parent:group.id)
        let source = document([group,base,child,clip],active:base.id)
        let next = try AdjustmentLayerEdit(document:source,kind:.curves).preview(invert())
        XCTAssertEqual(next.layers.map(\.id),source.layers.map(\.id)+[next.activeLayerID!])
        try next.validate()
        let intoGroup = try AdjustmentLayerEdit(document:document(source.layers,active:group.id),kind:.curves).preview(invert())
        XCTAssertEqual(intoGroup.activeLayer?.parentID,group.id); try intoGroup.validate()
    }

    func testOnceUndoRedoNoOpAndFrozenSourceRejectionAreAtomic() throws {
        let e = try DocumentEditor(document:document([try layer([[255,0,0,255]])]))
        let plan = try AdjustmentLayerEdit(document:e.document,kind:.curves)
        try e.transaction("曲线") { try plan.apply(invert(),to:&$0) }
        XCTAssertEqual(e.undoCount,1); XCTAssertEqual(e.document.layers[0].pngData,plan.source.layers[0].pngData)
        try e.undo(); XCTAssertTrue(e.canRedo)
        let noop = try AdjustmentLayerEdit(document:e.document,kind:.levels)
        var identity = LayerAdjustment(kind:.levels); identity.levels.channel = .blue
        try e.transaction("无操作") { try noop.apply(identity,to:&$0) }; XCTAssertTrue(e.canRedo)
        try e.redo(); let current = e.document
        XCTAssertThrowsError(try e.transaction("旧会话") { try plan.apply(invert(),to:&$0) }); XCTAssertEqual(e.document,current)
        let edit = try AdjustmentLayerEdit(document:e.document)
        var channelOnly = edit.original; channelOnly.curves.channel = .red
        let count = e.undoCount
        try e.transaction("只切通道") { try edit.apply(channelOnly,to:&$0) }; XCTAssertEqual(e.undoCount,count)
        var invalid = edit.original; invalid.curves.channels[0] = []
        XCTAssertThrowsError(try e.transaction("无效") { try edit.apply(invalid,to:&$0) }); XCTAssertEqual(e.document,current)
    }

    func testInvalidParametersAndUnsafeLayerKindsAreRejected() throws {
        let base = try layer([[255,0,0,255]])
        for range in [LevelRange(black:255),LevelRange(gamma:.nan),LevelRange(gamma:0),LevelRange(white:0),LevelRange(outputBlack:-1)] {
            var v = LayerAdjustment(kind:.levels); v.levels.ranges[0] = range
            XCTAssertThrowsError(try document([base,adjustment(v,width:1)]).validate())
        }
        for points in [[CurvePoint(x:0,y:0)], [CurvePoint(x:0,y:0),CurvePoint(x:0,y:255)], [CurvePoint(x:0,y:.infinity),CurvePoint(x:255,y:255)]] {
            var v = LayerAdjustment(kind:.curves); v.curves.channels[0] = points
            XCTAssertThrowsError(try document([base,adjustment(v,width:1)]).validate())
        }
        var a = adjustment(width:1); a.pngData = base.pngData
        XCTAssertThrowsError(try document([base,a]).validate())
        a.pngData = nil; a.isGroup = true; XCTAssertThrowsError(try document([base,a]).validate())
        a.isGroup = false; a.blendMode = .multiply; XCTAssertThrowsError(try document([base,a]).validate())
        a.blendMode = .normal
        var clip = base; clip.maskSourceID = a.id
        XCTAssertThrowsError(try document([a,clip]).validate())
        var locked = base; locked.isLocked = true
        XCTAssertThrowsError(try AdjustmentLayerEdit(document:document([locked]),kind:.curves))
    }

    func testDuplicateAndClippingOperationsPreserveLiveParameters() throws {
        let base = try layer([[0,128,0,128]])
        var a = adjustment(width:1); a.maskPNGData = try mask([128])
        let editor = try DocumentEditor(document:document([base,a]))
        try editor.setClipping(layerID:a.id,enabled:true)
        let id = try editor.duplicateLayer(a.id)
        let copy = try XCTUnwrap(editor.document.layers.first { $0.id == id })
        XCTAssertEqual(copy.adjustment,a.adjustment); XCTAssertEqual(copy.maskPNGData,a.maskPNGData); XCTAssertEqual(copy.maskSourceID,base.id)
        XCTAssertThrowsError(try editor.setPixels(layerID:a.id,pngData:base.pngData))
        XCTAssertThrowsError(try LayerMerge.plan(document:editor.document,selectedIDs:Set(editor.document.layers.map(\.id))))
        _ = try LayerMerge.stampVisible(document:editor.document,renderer:DocumentRenderer())
    }

    func testSaveReopenPreservesParametersRawAssetsAndNumericMasks() throws {
        let base = try layer([[64,32,0,128],[0,0,0,0]])
        var a = adjustment(width:2); a.maskPNGData = try mask([128,255])
        let source = document([base,a])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".comp")
        defer { try? FileManager.default.removeItem(at:url) }
        try DocumentStore.save(source,to:url)
        let reopened = try DocumentStore.load(from:url)
        XCTAssertEqual(reopened,source); XCTAssertEqual(try pixels(reopened),try pixels(source))
        XCTAssertEqual(try AdjustmentLayerEdit(document:reopened).original,a.adjustment)
        let encoded = try JSONSerialization.jsonObject(with:Data(contentsOf:url.appendingPathComponent("manifest.json"))) as! [String:Any]
        let records = encoded["layers"] as! [[String:Any]], value = records[1]["adjustment"] as! [String:Any]
        XCTAssertEqual(value["kind"] as? String,"Curves"); XCTAssertEqual(value["hue"] as? Double,0)
    }

    func testUnknownNestedFieldsKindsAndForeignSemanticsRejectBeforeEditing() throws {
        let source = document([try layer([[255,0,0,255]]),adjustment(width:1)],width:1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".comp")
        defer { try? FileManager.default.removeItem(at:url) }
        for field in ["root","range","point","kind","semantics"] {
            try DocumentStore.save(source,to:url)
            let file = url.appendingPathComponent("manifest.json")
            var root = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
            var layers = root["layers"] as! [[String:Any]], a = layers[1]["adjustment"] as! [String:Any]
            if field == "root" { a["futureEffect"] = 1 }
            if field == "kind" { a["kind"] = "Exposure" }
            if field == "range" { var l = a["levels"] as! [String:Any], r = l["ranges"] as! [[String:Any]]; r[0]["future"] = true; l["ranges"] = r; a["levels"] = l }
            if field == "point" { var c = a["curves"] as! [String:Any], p = c["channels"] as! [[[String:Any]]]; p[0][0]["future"] = true; c["channels"] = p; a["curves"] = c }
            layers[1]["adjustment"] = a; root["layers"] = layers
            try JSONSerialization.data(withJSONObject:root).write(to:file)
            try FileManager.default.removeItem(at:url.appendingPathComponent("ipad-state.json"))
            XCTAssertThrowsError(try DocumentStore.load(from:url),field)
        }
    }

    func testClippingAboveExistingClippedAdjustmentAndGroupDuplicateRemapsReferences() throws {
        let group = RasterLayer(name:"组",transform:.init(size:CGSize(width:1,height:1)),isGroup:true)
        let base = try layer([[0,128,0,128]],parent:group.id)
        var a = adjustment(width:1,parent:group.id); a.maskSourceID = base.id
        let top = try layer([[255,0,0,255]],parent:group.id)
        let editor = try DocumentEditor(document:document([group,base,a,top],width:1))
        try editor.setClipping(layerID:top.id,enabled:true)
        XCTAssertEqual(editor.document.activeLayer?.maskSourceID,base.id)
        let id = try editor.duplicateLayer(group.id)
        let copies = editor.document.layers.filter { $0.parentID == id }
        XCTAssertEqual(copies.count,3)
        XCTAssertEqual(copies[1].adjustment,a.adjustment); XCTAssertEqual(copies[1].maskSourceID,copies[0].id)
        XCTAssertEqual(copies[2].maskSourceID,copies[0].id)
    }

    func testBackupContainsLiveParametersAndSemanticsWithSourcePixels() throws {
        let source = document([try layer([[64,32,0,128]]),adjustment(width:1)],width:1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".comp")
        defer { try? FileManager.default.removeItem(at:url) }
        try DocumentStore.save(source,to:url)
        let zip = try ProjectArchive.zip(contentsOf:url)
        XCTAssertNotNil(zip.range(of:Data("pass-through-lut-v1".utf8)))
        XCTAssertNotNil(zip.range(of:Data("Curves".utf8)))
        XCTAssertNotNil(zip.range(of:try XCTUnwrap(source.layers[0].pngData)))
        XCTAssertEqual(try DocumentStore.load(from:url),source)
    }

    func testMaskPreviewMatchesCommitAndMemoryBudgetRejectsBeforeAllocation() throws {
        let base = try layer([[128,0,0,128],[128,0,0,128]])
        var a = adjustment(width:2); a.maskPNGData = try mask([255,0])
        let doc = document([base,a]), replacement = try RasterImage.decode(mask([0,128]))
        let renderer = DocumentRenderer()
        let preview = try renderer.render(doc,replacing:a.id,with:nil,replacementMask:replacement)
        var committed = doc; committed.layers[1].maskPNGData = try mask([0,128])
        XCTAssertEqual(preview.dataProvider?.data as Data?,try renderer.render(committed).dataProvider?.data as Data?)
        XCTAssertThrowsError(try GroupMaskRules.validate(doc.layers,bounds:CGRect(origin:.zero,size:doc.size),limit:1))
        a.maskEnabled = false
        XCTAssertNoThrow(try GroupMaskRules.validate([base,a],bounds:CGRect(origin:.zero,size:doc.size),limit:1))
    }

    func testBatchTransformMovesAdjustmentMaskWithoutInventingSourcePixels() throws {
        let base = try layer([[255,0,0,255],[255,0,0,255]])
        var a = adjustment(width:2); a.maskPNGData = try mask([0,255])
        let source = document([base,a]), plan = try LayerBatchTransformPlan(document:document([base,a]),selectedIDs:[base.id,a.id])
        var next = plan.original; next.origin.x += 1
        let result = try plan.layers(following:next)
        XCTAssertEqual(result[1].transform.origin.x,a.transform.origin.x+1)
        XCTAssertEqual(result[1].adjustment,a.adjustment); XCTAssertEqual(result[1].maskPNGData,a.maskPNGData); XCTAssertNil(result[1].pngData)
        XCTAssertEqual(source.layers[0].pngData,result[0].pngData)
    }

    func testCanvasGrowthPreservesAdjustmentParametersAndOldMaskSamples() throws {
        let base = try layer([[128,0,0,128],[128,0,0,128]])
        var a = adjustment(width:2); a.maskPNGData = try mask([128,0])
        var doc = document([base,a]); let renderer = DocumentRenderer()
        let before = try pixels(doc)
        try renderer.resizeCanvas(&doc,width:4,height:1,resample:false)
        try doc.validate()
        XCTAssertEqual(doc.layers[1].adjustment,a.adjustment); XCTAssertNil(doc.layers[1].pngData)
        XCTAssertEqual(doc.layers[1].maskPNGData,try mask([128,0,255,255]))
        XCTAssertEqual(Array(try pixels(doc).prefix(2)),before)
        XCTAssertEqual(Array(try pixels(doc).suffix(2)),[[0,0,0,0],[0,0,0,0]])
        try renderer.resizeCanvas(&doc,width:8,height:2,resample:true)
        XCTAssertEqual(doc.layers[1].adjustment,a.adjustment); XCTAssertNil(doc.layers[1].pngData)
        XCTAssertEqual(doc.layers[1].maskPNGData,try mask([128,0,255,255]))
    }
}
