// ImageIO import, EXIF normalization and TIFF/PDF export adapted from Compositor
// ImageImporter.swift / ImageExporter.swift, 365b5745eda537f984f3d5bed1e53c361dbc9c91.
// MIT © 2026 Wonder Assembly LLC. Strict depth/frame preflight is an iPad adaptation.
import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers

enum ImageFileError: LocalizedError {
    case unsupported(String)
    var errorDescription: String? {
        switch self { case .unsupported(let reason): "无法无损导入此图片：\(reason)。请另存为单帧 8 位 RGB 图片，原文件未修改。" }
    }
}

enum ImageFileCodec {
    static let byteLimit = 256 * 1024 * 1024
    static var importTypes: [UTType] {
        let supported = Set(CGImageSourceCopyTypeIdentifiers() as! [String])
        return [UTType.png, .jpeg, .heic, .heif, .tiff, UTType(importedAs: "org.webmproject.webp")]
            .filter { supported.contains($0.identifier) }
    }
    static func data(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= byteLimit else { throw RasterError.oversized }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= byteLimit, let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary), let type = CGImageSourceGetType(source) as String?,
              importTypes.contains(where: { $0.identifier == type }) else { throw RasterError.invalidImage }
        guard CGImageSourceGetCount(source) == 1 else { throw ImageFileError.unsupported("动画或多页图片需要先选择并另存一帧") }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 16_000_000 else { throw RasterError.oversized }
        guard let depth = properties[kCGImagePropertyDepth] as? Int, depth > 0, depth <= 8 else {
            throw ImageFileError.unsupported("16/32 位或 HDR 颜色，不能静默降精度")
        }
        guard CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) == nil else {
            throw ImageFileError.unsupported("HDR 增益图，不能静默转为 SDR")
        }
        if #available(iOS 18, macOS 15, *) {
            guard CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) == nil else {
                throw ImageFileError.unsupported("ISO HDR 增益图，不能静默转为 SDR")
            }
        }
        let model = properties[kCGImagePropertyColorModel] as? String
        guard model == "RGB" || model == "Gray" || model == "Indexed" else { throw ImageFileError.unsupported("CMYK 或其他颜色模式") }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int32) ?? 1
        guard (1...8).contains(orientation), let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw RasterError.invalidImage }
        if let space = image.colorSpace, space.isHDR() { throw ImageFileError.unsupported("HDR 颜色空间") }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let extent = oriented.extent.integral
        let normalized = oriented.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let rect = CGRect(origin: .zero, size: extent.size)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let result = context.createCGImage(normalized, from: rect, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw RasterError.invalidImage }
        return result
    }

    static func tiff(_ image: CGImage, resolution: Double) throws -> Data {
        guard resolution.isFinite, (1...9600).contains(resolution) else { throw DocumentError.invalid("导出分辨率") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else { throw RasterError.encoding }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: resolution, kCGImagePropertyDPIHeight: resolution,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RasterError.encoding }
        return data as Data
    }

    /// One raster page at document resolution. It is not an editable vector PDF or layered PSD.
    static func pdf(_ image: CGImage, resolution: Double) throws -> Data {
        guard resolution.isFinite, (1...9600).contains(resolution) else { throw DocumentError.invalid("导出分辨率") }
        var page = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / resolution, height: Double(image.height) * 72 / resolution)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw RasterError.encoding }
        context.beginPDFPage(nil); context.draw(image, in: page); context.endPDFPage(); context.closePDF()
        return data as Data
    }
}
