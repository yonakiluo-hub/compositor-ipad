import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import CompositorKit

final class ImageFileWorkflowTests: XCTestCase {
    private func image(width: Int = 3, height: Int = 2) throws -> CGImage {
        var pixels: [UInt8] = []
        for i in 0..<(width * height) { pixels.append(contentsOf: [UInt8(i * 13), UInt8(100 + i), UInt8(20 + i), i == 0 ? 0 : 255]) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixels(_ image: CGImage) throws -> [[UInt8]] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none; context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { i in Array(UnsafeBufferPointer(start: bytes + i * 4, count: 4)) }
    }
    func testTransparentTIFFRoundTripAndResolution() throws {
        let original = try image(), data = try ImageFileCodec.tiff(original, resolution: 144)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(metadata[kCGImagePropertyDPIWidth] as? Double, 144)
        let decoded = try ImageFileCodec.decode(data)
        XCTAssertEqual(decoded.width, 3); XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(try pixels(original), try pixels(decoded))
        XCTAssertThrowsError(try ImageFileCodec.tiff(original, resolution: .nan))
    }
    func testAllEXIFOrientationsNormalizeDimensionsAndDistinctRows() throws {
        let original = try image(), before = try pixels(original)
        let expected = [[0, 1, 2, 3, 4, 5], [2, 1, 0, 5, 4, 3], [5, 4, 3, 2, 1, 0], [3, 4, 5, 0, 1, 2],
                        [0, 3, 1, 4, 2, 5], [3, 0, 4, 1, 5, 2], [5, 2, 4, 1, 3, 0], [2, 5, 1, 4, 0, 3]]
        for orientation in 1...8 {
            let data = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let decoded = try ImageFileCodec.decode(data as Data)
            XCTAssertEqual(decoded.width, orientation >= 5 ? 2 : 3); XCTAssertEqual(decoded.height, orientation >= 5 ? 3 : 2)
            XCTAssertEqual(try pixels(decoded), expected[orientation - 1].map { before[$0] }, "EXIF \(orientation)")
        }
    }
    func testMultiPageAndHighDepthRejectBeforeRasterConversion() throws {
        let data = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 2, nil))
        let source = try image(); CGImageDestinationAddImage(destination, source, nil); CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); XCTAssertThrowsError(try ImageFileCodec.decode(data as Data))
        let values = Data([0, 0, 255, 255]), provider = try XCTUnwrap(CGDataProvider(data: values as CFData))
        let deep = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Big.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let deepPNG = try RasterImage.png(deep)
        XCTAssertThrowsError(try ImageFileCodec.decode(deepPNG))
    }
    func testImageOnlyPDFHasOnePageAndDocumentPhysicalSize() throws {
        let source = try image(), data = try ImageFileCodec.pdf(source, resolution: 144)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData)), pdf = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(pdf.numberOfPages, 1)
        let page = try XCTUnwrap(pdf.page(at: 1))
        XCTAssertEqual(page.getBoxRect(.mediaBox), CGRect(x: 0, y: 0, width: 1.5, height: 1))
        XCTAssertThrowsError(try ImageFileCodec.pdf(source, resolution: .nan))
    }
    func testFileSizeIsPreflightedWithoutLoadingSparsePayload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let file = try FileHandle(forWritingTo: url); try file.truncate(atOffset: UInt64(ImageFileCodec.byteLimit + 1)); try file.close()
        XCTAssertThrowsError(try ImageFileCodec.data(from: url))
        XCTAssertThrowsError(try ImageFileCodec.decode(Data("not an image".utf8)))
        XCTAssertFalse(ImageFileCodec.importTypes.contains { $0.identifier == "com.adobe.photoshop-image" }, "Layered PSD must not pass through flat image decoding")
    }
}
