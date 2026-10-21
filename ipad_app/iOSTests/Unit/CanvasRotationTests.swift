import XCTest
import UIKit
@testable import CompositorPad

final class CanvasRotationTests: XCTestCase {
    private let imageSize = CGSize(width: 96, height: 64)
    private let quadrantColors: [[UInt8]] = [
        [240, 32, 48, 255], [32, 224, 64, 255],
        [48, 64, 240, 255], [224, 192, 32, 255]
    ]
    private let coverage: [UInt8] = [0, 85, 170, 255]
    private let samplePoints = [
        CGPoint(x: 24, y: 16), CGPoint(x: 72, y: 16),
        CGPoint(x: 24, y: 48), CGPoint(x: 72, y: 48)
    ]

    /// Only the location and type consumed by the canvas are synthetic. The
    /// test still exercises its public UIKit touch callbacks and private mapping.
    @MainActor
    private final class LocatedTouch: UITouch {
        var point = CGPoint.zero
        override var type: UITouch.TouchType { .direct }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private func sourceImage() throws -> CGImage {
        var pixels = [UInt8]()
        for y in 0..<64 {
            for x in 0..<96 {
                pixels.append(contentsOf: quadrantColors[(y < 32 ? 0 : 2) + (x < 48 ? 0 : 1)])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: 96, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func selectionImage() throws -> CGImage {
        var pixels = [UInt8]()
        for y in 0..<64 {
            for x in 0..<96 {
                pixels.append(coverage[(y < 32 ? 0 : 2) + (x < 48 ? 0 : 1)])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: 96, height: 64, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 96, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @MainActor
    private func fixture(selection: Bool = false) throws -> (EditorModel, PadCanvasView) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-rotation-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let suite = "canvas-rotation-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let layer = RasterLayer(name: "合成四色", pngData: try RasterImage.png(sourceImage()),
                                transform: LayerTransform(size: imageSize, sampling: .nearest))
        let document = CanvasDocument(name: "旋转画布测试", width: 96, height: 64, layers: [layer],
            activeLayerID: layer.id, selectionMaskPNGData: selection ? try RasterImage.png(selectionImage()) : nil)
        try DocumentStore.save(document, to: documents.appendingPathComponent(document.id.uuidString.lowercased() + ".comp"))
        preferences.set(document.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: documents, supportURL: root.appendingPathComponent("Support"),
                                preferences: preferences, loadPairing: false)
        let canvas = PadCanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 480, height: 400)
        canvas.overrideUserInterfaceStyle = .light
        canvas.layoutIfNeeded()
        canvas.update()
        addTeardownBlock {
            await MainActor.run {
                model.suspend()
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.pairing)
        return (model, canvas)
    }

    @MainActor
    private func setViewport(_ canvas: PadCanvasView, angle: CGFloat, pointsPerPixel: CGFloat) {
        canvas.viewport.resize(to: canvas.bounds.size, backingScale: 2, documentSize: imageSize)
        canvas.viewport.setZoom(pointsPerPixel * 2, anchoredAt: canvas.viewport.center, documentSize: imageSize)
        canvas.viewport.setRotation(angle, anchoredAt: canvas.viewport.center, documentSize: imageSize)
        canvas.viewport.pan = CGSize(width: 13, height: -17)
    }

    @MainActor
    private func render(_ canvas: PadCanvasView) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var result: CGImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            result = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { _ in
                canvas.draw(canvas.bounds)
            }.cgImage
        }
        return try XCTUnwrap(result)
    }

    /// Normalize UIKit's potentially BGRA backing into known RGBA bytes. A
    /// default bitmap context preserves CGImage row order; no viewport code is used.
    private func rgba(_ image: CGImage, at point: CGPoint) throws -> [UInt8] {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard (0..<image.width).contains(x), (0..<image.height).contains(y) else {
            XCTFail("Sample point must remain inside the rendered view")
            return [0, 0, 0, 0]
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (0..<4).map { bytes[offset + $0] }
    }

    private func assertPixel(_ actual: [UInt8], equals expected: [UInt8], accuracy: Double = 3,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, 4, file: file, line: line)
        for channel in 0..<4 {
            XCTAssertEqual(Double(actual[channel]), Double(expected[channel]), accuracy: accuracy,
                           "RGBA channel \(channel)", file: file, line: line)
        }
    }

    @MainActor
    func testInitialFitContinuesToFitAfterOrientationChanges() throws {
        let (model, canvas) = try fixture()
        let before = model.document
        XCTAssertTrue(canvas.viewport.followsFit)
        canvas.frame = CGRect(x: 0, y: 0, width: 280, height: 600)
        canvas.setNeedsLayout(); canvas.layoutIfNeeded()
        let rect = canvas.viewport.documentRect(imageSize)
        XCTAssertGreaterThanOrEqual(rect.minX, 47.9)
        XCTAssertLessThanOrEqual(rect.maxX, canvas.bounds.width - 47.9)
        XCTAssertGreaterThanOrEqual(rect.minY, 47.9)
        XCTAssertLessThanOrEqual(rect.maxY, canvas.bounds.height - 47.9)
        XCTAssertTrue(canvas.viewport.followsFit)
        XCTAssertEqual(model.document, before)
        XCTAssertFalse(model.editor.canUndo)
    }

    @MainActor
    func testNativeCanvasDrawKeepsAsymmetricPixelsInTheirRotatedDocumentPositions() throws {
        let (model, canvas) = try fixture()
        let before = model.document
        let source = try sourceImage()
        for (index, point) in samplePoints.enumerated() {
            assertPixel(try rgba(source, at: point), equals: quadrantColors[index])
        }
        for angle in [CGFloat.zero, CGFloat.pi / 2, -CGFloat.pi / 2, CGFloat.pi * 0.37] {
            for scale in [CGFloat(1.5), 3] {
                setViewport(canvas, angle: angle, pointsPerPixel: scale)
                let image = try render(canvas)
                for (index, documentPoint) in samplePoints.enumerated() {
                    let screenPoint = canvas.viewport.viewPoint(from: documentPoint, documentSize: imageSize)
                    assertPixel(try rgba(image, at: screenPoint), equals: quadrantColors[index])
                }
            }
        }
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, 0, "View navigation must not edit pixels or history")
    }

    @MainActor
    func testGraySelectionOverlayRotatesWithPixelsAndRetainsItsCoverage() throws {
        let (model, canvas) = try fixture(selection: true)
        let before = model.document
        let teal = try XCTUnwrap(UIColor.systemTeal.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components)
        for angle in [CGFloat.zero, CGFloat.pi / 2, -CGFloat.pi * 0.31] {
            setViewport(canvas, angle: angle, pointsPerPixel: 3)
            let image = try render(canvas)
            for (index, documentPoint) in samplePoints.enumerated() {
                let alpha = 0.28 * Double(coverage[index]) / 255
                let expected = (0..<3).map { channel in
                    UInt8((Double(quadrantColors[index][channel]) * (1 - alpha)
                        + Double(teal[channel]) * 255 * alpha).rounded())
                } + [255]
                let screenPoint = canvas.viewport.viewPoint(from: documentPoint, documentSize: imageSize)
                assertPixel(try rgba(image, at: screenPoint), equals: expected, accuracy: 4)
            }
        }
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, 0)
    }

