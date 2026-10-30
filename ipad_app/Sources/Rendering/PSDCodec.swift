// PSD record/channel model adapted from Compositor PSDReader.swift / PSDTypes.swift,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
// Writer and strict iPad subset: Adobe Photoshop File Formats Specification (November 2019),
// File Header, Image Resources, Layer and Mask Information, Image Data.
import Foundation
import CoreGraphics

enum PSDCodec {
    static let byteLimit = 256 * 1024 * 1024
    static let sampleLimit = 32_000_000
    private static let recordLimit = 1024
    private static let blendKeys: [LayerBlendMode: String] = [
        .normal: "norm", .multiply: "mul ", .screen: "scrn", .overlay: "over", .darken: "dark", .lighten: "lite",
        .difference: "diff", .exclusion: "smud", .hue: "hue ", .saturation: "sat ", .color: "colr", .luminosity: "lum "]
    private struct Record {
        var id = UUID()
        var name = "图层"
        var rect = CGRect.zero
        var opacity: UInt8 = 255
        var hidden = false, locked = false, clipped = false
        var blend = "norm"
        var section: Int?
        var maskRect: CGRect?
        var maskDefault: UInt8 = 255
        var maskEnabled = true
        var channels: [(id: Int, length: Int)] = []
        var planes: [Int: [UInt8]] = [:]
        /// Prepared numeric coverage summary; never serialized as a PSD field.
        var hasFractionalCoverage = false
    }

    static func matches(_ data: Data) -> Bool { data.prefix(4) == Data("8BPS".utf8) }

