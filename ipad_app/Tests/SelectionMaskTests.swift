import XCTest
import CoreGraphics
@testable import CompositorKit

final class SelectionMaskTests: XCTestCase {
    private func gray(width: Int, height: Int, values: [UInt8], padding: Int = 0) throws -> CGImage {
        XCTAssertEqual(values.count, width * height)
        var rows = [UInt8]()
        for row in 0..<height {
            rows.append(contentsOf: values[row * width..<(row + 1) * width])
            rows.append(contentsOf: Array(repeating: 99, count: padding))
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rows) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width + padding, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func values(_ image: CGImage) throws -> [UInt8] {
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 8)
        XCTAssertEqual(image.alphaInfo, .none)
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        return (0..<image.height).flatMap { row in
            (0..<image.width).map { column in bytes[row * image.bytesPerRow + column] }
        }
    }

    func testRectangleUsesTopLeftCoordinatesAndClipsCanvasEdges() throws {
        let mask = try SelectionMask.rasterize(.rectangle(CGRect(x: 2, y: 1, width: 3, height: 2)), width: 7, height: 5)
        let expected: [UInt8] = (0..<35).map { index in
            let x = index % 7, y = index / 7
            return (2..<5).contains(x) && (1..<3).contains(y) ? 255 : 0
        }
        XCTAssertEqual(try values(mask), expected)
        let reversed = try SelectionMask.rasterize(.rectangle(CGRect(x: 5, y: 3, width: -3, height: -2)), width: 7, height: 5)
        XCTAssertEqual(try values(reversed), expected)
        let clipped = try SelectionMask.rasterize(.rectangle(CGRect(x: -2, y: -1, width: 4, height: 3)), width: 7, height: 5)
        XCTAssertEqual(try values(clipped), (0..<35).map { $0 % 7 < 2 && $0 / 7 < 2 ? 255 : 0 })
    }

    func testEllipseAndPolygonKeepNonSquareOrientationAndEvenOddCrossings() throws {
        let ellipse = try values(SelectionMask.rasterize(.ellipse(CGRect(x: 3, y: 1, width: 6, height: 4)), width: 11, height: 7))
        XCTAssertEqual(ellipse[2 * 11 + 5], 255)
        XCTAssertEqual(ellipse[3 * 11 + 6], 255)
        XCTAssertEqual(ellipse[0], 0)
        XCTAssertEqual(ellipse[5 * 11 + 6], 0)
        XCTAssertGreaterThan(ellipse[1 * 11 + 5], 0)
        let corners = [CGPoint(x: 1, y: 1), CGPoint(x: 7, y: 1), CGPoint(x: 7, y: 5), CGPoint(x: 1, y: 5)]
        let polygon = try SelectionMask.rasterize(.polygon(corners), width: 11, height: 7)
        let rectangle = try SelectionMask.rasterize(.rectangle(CGRect(x: 1, y: 1, width: 6, height: 4)), width: 11, height: 7)
        XCTAssertEqual(try values(polygon), try values(rectangle))
        // Winding would fill a twice-traced outline. Even-odd cancels its overlap.
        let twice = try SelectionMask.rasterize(.polygon(corners + corners), width: 11, height: 7)
        XCTAssertEqual(try values(twice), Array(repeating: 0, count: 77))
    }

    func testCoverageCombinesNumericallyWithoutRepeatedSoftEdgeAccumulation() throws {
        let old = try gray(width: 3, height: 2, values: [0, 64, 128, 192, 255, 128], padding: 2)
        let incoming = try gray(width: 3, height: 2, values: [255, 128, 128, 64, 0, 200], padding: 3)
        let cases: [(SelectionCombineMode, [UInt8])] = [
            (.replace, [255, 128, 128, 64, 0, 200]),
            (.add, [255, 128, 128, 192, 255, 200]),
            (.subtract, [0, 0, 0, 128, 255, 0]),
            (.intersect, [0, 64, 128, 64, 0, 128])
        ]
        for (mode, expected) in cases {
            let combined = try XCTUnwrap(SelectionMask.combine(existing: old, incoming: incoming, mode: mode))
            XCTAssertEqual(try values(combined), expected)
        }
        for mode in [SelectionCombineMode.add, .intersect] {
            let same = try XCTUnwrap(SelectionMask.combine(existing: old, incoming: old, mode: mode))
            XCTAssertEqual(try values(same), try values(old), "128 coverage must remain 128 when a soft edge overlaps itself")
        }
    }

    func testNoSelectionAndExplicitEmptySelectionRemainDifferent() throws {
        let incoming = try gray(width: 3, height: 2, values: [0, 128, 255, 255, 128, 0])
        for mode in [SelectionCombineMode.replace, .add] {
            let created = try XCTUnwrap(SelectionMask.combine(existing: nil, incoming: incoming, mode: mode))
            XCTAssertEqual(try values(created), try values(incoming))
        }
        for mode in [SelectionCombineMode.subtract, .intersect] {
            XCTAssertNil(try SelectionMask.combine(existing: nil, incoming: incoming, mode: mode))
        }
        let black = try gray(width: 3, height: 2, values: Array(repeating: 0, count: 6))
        for mode in [SelectionCombineMode.subtract, .intersect] {
            let empty = try XCTUnwrap(SelectionMask.combine(existing: black, incoming: incoming, mode: mode))
            XCTAssertEqual(try values(empty), Array(repeating: 0, count: 6), "An empty selection must continue to protect every pixel")
        }
    }

