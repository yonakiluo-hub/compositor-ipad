import XCTest
import CoreGraphics
@testable import CompositorKit

final class CanvasCropGuideTests: XCTestCase {
    private func gray(_ values: [UInt8], width: Int, height: Int) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(values) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try RasterImage.png(image)
    }
    private func grayValues(_ data: Data) throws -> [UInt8] {
        let image = try RasterImage.decode(data), bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        return (0..<image.height).flatMap { y in (0..<image.width).map { x in bytes[y * image.bytesPerRow + x] } }
    }
    private func fixture() throws -> CanvasDocument {
        let context = try RasterImage.context(width: 3, height: 3)
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        let png = try RasterImage.png(XCTUnwrap(context.makeImage()))
        let group = RasterLayer(name: "Group", transform: LayerTransform(size: CGSize(width: 6, height: 4)), isLocked: true,
            isGroup: true, maskPNGData: try gray(Array(repeating: 128, count: 24), width: 6, height: 4))
        let base = RasterLayer(name: "Base", pngData: png, transform: LayerTransform(origin: CGPoint(x: -1, y: 1), size: CGSize(width: 3, height: 3)), parentID: group.id)
        let clipped = RasterLayer(name: "Clip", pngData: png, transform: LayerTransform(origin: CGPoint(x: 1, y: 0), size: CGSize(width: 3, height: 3)), parentID: group.id, maskSourceID: base.id)
        var value = LayerAdjustment(kind: .levels); value.levels.ranges[0].outputWhite = 128
        let adjustment = RasterLayer(name: "Adjust", transform: LayerTransform(size: CGSize(width: 6, height: 4)),
            maskPNGData: try gray(Array(repeating: 128, count: 24), width: 6, height: 4), adjustment: value)
        return CanvasDocument(width: 6, height: 4, layers: [group, base, clipped, adjustment], activeLayerID: base.id,
            selectionMaskPNGData: try gray(Array(0..<24).map { UInt8($0 * 10) }, width: 6, height: 4),
            guides: [CanvasGuide(axis: .vertical, position: 3), CanvasGuide(axis: .horizontal, position: 1.5)])
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    func testCropRetainsEverySourceAndMovesAllGeometryGuidesAndNumericSelectionOnce() throws {
        let source = try fixture(), plan = try CanvasCropPlan(document: source)
        let result = try plan.preview(PixelRect(x: 1, y: 1, width: 3, height: 2))
        XCTAssertEqual(source.layers.map(\.pngData), result.layers.map(\.pngData))
        XCTAssertEqual(source.layers.map(\.maskPNGData), result.layers.map(\.maskPNGData))
        XCTAssertEqual(source.layers.map(\.id), result.layers.map(\.id))
        XCTAssertEqual(source.layers.map(\.maskSourceID), result.layers.map(\.maskSourceID))
        XCTAssertEqual(source.layers.map(\.adjustment), result.layers.map(\.adjustment))
        for (a, b) in zip(source.layers, result.layers) { XCTAssertEqual(b.transform.origin.x, a.transform.origin.x - 1); XCTAssertEqual(b.transform.origin.y, a.transform.origin.y - 1) }
        XCTAssertEqual(result.guides.map(\.position), [2, 0.5])
        XCTAssertEqual(try grayValues(XCTUnwrap(result.selectionMaskPNGData)), [70, 80, 90, 130, 140, 150])
        let before = try DocumentRenderer().render(source), cropped = try XCTUnwrap(before.cropping(to: CGRect(x: 1, y: 1, width: 3, height: 2)))
        XCTAssertEqual(try pixels(DocumentRenderer().render(result)), try pixels(cropped))
    }

    func testExpandedCropRevealsRetainedPixelsAndBlackSelectionPadding() throws {
        let original = try fixture(), cropped = try CanvasCropPlan(document: original).preview(PixelRect(x: 1, y: 1, width: 3, height: 2))
        let revealed = try CanvasCropPlan(document: cropped).preview(PixelRect(x: -1, y: -1, width: 6, height: 4))
        XCTAssertEqual(revealed.layers, original.layers)
        XCTAssertEqual(revealed.guides, original.guides)
        let selection = try grayValues(XCTUnwrap(revealed.selectionMaskPNGData))
        XCTAssertEqual(selection[0], 0); XCTAssertEqual(selection[7], 70); XCTAssertEqual(selection[15], 150)
        XCTAssertEqual(try pixels(DocumentRenderer().render(revealed)), try pixels(DocumentRenderer().render(original)))
    }

    func testCropOneUndoNoOpRedoAndStaleOrInvalidFailureAreAtomic() throws {
        let source = try fixture(), editor = try DocumentEditor(document: source), plan = try CanvasCropPlan(document: source)
        try editor.transaction("crop") { try plan.apply(PixelRect(x: 1, y: 0, width: 4, height: 3), to: &$0) }
        XCTAssertEqual(editor.undoCount, 1); try editor.undo(); XCTAssertTrue(editor.canRedo)
        let noOp = try CanvasCropPlan(document: editor.document)
        try editor.transaction("noop") { try noOp.apply(noOp.original, to: &$0) }
        XCTAssertTrue(editor.canRedo)
        let before = editor.document
        XCTAssertThrowsError(try editor.transaction("invalid") { try noOp.apply(PixelRect(x: 0, y: 0, width: 0, height: 1), to: &$0) })
        XCTAssertEqual(editor.document, before); XCTAssertTrue(editor.canRedo)
        XCTAssertThrowsError(try editor.transaction("stale") { try plan.apply(PixelRect(x: 0, y: 0, width: 1, height: 1), to: &$0) })
        XCTAssertEqual(editor.document, before); try editor.redo(); XCTAssertEqual(editor.document.width, 4)
    }

    func testGuidesAndCroppedResourcesPersistAndUnknownGuideFieldsReject() throws {
        let document = try CanvasCropPlan(document: fixture()).preview(PixelRect(x: 1, y: 1, width: 3, height: 2))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: root) }
        try DocumentStore.save(document, to: root)
        XCTAssertEqual(try DocumentStore.load(from: root), document)
        let manifest = root.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var guides = try XCTUnwrap(json["guides"] as? [[String: Any]]); guides[0]["futureSemantic"] = 1; json["guides"] = guides
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        XCTAssertThrowsError(try DocumentStore.load(from: root))
    }

    func testGuideValidationHistoryAndRotatedScreenGeometry() throws {
        let source = try fixture(), editor = try DocumentEditor(document: source)
        try editor.transaction("guide") { $0.guides[0].position = 2 }
        try editor.undo(); XCTAssertTrue(editor.canRedo)
        try editor.transaction("noop") { $0.guides = source.guides }; XCTAssertTrue(editor.canRedo)
        XCTAssertThrowsError(try editor.transaction("nan") { $0.guides[0].position = .nan })
        XCTAssertThrowsError(try editor.transaction("duplicate") { $0.guides.append($0.guides[0]) })
        var viewport = CanvasViewport(); viewport.viewSize = CGSize(width: 600, height: 500); viewport.backingScale = 2
        let size = CGSize(width: 200, height: 100)
        viewport.setZoom(4, anchoredAt: viewport.center, documentSize: size)
        viewport.setRotation(.pi / 3, anchoredAt: viewport.center, documentSize: size)
        let guide = CanvasGuide(axis: .vertical, position: 40), (a, b) = GuideGeometry.segment(guide, viewport: viewport, documentSize: size)
        let middle = viewport.viewPoint(from: CGPoint(x: 40, y: 50), documentSize: size)
        XCTAssertEqual(GuideGeometry.distance(from: middle, to: guide, viewport: viewport, documentSize: size), 0, accuracy: 0.000001)
        let length = hypot(b.x - a.x, b.y - a.y)
        let offset = CGPoint(x: middle.x - (b.y - a.y) / length * 8, y: middle.y + (b.x - a.x) / length * 8)
        XCTAssertEqual(GuideGeometry.distance(from: offset, to: guide, viewport: viewport, documentSize: size), 8, accuracy: 0.000001)
    }

    func testImageResamplingScalesGuideCoordinatesAndCanvasResizeKeepsThem() throws {
        var document = try fixture()
        let original = document.guides
        try DocumentRenderer().resizeCanvas(&document, width: 3, height: 2, resample: true)
        XCTAssertEqual(document.guides.map(\.position), [1.5, 0.75])
        XCTAssertEqual(document.guides.map(\.id), original.map(\.id))
        let scaled = document.guides
        try DocumentRenderer().resizeCanvas(&document, width: 2, height: 2, resample: false)
        XCTAssertEqual(document.guides, scaled)
    }

    func testGuidesNeverChangeCommittedCompositeOrAIInputPixels() throws {
        var document = try fixture(); let before = try pixels(DocumentRenderer().render(document))
        document.guides.append(CanvasGuide(axis: .horizontal, position: 2))
        XCTAssertEqual(try pixels(DocumentRenderer().render(document)), before)
    }
}