    static func read(_ data: Data, name: String = "Photoshop 文稿") throws -> CanvasDocument {
        guard data.count <= byteLimit else { throw PSDFileError.tooLarge }
        var file = PSDReadCursor(data)
        guard try file.ascii(4) == "8BPS" else { throw PSDFileError.invalid("文件签名") }
        guard try file.u16() == 1 else { throw PSDFileError.unsupported("PSB 或其他格式版本") }
        guard try file.bytes(6).allSatisfy({ $0 == 0 }) else { throw PSDFileError.invalid("保留字段非零") }
        let channels = Int(try file.u16()), height = Int(try file.u32()), width = Int(try file.u32())
        guard [3, 4].contains(channels) else { throw PSDFileError.unsupported("附加 Alpha、专色或缺失颜色通道") }
        try sizeCheck(width, height)
        guard try file.u16() == 8 else { throw PSDFileError.unsupported("非 8 位颜色") }
        guard try file.u16() == 3 else { throw PSDFileError.unsupported("非 RGB 颜色模式") }
        guard try file.u32() == 0 else { throw PSDFileError.unsupported("RGB 颜色模式附加数据") }
        var resources = try file.take(Int(try file.u32()))
        var resolution = 72.0, sourceSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var guides: [CanvasGuide] = [], seenResources: Set<Int> = []
        while resources.remaining > 0 {
            guard try resources.ascii(4) == "8BIM" else { throw PSDFileError.invalid("图像资源签名") }
            let id = Int(try resources.u16())
            guard seenResources.insert(id).inserted else { throw PSDFileError.invalid("重复图像资源") }
            let nameLength = Int(try resources.u8()); try resources.skip(nameLength)
            if (nameLength + 1) % 2 != 0 { guard try resources.u8() == 0 else { throw PSDFileError.invalid("资源名称填充") } }
            let length = Int(try resources.u32()); var payload = try resources.take(length)
            switch id {
            case 1005:
                guard length == 16 else { throw PSDFileError.invalid("分辨率资源") }
                resolution = Double(try payload.u32()) / 65536
                let horizontalUnit = try payload.u16(), widthUnit = try payload.u16()
                let vertical = Double(try payload.u32()) / 65536
                let verticalUnit = try payload.u16(), heightUnit = try payload.u16()
                guard resolution.isFinite, (1...9600).contains(resolution), vertical == resolution,
                      horizontalUnit == 1, verticalUnit == 1, (1...5).contains(widthUnit), (1...5).contains(heightUnit) else {
                    throw PSDFileError.unsupported("非方形像素或非像素每英寸的分辨率资源")
                }
            case 1039:
                let profile = try payload.bytes(payload.remaining)
                guard let space = CGColorSpace(iccData: profile as CFData), space.model == .rgb, !space.isHDR() else {
                    throw PSDFileError.unsupported("无效或非 RGB ICC 配置")
                }
                sourceSpace = space
            case 1032: guides = try readGuides(&payload)
            case 1041:
                guard length == 1, try payload.u8() == 0 else { throw PSDFileError.unsupported("刻意未标记的颜色配置") }
            // Known non-rendering UI/preview/XMP resources. They are not native editing records.
            case 1024, 1033, 1036, 1058, 1059, 1060, 1061, 1088: break
            default: throw PSDFileError.unsupported("图像资源 \(id)")
            }
            if length % 2 != 0 { guard try resources.u8() == 0 else { throw PSDFileError.invalid("资源填充") } }
        }
        let sectionLength = Int(try file.u32()); var section = try file.take(sectionLength)
        var raw: [Record] = [], mergedTransparency = false, usedSamples = 0
        if section.remaining > 0 {
            var info = try section.take(Int(try section.u32()))
            if info.remaining > 0 {
                let count = try info.i16(); mergedTransparency = count < 0
                guard abs(count) <= recordLimit else { throw PSDFileError.tooLarge }
                for _ in 0..<abs(count) { raw.append(try readRecord(&info)) }
                // Group bounds are metadata, not a raster allocation size. Validate
                // every empty group channel header before any ordinary plane decodes.
                var channelCheck = info
                for record in raw {
                    for channel in record.channels {
                        if record.section != nil {
                            var empty = try channelCheck.take(channel.length)
                            let compression = try empty.u16()
                            guard compression == 0 || compression == 1 else { throw PSDFileError.unsupported("组空通道压缩方式") }
                            try empty.finish()
                        } else { try channelCheck.skip(channel.length) }
                    }
                }
                for i in raw.indices {
                    if raw[i].section != nil {
                        for channel in raw[i].channels { try info.skip(channel.length) }
                        continue
                    }
                    let imageCount = Int(raw[i].rect.width * raw[i].rect.height)
                    let maskCount = raw[i].maskRect.map { Int($0.width * $0.height) } ?? 0
                    let union = raw[i].maskRect.map { raw[i].rect.union($0) } ?? raw[i].rect
                    try sizeCheck(Int(union.width), Int(union.height), allowEmpty: true)
                    usedSamples += Int(union.width * union.height) * (raw[i].maskRect == nil ? 1 : 2)
                    guard usedSamples <= sampleLimit else { throw PSDFileError.tooLarge }
                    for channel in raw[i].channels {
                        let payload = try info.bytes(channel.length), isMask = channel.id == -2
                        let rect = isMask ? raw[i].maskRect : raw[i].rect
                        guard let rect else { throw PSDFileError.invalid("蒙版通道没有对应矩形") }
                        let plane = try PSDChannelCodec.decode(payload, width: Int(rect.width), height: Int(rect.height))
                        guard plane.count == (isMask ? maskCount : imageCount) else { throw PSDFileError.invalid("通道样本数") }
                        raw[i].planes[channel.id] = plane
                    }
                    raw[i].hasFractionalCoverage = fractionalCoverage(raw[i])
                }
                try info.finish(allowZeroPadding: 1)
            }
            guard section.remaining >= 4, try section.u32() == 0 else { throw PSDFileError.unsupported("全局图层蒙版") }
            if section.remaining >= 12 {
                guard try section.ascii(4) == "8BIM", try section.ascii(4) == "Mtrn", try section.u32() == 0 else {
                    throw PSDFileError.unsupported("全局附加图层信息")
                }
                mergedTransparency = true
            }
            try section.finish(allowZeroPadding: 3)
        }
        if channels == 4, !mergedTransparency { throw PSDFileError.unsupported("未声明为透明度的附加 Alpha 通道") }
        let merged = try readMerged(&file, width: width, height: height, channels: channels, needed: raw.isEmpty, space: sourceSpace)
        try file.finish()
        let canvas = CGSize(width: width, height: height)
        var topFirst: [RasterLayer] = [], stack: [UUID] = [], clipping: Set<UUID> = []
        // PSD stores records bottom-to-top: bounding divider (3), children,
        // then the folder record (1/2). Walk top-to-bottom while assigning parents.
        for record in raw.reversed() {
            if record.section == 3 {
                guard stack.popLast() != nil, record.maskRect == nil, record.planes.values.allSatisfy(\.isEmpty) else { throw PSDFileError.invalid("组边界") }
                continue
            }
            if record.section != nil {
                guard record.blend == "pass", record.opacity == 255, record.maskRect == nil, !record.clipped,
                      record.planes.values.allSatisfy(\.isEmpty), stack.count < 64 else {
                    throw PSDFileError.unsupported("隔离组、组透明度、组蒙版或组像素")
                }
                let layer = RasterLayer(id: record.id, name: record.name, transform: LayerTransform(size: canvas),
                    isVisible: !record.hidden, isLocked: record.locked, parentID: stack.last, isGroup: true)
                topFirst.append(layer); stack.append(layer.id)
            } else {
                let layer = try raster(record, parent: stack.last, canvas: canvas, space: sourceSpace)
                topFirst.append(layer)
                if record.clipped { clipping.insert(layer.id) }
            }
        }
        guard stack.isEmpty else { throw PSDFileError.invalid("图层组没有结束") }
        let siblings = Dictionary(grouping: topFirst, by: \.parentID)
        var layers: [RasterLayer] = []
        func visit(_ parent: UUID?) {
            for layer in (siblings[parent] ?? []).reversed() { layers.append(layer); if layer.isGroup { visit(layer.id) } }
        }
        visit(nil)
        for siblings in Dictionary(grouping: layers.indices, by: { layers[$0].parentID }).values {
            var base: UUID?
            for i in siblings {
                if clipping.contains(layers[i].id) {
                    guard let base, !layers[i].isGroup else { throw PSDFileError.unsupported("剪贴基底缺失或跨组") }
                    layers[i].maskSourceID = base
                } else { base = layers[i].isGroup ? nil : layers[i].id }
            }
        }
        if layers.isEmpty, let merged {
            layers = [RasterLayer(name: "背景", pngData: try RasterImage.png(merged), transform: LayerTransform(size: canvas, sampling: .nearest))]
        }
        let document = CanvasDocument(name: name.isEmpty ? "Photoshop 文稿" : name, width: width, height: height,
            resolution: resolution, layers: layers, activeLayerID: layers.last?.id, guides: guides)
        try document.validate()
        try validateClippingCoverage(document.layers, records: raw)
        return document
    }