    func testFeatherSoftensBothSidesWithClampedCanvasEdges() throws {
        let hard = try SelectionMask.rasterize(.rectangle(CGRect(x: 20, y: 0, width: 20, height: 20)), width: 60, height: 20)
        let soft = try SelectionMask.feather(mask: hard, radius: 6)
        let pixels = try values(soft)
        let row = Array(pixels[10 * 60..<11 * 60])
        XCTAssertGreaterThanOrEqual(row.filter { $0 > 8 && $0 < 247 }.count, 4)
        XCTAssertGreaterThan(row[19], 0, "Feather extends outside the original outline")
        XCTAssertLessThan(row[20], 255, "Feather also softens inside the outline")
        XCTAssertEqual(Int(row[19]) + Int(row[20]), 255, accuracy: 2)
        XCTAssertEqual(row[0], 0)
        XCTAssertGreaterThanOrEqual(row[30], 254)
        XCTAssertEqual(Array(pixels[0..<60]), row, "Clamping avoids dimming a selection that reaches the top or bottom canvas edge")
        let touching = try SelectionMask.rasterize(.rectangle(CGRect(x: 0, y: 0, width: 20, height: 20)), width: 60, height: 20)
        let edge = try values(SelectionMask.feather(mask: touching, radius: 6))
        XCTAssertEqual(edge[0], 255)
    }

    func testFeatherPreservesNumericGrayAndZeroRadiusIsExact() throws {
        let stepped = try gray(width: 3, height: 2, values: [0, 64, 128, 192, 255, 128])
        let unchanged = try SelectionMask.feather(mask: stepped, radius: 0)
        XCTAssertTrue(unchanged === stepped)
        for coverage: UInt8 in [0, 128, 255] {
            let constant = try gray(width: 9, height: 3, values: Array(repeating: coverage, count: 27))
            // Include the ImageIO round-trip, which may attach a gray color profile.
            let decoded = try RasterImage.decode(RasterImage.png(constant))
            let blurred = try values(SelectionMask.feather(mask: decoded, radius: 100))
            XCTAssertEqual(blurred, Array(repeating: coverage, count: 27))
        }
    }

    func testCoverageClipsEditsOnceAndPNGProjectRoundTripPreservesSamples() throws {
        let mask = try gray(width: 3, height: 2, values: [0, 128, 255, 64, 192, 0])
        let combined = try XCTUnwrap(SelectionMask.combine(existing: mask, incoming: mask, mode: .add))
        let context = try RasterImage.context(width: 3, height: 2)
        let rect = CGRect(x: 0, y: 0, width: 3, height: 2)
        RasterImage.clip(combined, to: rect, context: context)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(rect)
        let raw = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual((0..<6).map { raw[$0 * 4 + 3] }, try values(mask), "A 128 selection clips at 128, never 64")
        let feathered = try SelectionMask.feather(mask: combined, radius: 2)
        let encoded = try RasterImage.png(feathered)
        _ = try PNGAsset.inspect(encoded, requireGrayscale: true)
        try bridgeValidatePNG(encoded, size: .init(width: 3, height: 2), mask: true)
        let document = CanvasDocument(width: 3, height: 2, selectionMaskPNGData: encoded)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("selection-" + UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: package) }
        try DocumentStore.save(document, to: package)
        let reopened = try DocumentStore.load(from: package)
        let restored = try RasterImage.decode(XCTUnwrap(reopened.selectionMaskPNGData))
        XCTAssertEqual(try values(restored), try values(feathered))
        XCTAssertEqual(reopened, document)
    }

    func testZeroFeatherAndIdempotentUnionPreserveRevisionAndRedo() throws {
        let mask = try SelectionMask.rasterize(.rectangle(CGRect(x: 2, y: 1, width: 3, height: 2)), width: 8, height: 6)
        let encoded = try RasterImage.png(mask)
        let editor = try DocumentEditor(document: CanvasDocument(width: 8, height: 6, selectionMaskPNGData: encoded))
        try editor.setSelection(nil)
        try editor.undo()
        let before = editor.document
        let zero = try SelectionMask.feather(mask: mask, radius: 0)
        try editor.setSelection(RasterImage.png(zero))
        let same = try XCTUnwrap(SelectionMask.combine(existing: mask, incoming: mask, mode: .add))
        try editor.setSelection(RasterImage.png(same))
        XCTAssertEqual(editor.document, before)
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.canRedo)
    }

    func testRejectsInvalidGeometryRadiusAndIncompatibleMasks() throws {
        for shape in [SelectionShape.rectangle(.zero), .ellipse(CGRect(x: Double.nan, y: 0, width: 2, height: 2)),
                      .polygon([.zero, CGPoint(x: 1, y: 1)]),
                      .polygon([.zero, CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)])] {
            XCTAssertThrowsError(try SelectionMask.rasterize(shape, width: 8, height: 6))
        }
        XCTAssertThrowsError(try SelectionMask.rasterize(.rectangle(CGRect(x: 0, y: 0, width: 1, height: 1)), width: 0, height: 6))
        XCTAssertThrowsError(try SelectionMask.rasterize(.rectangle(CGRect(x: 0, y: 0, width: 1, height: 1)), width: 4097, height: 6))
        let mask = try gray(width: 3, height: 2, values: Array(repeating: 128, count: 6))
        for radius in [-1.0, Double.nan, Double.infinity, 100.1] {
            XCTAssertThrowsError(try SelectionMask.feather(mask: mask, radius: radius))
        }
        let otherSize = try gray(width: 2, height: 3, values: Array(repeating: 128, count: 6))
        XCTAssertThrowsError(try SelectionMask.combine(existing: mask, incoming: otherSize, mode: .add))
        let rgba = try XCTUnwrap(RasterImage.context(width: 3, height: 2).makeImage())
        XCTAssertThrowsError(try SelectionMask.combine(existing: nil, incoming: rgba, mode: .replace))
        XCTAssertThrowsError(try SelectionMask.feather(mask: rgba, radius: 1))
    }
}
