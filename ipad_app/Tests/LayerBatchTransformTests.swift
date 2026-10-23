import XCTest
import CoreGraphics
@testable import CompositorKit

final class LayerBatchTransformTests: XCTestCase {
    private func layer(_ name: String = "层", parent: UUID? = nil, angle: CGFloat = 0) throws -> RasterLayer {
        let context = try RasterImage.context(width: 4, height: 3)
        context.setFillColor(CGColor(red: 0.5, green: 0, blue: 0, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        return RasterLayer(name: name, pngData: try RasterImage.png(XCTUnwrap(context.makeImage())),
            transform: .init(origin: CGPoint(x: 5, y: 7), size: CGSize(width: 20, height: 12), rotation: angle, sampling: .nearest), parentID: parent)
    }
    private func group(parent: UUID? = nil, mask: Bool = false) throws -> RasterLayer {
        RasterLayer(name: "组", transform: .init(size: CGSize(width: 32, height: 24), sampling: .nearest), parentID: parent,
            isGroup: true, maskPNGData: mask ? try RasterImage.png(RasterImage.solidMask(width: 2, height: 2, white: true)) : nil)
    }
    private func doc(_ layers: [RasterLayer]) -> CanvasDocument {
        CanvasDocument(width: 100, height: 80, layers: layers, activeLayerID: layers.last?.id)
    }
    private func moved(_ t: LayerTransform) -> LayerTransform {
        var next = t; next.origin.x += 9.25; next.origin.y -= 5.5; return next
    }
    /// Independent affine-composition oracle: the existing renderer's pixel map,
    /// carried by old-box inverse then new-box map, must agree at every corner.
    private func assertFollows(_ before: RasterLayer, _ after: RasterLayer, box: LayerTransform, next: LayerTransform,
                               file: StaticString = #filePath, line: UInt = #line) {
        let renderer = DocumentRenderer(), unit = CGSize(width: 1, height: 1)
        let from = renderer.pixelToDocument(before, size: unit), to = renderer.pixelToDocument(after, size: unit)
        let oldBox = renderer.pixelToDocument(RasterLayer(transform: box), size: unit)
        let newBox = renderer.pixelToDocument(RasterLayer(transform: next), size: unit)
        for p in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0.3, y: 0.7)] {
            let expected = p.applying(from).applying(oldBox.inverted()).applying(newBox), actual = p.applying(to)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-7, file: file, line: line)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-7, file: file, line: line)
        }
    }

    func testAncestorAndDescendantAreCarriedOnceInVisualOrder() throws {
        let g = try group(), nested = try group(parent: g.id), a = try layer(parent: nested.id), b = try layer()
        let d = doc([g, b, a, nested]) // Deliberately interleaved storage.
        let p = try LayerBatchTransformPlan(document: d, selectedIDs: [g.id, a.id, b.id])
        XCTAssertEqual(p.rootIDs, [g.id, b.id]); XCTAssertEqual(p.carriedIDs, [g.id, nested.id, a.id, b.id])
        let output = try p.layers(following: moved(p.original))
        XCTAssertEqual(output[0], g); XCTAssertEqual(output[3], nested, "Unmasked group placeholders have no pixel geometry")
        XCTAssertEqual(output[2].transform.origin, CGPoint(x: 14.25, y: 1.5))
        XCTAssertEqual(output.map(\.id), d.layers.map(\.id))
    }

    func testTranslationIsExactAndPreservesEveryOtherField() throws {
        var a = try layer(angle: 1e250), b = try layer()
        a.transform.flipX = true; a.maskPNGData = try RasterImage.png(RasterImage.solidMask(width: 2, height: 1, white: false)); a.maskEnabled = false
        a.blendMode = .multiply; a.opacity = 0.38; b.isVisible = false; b.transform.origin.x = -25
        let d = doc([a,b]), p = try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id])
        let output = try p.layers(following:moved(p.original))
        for (old,new) in zip(d.layers,output) {
            var expected = old; expected.transform.origin.x += 9.25; expected.transform.origin.y -= 5.5
            XCTAssertEqual(new,expected)
        }
    }

    func testUniformScaleRotationAndAllFlipsMatchAffineOracle() throws {
        for angle: CGFloat in [0,37,90,-145] { for flipX in [false,true] { for flipY in [false,true] {
            var a = try layer(angle:angle); a.transform.flipX = flipX; a.transform.flipY = flipY
            let b = try layer(), d = doc([a,b]), p = try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id])
            for commonX in [false,true] { for commonY in [false,true] {
                var next = moved(p.original); next.size.width *= 1.7; next.size.height *= 1.7
                next.rotation = -53; next.flipX = commonX; next.flipY = commonY
                let output = try p.layers(following:next)
                for (old,new) in zip(d.layers,output) { assertFollows(old,new,box:p.original,next:next) }
                XCTAssertEqual(output[0].pngData,a.pngData); XCTAssertEqual(output[0].transform.sampling,a.transform.sampling)
            }}
        }}}
    }

    func testAnisotropicScalingSupportsOrthogonalLayersWithoutShear() throws {
        for angle: CGFloat in [0,90,180,270,-90,450] {
            var a = try layer(angle:angle); a.transform.flipX = true
            let b = try layer(), d = doc([a,b]), p = try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id])
            XCTAssertTrue(p.allowsNonUniformScale)
            var next = p.original; next.size.width *= 2; next.size.height *= 3; next.rotation = 28; next.flipY = true
            for (old,new) in zip(d.layers,try p.layers(following:next)) { assertFollows(old,new,box:p.original,next:next) }
        }
    }

    func testShearRejectsTheWholePlanInsteadOfApproximating() throws {
        let a = try layer(angle:37), b = try layer(), d = doc([a,b])
        let p = try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id]); XCTAssertFalse(p.allowsNonUniformScale)
        var next = p.original; next.size.width *= 2
        var attempted = d
        XCTAssertThrowsError(try p.apply(next,to:&attempted)) { XCTAssertTrue($0.localizedDescription.contains("斜切")) }
        XCTAssertEqual(attempted,d)
        next.size.height *= 2; XCTAssertNoThrow(try p.layers(following:next))
    }

    func testOriginalBoxReturnsExactSourcesWithoutNormalization() throws {
        var a = try layer(angle:540); a.transform.flipX = true
        let b = try layer(), d = doc([a,b]), p = try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id])
        _ = try p.layers(following:moved(p.original))
        XCTAssertEqual(try p.layers(following:p.original),d.layers)
    }

    func testStaleSourceCanvasActiveLayerAndRevisionAreRejectedAtomically() throws {
        let a = try layer(), b = try layer(), d = doc([a,b]), p = try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id])
        let changes: [(inout CanvasDocument)->Void] = [
            { $0.width += 1 }, { $0.revision += 1 }, { $0.activeLayerID = a.id },
            { $0.layers[0].transform.origin.x += 1 }, { $0.layers[1].isLocked = true }, { $0.name += "另存" }
        ]
        for change in changes {
            var edited = d; change(&edited); let before = edited
            XCTAssertFalse(p.matches(edited)); XCTAssertThrowsError(try p.apply(moved(p.original),to:&edited)); XCTAssertEqual(edited,before)
        }
    }

    func testInvalidFrameOrOneInvalidMemberDoesNotPartiallyMoveOtherLayers() throws {
        var a = try layer(), b = try layer(); a.transform.size = CGSize(width:1,height:1); b.transform.origin.x = 500
        let d = doc([a,b]), p = try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id])
        var invalid = p.original; invalid.origin.x = .nan
        XCTAssertThrowsError(try p.layers(following:invalid))
        invalid = p.original; invalid.size.width *= 0.5; invalid.size.height *= 0.5
        var attempted = d; XCTAssertThrowsError(try p.apply(invalid,to:&attempted)); XCTAssertEqual(attempted,d)
    }

    func testExplicitSelectionIncludingBlackRejectsWholeLayerFallback() throws {
        let a = try layer(), b = try layer(); var d = doc([a,b])
        d.selectionMaskPNGData = try RasterImage.png(RasterImage.solidMask(width:100,height:80,white:false))
        XCTAssertThrowsError(try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id])) {
            XCTAssertTrue($0.localizedDescription.contains("取消选区"))
        }
    }

    func testLockedHiddenDescendantOrAncestorRejectsButUnrelatedLockDoesNot() throws {
        let g = try group(); var a = try layer(parent:g.id), b = try layer()
        a.isVisible = false; a.isLocked = true
        var d = doc([g,a,b]); XCTAssertThrowsError(try LayerBatchTransformPlan(document:d,selectedIDs:[g.id]))
        d.layers[1].isLocked = false; d.layers[0].isLocked = true
        XCTAssertThrowsError(try LayerBatchTransformPlan(document:d,selectedIDs:[a.id]))
        b.isLocked = true; d = doc([g,try layer(parent:g.id),b])
        XCTAssertNoThrow(try LayerBatchTransformPlan(document:d,selectedIDs:[g.id]))
    }

    func testBlankGroupAndEmptySelectionRejectWhileHiddenPixelsParticipate() throws {
        let g = try group(); var a = try layer(parent:g.id), d = doc([g])
        XCTAssertThrowsError(try LayerBatchTransformPlan(document:d,selectedIDs:[g.id]))
        XCTAssertThrowsError(try LayerBatchTransformPlan(document:d,selectedIDs:[]))
        a.isVisible = false; d.layers.append(a)
        XCTAssertNoThrow(try LayerBatchTransformPlan(document:d,selectedIDs:[g.id]))
        d.layers[1].pngData = nil
        XCTAssertThrowsError(try LayerBatchTransformPlan(document:d,selectedIDs:[g.id]))
    }

    func testEnabledDisabledAndNestedGroupMasksFollowWithoutTouchingSamples() throws {
        let g = try group(mask:true); var nested = try group(parent:g.id,mask:true); nested.maskEnabled = false
        let a = try layer(parent:nested.id), outside = try layer(), d = doc([g,nested,a,outside])
        let p = try LayerBatchTransformPlan(document:d,selectedIDs:[g.id,a.id])
        var next = p.original; next.rotation = 41; next.flipX = true
        let result = try p.layers(following:next)
        for i in 0..<3 {
            assertFollows(d.layers[i],result[i],box:p.original,next:next)
            XCTAssertEqual(result[i].pngData,d.layers[i].pngData); XCTAssertEqual(result[i].maskPNGData,d.layers[i].maskPNGData)
            XCTAssertEqual(result[i].maskEnabled,d.layers[i].maskEnabled)
        }
        XCTAssertEqual(result[3],outside)
    }

    func testPartialAndCompleteClippingSelectionsPreserveReferencesAndBase() throws {
        let base = try layer(); var clip = try layer(); clip.maskSourceID = base.id
        let other = try layer(), d = doc([base,clip,other])
        let p = try LayerBatchTransformPlan(document:d,selectedIDs:[clip.id,other.id])
        let result = try p.layers(following:moved(p.original))
        XCTAssertEqual(result[0],base); XCTAssertEqual(result[1].maskSourceID,base.id)
        let whole = try LayerBatchTransformPlan(document:d,selectedIDs:[base.id,clip.id])
        XCTAssertNoThrow(try whole.layers(following:moved(whole.original)))
    }

    func testOneTransactionUndoRedoAndProjectRoundTripPreserveRawAssets() throws {
        let g = try group(mask:true), a = try layer(parent:g.id), b = try layer(), d = doc([g,a,b])
        let p = try LayerBatchTransformPlan(document:d,selectedIDs:[g.id,b.id]), editor = try DocumentEditor(document:d)
        let next = moved(p.original)
        try editor.transaction("共同变换") { try p.apply(next,to:&$0) }
        XCTAssertEqual(editor.undoCount,1); let transformed = editor.document
        try editor.undo(); XCTAssertEqual(editor.document.layers,d.layers)
        try editor.redo(); XCTAssertEqual(editor.document.layers,transformed.layers)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".comp")
        defer { try? FileManager.default.removeItem(at:url) }
        try DocumentStore.save(editor.document,to:url); XCTAssertEqual(try DocumentStore.load(from:url),editor.document)
        let noOp = try LayerBatchTransformPlan(document:editor.document,selectedIDs:[g.id,b.id])
        try editor.undo(); let redo = editor.canRedo
        XCTAssertTrue(redo)
        let reset = try LayerBatchTransformPlan(document:editor.document,selectedIDs:[g.id,b.id])
        try editor.transaction("原地") { try reset.apply(reset.original,to:&$0) }
        XCTAssertTrue(editor.canRedo); XCTAssertFalse(noOp.matches(editor.document))
    }

    func testOffCanvasBoundsAreIncludedAndNeverTrimmedToCanvas() throws {
        var a = try layer(), b = try layer(); a.transform.origin = CGPoint(x:-90,y:-40); b.transform.origin = CGPoint(x:240,y:160)
        let d = doc([a,b]), p = try LayerBatchTransformPlan(document:d,selectedIDs:[a.id,b.id])
        XCTAssertEqual(p.original.origin,a.transform.origin); XCTAssertGreaterThan(p.original.size.width,CGFloat(d.width))
        for (old,new) in zip(d.layers,try p.layers(following:moved(p.original))) { assertFollows(old,new,box:p.original,next:moved(p.original)) }
    }

    func testGroupMaskBudgetIsCheckedBeforeLargePreviewAllocations() throws {
        let g = try group(mask:true), a = try layer(parent:g.id); var d = doc([g,a]); d.width = 4000; d.height = 4000
        let p = try LayerBatchTransformPlan(document:d,selectedIDs:[g.id])
        var next = p.original; next.origin = .zero; next.size = CGSize(width:4000,height:4000)
        XCTAssertThrowsError(try p.layers(following:next)) { XCTAssertTrue($0.localizedDescription.contains("内存预算")) }
    }
}