    /// Only inspect already-decoded numeric planes; masks are neither color-managed
    /// nor materialized into another canvas merely to determine this capability.
    private static func fractionalCoverage(_ record: Record) -> Bool {
        guard record.opacity > 0, record.rect.width > 0, record.rect.height > 0 else { return false }
        let width = Int(record.rect.width), height = Int(record.rect.height), alpha = record.planes[-1]
        let mask = record.maskEnabled ? record.planes[-2] : nil
        for y in 0..<height { for x in 0..<width {
            let a = alpha?[y * width + x] ?? 255
            guard a > 0 else { continue }
            var m: UInt8 = 255
            if let mask, let rect = record.maskRect {
                let mx = x + Int(record.rect.minX - rect.minX), my = y + Int(record.rect.minY - rect.minY)
                m = mx >= 0 && my >= 0 && mx < Int(rect.width) && my < Int(rect.height)
                    ? mask[my * Int(rect.width) + mx] : record.maskDefault
            }
            if m > 0 && (a < 255 || m < 255 || record.opacity < 255) { return true }
        } }
        return false
    }

    private static func validateClippingCoverage(_ layers: [RasterLayer], records: [Record]) throws {
        let coverage = Dictionary(uniqueKeysWithValues: records.filter { $0.section == nil }.map { ($0.id, $0.hasFractionalCoverage) })
        for layer in layers where layer.maskSourceID != nil && layer.blendMode != .normal {
            guard let base = layer.maskSourceID, let fractional = coverage[base] else { throw PSDFileError.invalid("剪贴基底记录缺失") }
            guard !fractional else {
                throw PSDFileError.unsupported("非正常混合剪贴层与半透明基底的组合（请保留 .comp 工程）")
            }
        }
    }

