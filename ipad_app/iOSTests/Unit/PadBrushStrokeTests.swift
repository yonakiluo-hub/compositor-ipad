import XCTest
import UIKit
@testable import CompositorPad

final class PadBrushStrokeTests: XCTestCase {
    private func sample(_ x: CGFloat = 16, _ y: CGFloat = 16, pressure: CGFloat = 1,
                        altitude: CGFloat = .pi / 2) -> BrushSample {
        BrushSample(point: CGPoint(x: x, y: y), pressure: pressure, altitude: altitude, azimuth: 0)
    }
    private func settings(opacity: CGFloat = 1, erasing: Bool = false) -> PadBrushSettings {
        PadBrushSettings(diameter: 20, hardness: 1, opacity: opacity, color: .red, erasing: erasing)
    }
    private func pixel(_ image: CGImage, x: Int = 16, y: Int = 16) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
        return (0..<(image.bitsPerPixel / 8)).map { bytes[offset + $0] }
    }
    private func solid(alpha: CGFloat) throws -> CGImage {
        let context = try RasterImage.context(width: 32, height: 32)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return try XCTUnwrap(context.makeImage())
    }
    private func gray(_ value: CGFloat) throws -> CGImage {
        let context = try RasterImage.context(width: 32, height: 32, gray: true)
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return try XCTUnwrap(context.makeImage())
    }

    func testRepeatedDabsCapOpacityAndRepeatedPreviewsDoNotAccumulate() throws {
        let stroke = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(opacity: 0.5), selection: nil, maskMode: false)
        for _ in 0..<20 { stroke.add(sample()) }
        let first = try stroke.image(), second = try stroke.image()
        XCTAssertEqual(try pixel(first)[3], 128, accuracy: 1)
        XCTAssertEqual(try pixel(first), try pixel(second))
        XCTAssertEqual(try pixel(first, x: 0, y: 0)[3], 0)
    }

    func testEraserAndSoftSelectionEachApplyOnce() throws {
        let erase = try PadBrushStroke(width: 32, height: 32, original: solid(alpha: 1), settings: settings(opacity: 0.5, erasing: true), selection: nil, maskMode: false)
        erase.add(sample())
        XCTAssertEqual(try pixel(erase.image())[3], 128, accuracy: 1)
        let paint = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(opacity: 0.5), selection: gray(0.5), maskMode: false)
        paint.add(sample())
        XCTAssertEqual(try pixel(paint.image())[3], 64, accuracy: 1)
    }

    func testMaskPaintingUsesNumericGrayscaleWithoutAlpha() throws {
        let stroke = try PadBrushStroke(width: 32, height: 32, original: gray(0), settings: settings(opacity: 0.5), selection: nil, maskMode: true)
        stroke.add(sample())
        let mask = try stroke.image()
        XCTAssertEqual(mask.bitsPerPixel, 8)
        XCTAssertEqual(mask.alphaInfo, .none)
        XCTAssertEqual(try pixel(mask)[0], 128, accuracy: 1)
        XCTAssertNoThrow(try bridgeValidatePNG(RasterImage.png(mask), size: BridgePixelSize(width: 32, height: 32), mask: true))
    }

    func testSavedSelectionCropUploadsAsProfileFreeNumericMask() throws {
        let context = try RasterImage.context(width: 32, height: 24, gray: true)
        for (x, width, value) in [(0, 10, 0.0), (10, 10, 128.0 / 255), (20, 12, 1.0)] {
            context.setFillColor(gray: value, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: width, height: 24))
        }
        let saved = try RasterImage.png(XCTUnwrap(context.makeImage()))
        let decoded = try RasterImage.decode(saved)
        let crop = try XCTUnwrap(decoded.cropping(to: CGRect(x: 8, y: 5, width: 16, height: 12)))
        let upload = try RasterImage.png(crop)
        try bridgeValidatePNG(upload, size: .init(width: 16, height: 12), mask: true)
        let reopened = try RasterImage.decode(upload)
        XCTAssertEqual(reopened.bitsPerPixel, 8)
        XCTAssertEqual(reopened.alphaInfo, .none)
        XCTAssertEqual(try pixel(reopened, x: 0, y: 0)[0], 0)
        XCTAssertEqual(try pixel(reopened, x: 4, y: 0)[0], 128)
        XCTAssertEqual(try pixel(reopened, x: 14, y: 0)[0], 255)
    }

    func testPressureChangesCoverageAndTiltBroadensTip() throws {
        let light = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(), selection: nil, maskMode: false)
        let heavy = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(), selection: nil, maskMode: false)
        light.add(sample(pressure: 0.1)); heavy.add(sample())
        XCTAssertEqual(try pixel(light.image(), x: 23, y: 16)[3], 0)
        XCTAssertGreaterThan(try pixel(heavy.image(), x: 23, y: 16)[3], 200)
        let tilted = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(), selection: nil, maskMode: false)
        tilted.add(sample(altitude: 0.1))
        XCTAssertEqual(try pixel(heavy.image(), x: 16, y: 29)[3], 0)
        XCTAssertGreaterThan(try pixel(tilted.image(), x: 16, y: 29)[3], 200)
    }

    func testTransformedLayerKeepsBrushFootprintInDocumentCoordinates() throws {
        let scaled = try PadBrushStroke(width: 64, height: 64, original: nil, settings: settings(), selection: nil,
            maskMode: false, brushToPixels: CGAffineTransform(scaleX: 2, y: 0.5))
        scaled.add(sample(32, 32))
        XCTAssertGreaterThan(try pixel(scaled.image(), x: 48, y: 32)[3], 200)
        XCTAssertEqual(try pixel(scaled.image(), x: 32, y: 40)[3], 0)
        let rotated = try PadBrushStroke(width: 64, height: 64, original: nil, settings: settings(), selection: nil,
            maskMode: false, brushToPixels: CGAffineTransform(rotationAngle: -.pi / 2))
        rotated.add(sample(32, 32, altitude: 0.1))
        XCTAssertGreaterThan(try pixel(rotated.image(), x: 45, y: 32)[3], 200)
        XCTAssertEqual(try pixel(rotated.image(), x: 32, y: 45)[3], 0)
    }
}