    @MainActor
    func testCanvasTouchCallbacksPickTheDocumentPixelUnderRotatedViewLocation() throws {
        let (model, canvas) = try fixture()
        let before = model.document
        model.tool = .eyedropper
        model.fingerDrawing = true
        for angle in [CGFloat.pi / 2, -CGFloat.pi / 3] {
            setViewport(canvas, angle: angle, pointsPerPixel: 2.5)
            for (index, documentPoint) in samplePoints.enumerated() {
                let touch = LocatedTouch()
                touch.point = canvas.viewport.viewPoint(from: documentPoint, documentSize: imageSize)
                canvas.touchesBegan([touch], with: nil)
                canvas.touchesEnded([touch], with: nil)
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(UIColor(model.color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                let actual = [red, green, blue, alpha].map { UInt8(($0 * 255).rounded()) }
                assertPixel(actual, equals: quadrantColors[index])
            }
        }
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, 0)
    }

    func testTransformHandlesKeep24PointHitToleranceAcrossZoomAndCanvasRotation() throws {
        let size = CGSize(width: 1200, height: 900)
        let transform = LayerTransform(origin: CGPoint(x: 300, y: 240),
            size: CGSize(width: 600, height: 420), rotation: 23, flipX: true)
        for zoom in [CGFloat(0.5), 1, 4] {
            for angle in [CGFloat.zero, CGFloat.pi / 2, -CGFloat.pi * 0.4] {
                var viewport = CanvasViewport()
                viewport.resize(to: CGSize(width: 1024, height: 768), backingScale: 2, documentSize: size)
                viewport.setZoom(zoom, anchoredAt: viewport.center, documentSize: size)
                viewport.setRotation(angle, anchoredAt: viewport.center, documentSize: size)
                viewport.translate(by: CGSize(width: 43, height: -19))
                let geometry = TransformOverlayGeometry(transform: transform, viewport: viewport, documentSize: size)
                XCTAssertEqual(geometry.handles.count, 8)
                let combinedAngle = transform.radians + angle
                for (handle, point) in geometry.handles {
                    let unit = try XCTUnwrap(handle.unitPoint)
                    var outward = CGPoint(x: unit.x * 2 - 1, y: unit.y * 2 - 1)
                    // The rotation knob is 36 pt beyond top: test the top handle
                    // diagonally outside its edge, away from the knob's hit circle.
                    if handle == .top { outward = CGPoint(x: sqrt(CGFloat(3)) / 2, y: -0.5) }
                    let length = hypot(outward.x, outward.y)
                    let direction = CGPoint(x: (outward.x * cos(combinedAngle) - outward.y * sin(combinedAngle)) / length,
                                            y: (outward.x * sin(combinedAngle) + outward.y * cos(combinedAngle)) / length)
                    for distance in [CGFloat(0), 23.5, 24.5] {
                        let hitPoint = CGPoint(x: point.x + direction.x * distance, y: point.y + direction.y * distance)
                        let documentPoint = viewport.documentPoint(from: hitPoint, documentSize: size)
                        let result = geometry.hit(hitPoint, documentPoint: documentPoint, transform: transform)
                        if distance < 24 { XCTAssertEqual(result, handle) }
                        else { XCTAssertNil(result, "Outside the fixed hit radius and outside the layer") }
                    }
                }
                let center = viewport.viewPoint(from: transform.center, documentSize: size)
                XCTAssertEqual(geometry.hit(center, documentPoint: transform.center, transform: transform), .translate)
            }
        }
    }

    func testRotationHandleFollowsCombinedAngleAndStays36ScreenPointsFromTop() {
        let size = CGSize(width: 1200, height: 900)
        let transform = LayerTransform(origin: CGPoint(x: 300, y: 240),
            size: CGSize(width: 600, height: 420), rotation: -31)
        for zoom in [CGFloat(0.5), 2, 8] {
            for angle in [CGFloat.zero, CGFloat.pi / 2, -CGFloat.pi / 3] {
                var viewport = CanvasViewport()
                viewport.resize(to: CGSize(width: 1024, height: 768), backingScale: 2, documentSize: size)
                viewport.setZoom(zoom, anchoredAt: viewport.center, documentSize: size)
                viewport.setRotation(angle, anchoredAt: viewport.center, documentSize: size)
                let geometry = TransformOverlayGeometry(transform: transform, viewport: viewport, documentSize: size)
                let combinedAngle = transform.radians + angle
                let outward = CGPoint(x: sin(combinedAngle), y: -cos(combinedAngle))
                XCTAssertEqual(geometry.rotationHandle.x - geometry.top.x, outward.x * 36, accuracy: 0.000001)
                XCTAssertEqual(geometry.rotationHandle.y - geometry.top.y, outward.y * 36, accuracy: 0.000001)
                for distance in [CGFloat(0), 23.5, 24.5] {
                    let point = CGPoint(x: geometry.rotationHandle.x + outward.x * distance,
                                        y: geometry.rotationHandle.y + outward.y * distance)
                    let documentPoint = viewport.documentPoint(from: point, documentSize: size)
                    let result = geometry.hit(point, documentPoint: documentPoint, transform: transform)
                    if distance < 24 { XCTAssertEqual(result, .rotate) }
                    else { XCTAssertNil(result) }
                }
            }
        }
    }
}