    private static func readRecord(_ cursor: inout PSDReadCursor) throws -> Record {
        var record = Record()
        record.rect = try readRect(&cursor)
        let count = Int(try cursor.u16()); guard count <= 5 else { throw PSDFileError.unsupported("附加或专色图层通道") }
        var ids: Set<Int> = []
        for _ in 0..<count {
            let id = try cursor.i16(), length = Int(try cursor.u32())
            guard [-2, -1, 0, 1, 2].contains(id), ids.insert(id).inserted, length >= 2, length <= byteLimit else {
                throw PSDFileError.invalid("通道类型、重复或长度")
            }
            record.channels.append((id, length))
        }
        guard try cursor.ascii(4) == "8BIM" else { throw PSDFileError.invalid("图层签名") }
        record.blend = try cursor.ascii(4); record.opacity = try cursor.u8()
        let clipping = try cursor.u8(), flags = try cursor.u8()
        guard clipping <= 1, flags & ~UInt8(31) == 0, try cursor.u8() == 0 else { throw PSDFileError.unsupported("图层标记") }
        record.clipped = clipping == 1; record.hidden = flags & 2 != 0; record.locked = flags & 1 != 0
        var extra = try cursor.take(Int(try cursor.u32()))
        let maskLength = Int(try extra.u32()); var mask = try extra.take(maskLength)
        if maskLength > 0 {
            guard maskLength == 20 else { throw PSDFileError.unsupported("独立蒙版、蒙版密度或羽化参数") }
            let maskRect = try readRect(&mask)
            try sizeCheck(Int(maskRect.width), Int(maskRect.height), allowEmpty: true)
            record.maskRect = maskRect; record.maskDefault = try mask.u8()
            let maskFlags = try mask.u8()
            guard maskFlags & ~UInt8(2) == 0 else { throw PSDFileError.unsupported("相对、反相或渲染蒙版") }
            record.maskEnabled = maskFlags & 2 == 0; try mask.finish(allowZeroPadding: 2)
        }
        if ids.contains(-2) != (record.maskRect != nil) { throw PSDFileError.invalid("蒙版记录与通道不一致") }
        let ranges = try extra.bytes(Int(try extra.u32()))
        if !ranges.isEmpty {
            guard ranges.count % 8 == 0, ranges.count <= 40 else { throw PSDFileError.invalid("混合范围") }
            let values = Array(ranges)
            for i in stride(from: 0, to: values.count, by: 8) {
                guard Array(values[i..<i + 8]) == [0, 0, 255, 255, 0, 0, 255, 255] else { throw PSDFileError.unsupported("混合颜色带") }
            }
        }
        let nameCount = Int(try extra.u8()), nameBytes = try extra.bytes(nameCount)
        record.name = String(data: nameBytes, encoding: .macOSRoman) ?? "图层"
        let pad = (4 - (nameCount + 1) % 4) % 4
        guard try extra.bytes(pad).allSatisfy({ $0 == 0 }) else { throw PSDFileError.invalid("图层名称填充") }
        var seen: Set<String> = []
        while extra.remaining > 0 {
            guard try extra.ascii(4) == "8BIM" else { throw PSDFileError.invalid("附加图层信息签名") }
            let key = try extra.ascii(4), length = Int(try extra.u32())
            guard seen.insert(key).inserted else { throw PSDFileError.invalid("重复附加图层信息") }
            var payload = try extra.take(length)
            switch key {
            case "luni":
                let units = Int(try payload.u32()); guard units > 0, units <= 16_384, payload.remaining == units * 2,
                    let name = String(data: try payload.bytes(units * 2), encoding: .utf16BigEndian) else { throw PSDFileError.invalid("Unicode 图层名称") }
                record.name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            case "lsct", "lsdk":
                guard record.section == nil, [4, 12, 16].contains(length) else { throw PSDFileError.invalid("组分隔记录") }
                let value = Int(try payload.u32()); guard (1...3).contains(value) else { throw PSDFileError.unsupported("图层组类型") }
                record.section = value
                if length >= 12 {
                    guard try payload.ascii(4) == "8BIM" else { throw PSDFileError.invalid("组混合签名") }
                    record.blend = try payload.ascii(4)
                    if length == 16, try payload.u32() != 0 { throw PSDFileError.unsupported("图层组子类型") }
                }
            case "lspf":
                guard length == 4 else { throw PSDFileError.invalid("锁定标记") }
                let bits = try payload.u32(); guard bits & ~UInt32(7) == 0 else { throw PSDFileError.unsupported("图层保护标记") }
                record.locked = record.locked || bits != 0
            case "iOpa": guard length == 1, try payload.u8() == 255 else { throw PSDFileError.unsupported("填充不透明度") }
            case "clbl", "infx", "knko":
                let expected: UInt8 = key == "knko" ? 0 : 1
                guard length == 4, try payload.u8() == expected else { throw PSDFileError.unsupported("特殊剪贴或挖空混合") }
                try payload.finish(allowZeroPadding: 3)
            case "lclr": guard length == 8, try payload.bytes(8).allSatisfy({ $0 == 0 }) else { throw PSDFileError.unsupported("图层颜色标签") }
            case "lyid", "lyvr": guard length == 4 else { throw PSDFileError.invalid("图层编号") }
            case "fxrp": guard length == 16 else { throw PSDFileError.invalid("参考点") }
            default: throw PSDFileError.unsupported("附加图层字段 \(key)（文字、形状、调整、效果或智能对象）")
            }
            if length % 2 != 0 { guard try extra.u8() == 0 else { throw PSDFileError.invalid("附加图层填充") } }
        }
        guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.name.utf8.count <= 16_384 else { throw PSDFileError.invalid("图层名称") }
        if record.section == nil {
            guard flags & 16 == 0 else { throw PSDFileError.unsupported("非栅格图层") }
            try sizeCheck(Int(record.rect.width), Int(record.rect.height), allowEmpty: true)
        } else {
            // Group open/close records may have a nonempty bounding box, but no
            // independent pixels or masks in this subset. Empty channels consist
            // solely of a two-byte compression header, checked before decoding.
            guard record.maskRect == nil, record.channels.allSatisfy({ $0.length == 2 }) else {
                throw PSDFileError.unsupported("图层组记录包含像素通道数据或蒙版")
            }
        }
        return record
    }

    private static func readRect(_ cursor: inout PSDReadCursor) throws -> CGRect {
        let top = try cursor.i32(), left = try cursor.i32(), bottom = try cursor.i32(), right = try cursor.i32()
        guard abs(top) <= 1_000_000, abs(left) <= 1_000_000, abs(bottom) <= 1_000_000, abs(right) <= 1_000_000,
              bottom >= top, right >= left else { throw PSDFileError.invalid("图层矩形") }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func sizeCheck(_ width: Int, _ height: Int, allowEmpty: Bool = false) throws {
        guard width >= (allowEmpty ? 0 : 1), height >= (allowEmpty ? 0 : 1), width <= 4096, height <= 4096,
              width * height <= 16_000_000 else { throw PSDFileError.tooLarge }
    }

    private static func raster(_ record: Record, parent: UUID?, canvas: CGSize, space: CGColorSpace) throws -> RasterLayer {
        guard let blend = blendKeys.first(where: { $0.value == record.blend })?.key else { throw PSDFileError.unsupported("混合模式 \(record.blend)") }
        let width = Int(record.rect.width), height = Int(record.rect.height)
        if width == 0 || height == 0 {
            guard record.maskRect == nil, record.planes.values.allSatisfy(\.isEmpty) else { throw PSDFileError.invalid("空图层的非空资源") }
            return RasterLayer(id: record.id, name: record.name, transform: LayerTransform(size: canvas), isVisible: !record.hidden,
                isLocked: record.locked, opacity: Double(record.opacity) / 255, blendMode: blend, parentID: parent)
        }
        guard let red = record.planes[0], let green = record.planes[1], let blue = record.planes[2] else { throw PSDFileError.invalid("缺少 RGB 通道") }
        let alpha = record.planes[-1] ?? Array(repeating: 255, count: width * height)
        let union = record.maskRect.map { record.rect.union($0) } ?? record.rect
        let outputWidth = Int(union.width), outputHeight = Int(union.height)
        var rgba = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        let dx = Int(record.rect.minX - union.minX), dy = Int(record.rect.minY - union.minY)
        for y in 0..<height { for x in 0..<width {
            let source = y * width + x, target = ((y + dy) * outputWidth + x + dx) * 4
            rgba[target] = red[source]; rgba[target + 1] = green[source]; rgba[target + 2] = blue[source]; rgba[target + 3] = alpha[source]
        } }
        let image = try rgbImage(rgba, width: outputWidth, height: outputHeight, space: space)
        var maskPNG: Data?
        if let maskRect = record.maskRect, let plane = record.planes[-2] {
            var gray = [UInt8](repeating: record.maskDefault, count: outputWidth * outputHeight)
            let maskWidth = Int(maskRect.width), maskHeight = Int(maskRect.height)
            let xOffset = Int(maskRect.minX - union.minX), yOffset = Int(maskRect.minY - union.minY)
            for y in 0..<maskHeight { for x in 0..<maskWidth { gray[(y + yOffset) * outputWidth + x + xOffset] = plane[y * maskWidth + x] } }
            maskPNG = try RasterImage.png(grayImage(gray, width: outputWidth, height: outputHeight))
        }
        return RasterLayer(id: record.id, name: record.name, pngData: try RasterImage.png(image),
            transform: LayerTransform(origin: union.origin, size: union.size, sampling: .nearest), isVisible: !record.hidden,
            isLocked: record.locked, opacity: Double(record.opacity) / 255, blendMode: blend, parentID: parent,
            maskPNGData: maskPNG, maskEnabled: record.maskEnabled)
    }

    private static func readMerged(_ cursor: inout PSDReadCursor, width: Int, height: Int, channels: Int,
                                   needed: Bool, space: CGColorSpace) throws -> CGImage? {
        let compression = try cursor.u16(), count = width * height
        var planes: [[UInt8]] = []
        if compression == 0 {
            guard cursor.remaining == count * channels else { throw PSDFileError.invalid("合成图长度") }
            for _ in 0..<channels { let bytes = try cursor.bytes(count); if needed { planes.append(Array(bytes)) } }
        } else if compression == 1 {
            var rows = [[Int]]()
            for _ in 0..<channels { var lengths: [Int] = []; for _ in 0..<height { lengths.append(Int(try cursor.u16())) }; rows.append(lengths) }
            for lengths in rows {
                var payload = PSDWriteBuffer(); payload.u16(1); for length in lengths { payload.u16(UInt16(length)) }
                payload.bytes(try cursor.bytes(lengths.reduce(0, +)))
                let values = try PSDChannelCodec.decode(payload.data, width: width, height: height)
                if needed { planes.append(values) }
            }
        } else { throw PSDFileError.unsupported("合成图 ZIP 压缩") }
        guard needed else { return nil }
        var rgba = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            if channels == 4 {
                // PSD merged RGB is stored against white, unlike each layer's
                // straight color planes. Recover source colors before converting
                // the declared RGB profile. At alpha zero the color is invisible.
                let alpha = Int(planes[3][i]); rgba[i * 4 + 3] = UInt8(alpha)
                for channel in 0..<3 {
                    let premultiplied = max(0, Int(planes[channel][i]) + alpha - 255)
                    rgba[i * 4 + channel] = alpha == 0 ? 0 : UInt8(min(255, (premultiplied * 255 + alpha / 2) / alpha))
                }
            } else {
                for channel in 0..<channels { rgba[i * 4 + channel] = planes[channel][i] }
            }
        }
        return try rgbImage(rgba, width: width, height: height, space: space)
    }

    private static func rgbImage(_ bytes: [UInt8], width: Int, height: Int, space: CGColorSpace) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RasterError.allocation }
        // The app's working space is sRGB8. Embedded RGB profiles are honored, not discarded.
        let context = try RasterImage.context(width: width, height: height)
        context.setBlendMode(.copy); context.interpolationQuality = .none
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        guard let result = context.makeImage() else { throw RasterError.allocation }
        return result
    }

    private static func grayImage(_ values: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(values) as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RasterError.allocation }
        return image
    }

    private static func readGuides(_ cursor: inout PSDReadCursor) throws -> [CanvasGuide] {
        guard try cursor.u32() == 1, try cursor.u32() == 576, try cursor.u32() == 576 else { throw PSDFileError.unsupported("自定义网格或辅助线版本") }
        let count = Int(try cursor.u32()); guard count <= CanvasGuide.limit, cursor.remaining == count * 5 else { throw PSDFileError.invalid("辅助线记录") }
        var guides: [CanvasGuide] = []
        for _ in 0..<count {
            let position = Double(try cursor.i32()) / 32, axis = try cursor.u8()
            guard axis <= 1 else { throw PSDFileError.invalid("辅助线方向") }
            guides.append(CanvasGuide(axis: axis == 0 ? .vertical : .horizontal, position: position))
        }
        return guides
    }

    /// Integration hook: when editable text/shape/effects are added, reject those records here as well.
    /// A later explicit per-layer raster-copy export can render them without changing the native document.
    static func validateEditableContent(_ layer: RasterLayer) throws {
        guard layer.adjustment == nil else { throw PSDFileError.unsupported("可编辑调整层无法按此 PSD 栅格子集保真导出") }
        guard layer.text == nil, layer.shape == nil, layer.effects == nil else {
            throw PSDFileError.unsupported("可编辑文字、形状或图层效果不属于当前 PSD 保真子集；请使用 .comp 工程保留可编辑内容")
        }
    }

    static func write(_ document: CanvasDocument, renderer: DocumentRenderer = DocumentRenderer()) throws -> Data {
        try document.validate(); try sizeCheck(document.width, document.height)
        guard !document.layers.isEmpty else { throw PSDFileError.unsupported("空图层列表") }
        // Reject unsupported geometry and total allocations before decoding/baking any layer.
        var plannedSamples = 0, plannedRecords = 0
        for layer in document.layers {
            try validateEditableContent(layer)
            if layer.isGroup {
                guard layer.opacity == 1, layer.maskPNGData == nil else { throw PSDFileError.unsupported("组透明度或组蒙版的 iPad 穿透语义") }
                plannedRecords += 2
            } else {
                let bounds = try exportBounds(layer)
                plannedSamples += Int(bounds.width * bounds.height) * (layer.maskPNGData == nil ? 1 : 2)
                plannedRecords += 1
            }
            guard plannedSamples <= sampleLimit, plannedRecords <= recordLimit else { throw PSDFileError.tooLarge }
        }
        var encoded: [(record: Record, channels: [(Int, Data)])] = []
        let siblings = Dictionary(grouping: document.layers, by: \.parentID)
        func emit(_ parent: UUID?) throws {
            for layer in siblings[parent] ?? [] {
                try validateEditableContent(layer)
                if layer.isGroup {
                    guard layer.opacity == 1, layer.maskPNGData == nil else { throw PSDFileError.unsupported("组透明度或组蒙版的 iPad 穿透语义") }
                    // In file order the bounding divider precedes the group's
                    // bottom-to-top children; its named folder record follows them.
                    var boundary = Record(); boundary.name = "</Layer group>"; boundary.section = 3; boundary.blend = "pass"
                    encoded.append((boundary, []))
                    try emit(layer.id)
                    var folder = Record(); folder.id = layer.id; folder.name = layer.name; folder.section = 1; folder.blend = "pass"
                    folder.hidden = !layer.isVisible; folder.locked = layer.isLocked; encoded.append((folder, []))
                } else {
                    let rendered = try exportRaster(layer, renderer: renderer)
                    encoded.append(rendered)
                }
                guard encoded.count <= recordLimit else { throw PSDFileError.tooLarge }
            }
        }
        try emit(nil)
        try validateClippingCoverage(document.layers, records: encoded.map(\.record))
        var info = PSDWriteBuffer(); info.i16(-encoded.count)
        for item in encoded { try writeRecord(item.record, channels: item.channels, into: &info) }
        for item in encoded { for channel in item.channels { info.bytes(channel.1) } }
        if info.data.count % 2 != 0 { info.u8(0) }
        var layerSection = PSDWriteBuffer(); layerSection.section(info.data); layerSection.u32(0)
        additional("Mtrn", payload: Data(), into: &layerSection)
        var merged = try straightPlanes(renderer.render(document))
        // Composite transparency uses white-premixed RGB. Layer channel data
        // remains straight RGB; changing those would corrupt layer recomposition.
        for i in merged[3].indices {
            let alpha = Int(merged[3][i])
            for channel in 0..<3 {
                merged[channel][i] = UInt8((Int(merged[channel][i]) * alpha + 127) / 255 + 255 - alpha)
            }
        }
        var output = PSDWriteBuffer(); output.ascii("8BPS"); output.u16(1); output.zeros(6); output.u16(4)
        output.u32(UInt32(document.height)); output.u32(UInt32(document.width)); output.u16(8); output.u16(3); output.u32(0)
        var resources = PSDWriteBuffer()
        var dpi = PSDWriteBuffer(); dpi.u32(UInt32((document.resolution * 65536).rounded())); dpi.u16(1); dpi.u16(1)
        dpi.u32(UInt32((document.resolution * 65536).rounded())); dpi.u16(1); dpi.u16(1)
        resource(1005, payload: dpi.data, into: &resources)
        if let profile = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() { resource(1039, payload: profile as Data, into: &resources) }
        if !document.guides.isEmpty {
            var guides = PSDWriteBuffer(); guides.u32(1); guides.u32(576); guides.u32(576); guides.u32(UInt32(document.guides.count))
            for guide in document.guides {
                let fixed = guide.position * 32
                guard fixed.isFinite, fixed >= Double(Int32.min), fixed <= Double(Int32.max), fixed.rounded() == fixed else {
                    throw PSDFileError.unsupported("辅助线位置超出 PSD 的 1/32 像素表示范围")
                }
                guides.i32(Int(fixed)); guides.u8(guide.axis == .vertical ? 0 : 1)
            }
            resource(1032, payload: guides.data, into: &resources)
        }
        output.section(resources.data); output.section(layerSection.data); output.u16(0)
        for plane in merged { output.data.append(contentsOf: plane) }
        guard output.data.count <= byteLimit else { throw PSDFileError.tooLarge }
        return output.data
    }

    /// Pure preflight geometry, also exercised at the resource limit without large allocations.
    static func exportBounds(_ layer: RasterLayer) throws -> CGRect {
        var corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(layer.transform.point)
        let axisAligned = layer.transform.rotation.truncatingRemainder(dividingBy: 90) == 0
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0000001 }
        if axisAligned, corners.allSatisfy({ near($0.x, $0.x.rounded()) && near($0.y, $0.y.rounded()) }) {
            // sin/cos at 90-degree multiples can put an integer edge just below
            // zero. Snap the whole exact grid before floor/ceil, never real subpixels.
            corners = corners.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
        }
        let minX = corners.map(\.x).min()!, minY = corners.map(\.y).min()!, maxX = corners.map(\.x).max()!, maxY = corners.map(\.y).max()!
        let margin: CGFloat = axisAligned ? 0 : 1
        let bounds = CGRect(x: floor(minX - margin), y: floor(minY - margin), width: ceil(maxX + margin) - floor(minX - margin), height: ceil(maxY + margin) - floor(minY - margin))
        try sizeCheck(Int(bounds.width), Int(bounds.height))
        if let maskData = layer.maskPNGData {
            // Native masks are multiplied before sampling. Baking a transformed texture and
            // its mask independently would multiply two sampled edges and change coverage.
            // Preserve independent editable masks only on an exact one-to-one pixel grid.
            guard let imageData = layer.pngData else { throw PSDFileError.unsupported("没有像素源的独立蒙版") }
            let source = try PNGAsset.inspect(imageData), mask = try PNGAsset.inspect(maskData, requireGrayscale: true)
            guard axisAligned, near(layer.transform.size.width, CGFloat(source.width)),
                  near(layer.transform.size.height, CGFloat(source.height)), source.width == mask.width,
                  source.height == mask.height, corners.allSatisfy({ near($0.x, $0.x.rounded()) && near($0.y, $0.y.rounded()) }) else {
                throw PSDFileError.unsupported("带独立蒙版的旋转、缩放或亚像素图层；请保留原文稿，或先在副本中栅格化")
            }
        }
        return bounds
    }

    private static func exportRaster(_ layer: RasterLayer, renderer: DocumentRenderer) throws -> (Record, [(Int, Data)]) {
        let bounds = try exportBounds(layer)
        var copy = layer; copy.parentID = nil; copy.maskSourceID = nil; copy.isVisible = true; copy.opacity = 1
        copy.blendMode = .normal; copy.maskPNGData = nil
        let image = try renderer.render(layers: [copy], bounds: bounds), planes = try straightPlanes(image)
        var record = Record(); record.id = layer.id; record.name = layer.name; record.rect = bounds
        record.opacity = UInt8((layer.opacity * 255).rounded()); record.hidden = !layer.isVisible; record.locked = layer.isLocked
        record.clipped = layer.maskSourceID != nil; record.blend = blendKeys[layer.blendMode]!
        var channels = [(0, PSDChannelCodec.raw(planes[0])), (1, PSDChannelCodec.raw(planes[1])), (2, PSDChannelCodec.raw(planes[2])), (-1, PSDChannelCodec.raw(planes[3]))]
        var coverageMask: [UInt8]?
        if let data = layer.maskPNGData {
            let mask = try RasterImage.decode(data), context = try RasterImage.context(width: image.width, height: image.height, gray: true)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            let t = layer.transform
            context.translateBy(x: t.center.x, y: t.center.y); context.rotate(by: t.radians)
            context.scaleBy(x: t.flipX ? -1 : 1, y: t.flipY ? -1 : 1); context.interpolationQuality = t.sampling.quality
            let rect = CGRect(x: -t.size.width / 2, y: -t.size.height / 2, width: t.size.width, height: t.size.height)
            RasterImage.clip(mask, to: rect, context: context); context.setFillColor(gray: 1, alpha: 1); context.fill(rect)
            guard let gray = context.data?.assumingMemoryBound(to: UInt8.self) else { throw RasterError.allocation }
            var values = [UInt8](); values.reserveCapacity(image.width * image.height)
            for y in 0..<image.height { for x in 0..<image.width { values.append(gray[y * context.bytesPerRow + x]) } }
            record.maskRect = bounds; record.maskDefault = 0; record.maskEnabled = layer.maskEnabled
            channels.append((-2, PSDChannelCodec.raw(values)))
            if layer.maskEnabled { coverageMask = values }
        }
        // Use the prepared transformed alpha and numeric mask directly, retaining
        // the original Double opacity so 0.999 cannot round to an apparently opaque base.
        if layer.opacity > 0 {
            record.hasFractionalCoverage = planes[3].indices.contains { i in
                let a = planes[3][i], m = coverageMask?[i] ?? 255
                return a > 0 && m > 0 && (a < 255 || m < 255 || layer.opacity < 1)
            }
        }
        return (record, channels)
    }

    static func straightPlanes(_ image: CGImage) throws -> [[UInt8]] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw RasterError.allocation }
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw RasterError.allocation }
        var planes = Array(repeating: [UInt8](repeating: 0, count: image.width * image.height), count: 4)
        for y in 0..<image.height { for x in 0..<image.width {
            let p = y * context.bytesPerRow + x * 4, i = y * image.width + x, a = Int(pixels[p + 3])
            planes[3][i] = UInt8(a)
            if a > 0 { for c in 0..<3 { planes[c][i] = UInt8(min(255, (Int(pixels[p + c]) * 255 + a / 2) / a)) } }
        } }
        return planes
    }

    private static func writeRecord(_ record: Record, channels: [(Int, Data)], into output: inout PSDWriteBuffer) throws {
        writeRect(record.rect, into: &output); output.u16(UInt16(channels.count))
        for channel in channels { output.i16(channel.0); output.u32(UInt32(channel.1.count)) }
        output.ascii("8BIM"); output.ascii(record.blend); output.u8(record.opacity); output.u8(record.clipped ? 1 : 0)
        output.u8((record.hidden ? 2 : 0) | (record.locked ? 1 : 0)); output.u8(0)
        var extra = PSDWriteBuffer()
        if let mask = record.maskRect {
            extra.u32(20); writeRect(mask, into: &extra); extra.u8(record.maskDefault); extra.u8(record.maskEnabled ? 0 : 2); extra.zeros(2)
        } else { extra.u32(0) }
        extra.u32(0)
        let fallback = Data("Layer".utf8); extra.u8(UInt8(fallback.count)); extra.bytes(fallback)
        extra.zeros((4 - (fallback.count + 1) % 4) % 4)
        var name = PSDWriteBuffer(); name.u32(UInt32(record.name.utf16.count))
        for unit in record.name.utf16 { name.u16(unit) }
        additional("luni", payload: name.data, into: &extra)
        if record.section == nil {
            // Adobe clbl: Blend Clipped Layers As Group, the only accepted semantics.
            additional("clbl", payload: Data([1, 0, 0, 0]), into: &extra)
        }
        if let section = record.section {
            var payload = PSDWriteBuffer(); payload.u32(UInt32(section)); payload.ascii("8BIM"); payload.ascii("pass")
            additional("lsct", payload: payload.data, into: &extra)
        }
        if record.locked { var lock = PSDWriteBuffer(); lock.u32(7); additional("lspf", payload: lock.data, into: &extra) }
        output.section(extra.data)
    }

    private static func writeRect(_ rect: CGRect, into output: inout PSDWriteBuffer) {
        output.i32(Int(rect.minY)); output.i32(Int(rect.minX)); output.i32(Int(rect.maxY)); output.i32(Int(rect.maxX))
    }
    private static func additional(_ key: String, payload: Data, into output: inout PSDWriteBuffer) {
        output.ascii("8BIM"); output.ascii(key); output.section(payload); if payload.count % 2 != 0 { output.u8(0) }
    }
    private static func resource(_ id: UInt16, payload: Data, into output: inout PSDWriteBuffer) {
        output.ascii("8BIM"); output.u16(id); output.zeros(2); output.section(payload); if payload.count % 2 != 0 { output.u8(0) }
    }
}
