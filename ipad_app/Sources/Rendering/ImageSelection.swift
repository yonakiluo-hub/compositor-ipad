// Adapted from Compositor MagicWand.swift, WandPixels.c and ObjectSelection.swift.
// MIT © 2026 Wonder Assembly LLC; upstream 365b5745eda537f984f3d5bed1e53c361dbc9c91.
// iPad stores numeric coverage directly instead of tracing millions of path edges.
import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import Vision

struct ImageSelectionSettings: Equatable, Sendable {
    var tolerance = 32
    var sampleRadius = 0
    var contiguous = true
    var sampleAllLayers = true
    var isValid: Bool { (0...255).contains(tolerance) && (0...2).contains(sampleRadius) }
}

enum ImageSelectionError: LocalizedError {
    case outside, noSubject, unavailable, invalid
    var errorDescription: String? {
        switch self {
        case .outside: "请在画布内选择取样点。"
        case .noSubject: "没有检测到可选主体；请换一个对象或使用魔棒。"
        case .unavailable: "此设备当前无法进行主体识别；原选区保留，可改用魔棒。"
        case .invalid: "图像选区参数无效。"
        }
    }
}

enum ImageSelectionRaster {
    static func wand(_ image: CGImage, at point: CGPoint, settings: ImageSelectionSettings) throws -> CGImage {
        guard settings.isValid else { throw ImageSelectionError.invalid }
        let width = image.width, height = image.height
        try NumericSelectionRaster.check(width, height)
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < CGFloat(width), point.y < CGFloat(height) else { throw ImageSelectionError.outside }
        let pixels = try NumericSelectionRaster.rgba(image), x = Int(point.x), y = Int(point.y)
        let radius = settings.sampleRadius
        var reference = [Int](repeating: 0, count: 4), count = 0
        for row in max(0,y-radius)...min(height-1,y+radius) {
            for column in max(0,x-radius)...min(width-1,x+radius) {
                count += 1
                for channel in 0..<4 { reference[channel] += Int(pixels[(row*width+column)*4+channel]) }
            }
        }
        for channel in 0..<4 { reference[channel] = (reference[channel]+count/2)/count }
        func matches(_ index: Int) -> Bool {
            for channel in 0..<4 where abs(Int(pixels[index*4+channel])-reference[channel]) > settings.tolerance { return false }
            return true
        }
        var selected = [UInt8](repeating: 0, count: width*height)
        if !settings.contiguous {
            for index in selected.indices where matches(index) { selected[index] = 255 }
        } else {
            // Scanline flood fill follows WandPixels.c. A compact index stack is
            // bounded independently of image decoding to avoid unbounded queues.
            var stack = [UInt32(y*width+x)]
            while let next = stack.popLast() {
                let index = Int(next), row = index/width, column = index%width
                guard selected[index] == 0, matches(index) else { continue }
                var left = column, right = column
                while left > 0, selected[row*width+left-1] == 0, matches(row*width+left-1) { left -= 1 }
                while right+1 < width, selected[row*width+right+1] == 0, matches(row*width+right+1) { right += 1 }
                for c in left...right { selected[row*width+c] = 255 }
                for neighbor in [row-1,row+1] where neighbor >= 0 && neighbor < height {
                    var inRun = false
                    for c in left...right {
                        let candidate = selected[neighbor*width+c] == 0 && matches(neighbor*width+c)
                        if candidate && !inRun {
                            guard stack.count < 4_000_000 else { throw RasterError.oversized }
                            stack.append(UInt32(neighbor*width+c))
                        }
                        inRun = candidate
                    }
                }
            }
        }
        return try NumericSelectionRaster.grayImage(selected,width:width,height:height)
    }

    /// A real on-device Vision request. No color-threshold substitute is used if
    /// the model cannot run or cannot identify the clicked foreground instance.
    static func subject(_ image: CGImage, at point: CGPoint? = nil) throws -> CGImage {
        guard #available(iOS 17, macOS 14, *) else { throw ImageSelectionError.unavailable }
        try NumericSelectionRaster.check(image.width,image.height)
        if let point {
            guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
                  point.x < CGFloat(image.width), point.y < CGFloat(image.height) else { throw ImageSelectionError.outside }
        }
        let handler = VNImageRequestHandler(cgImage:image,orientation:.up,options:[:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.preferBackgroundProcessing = true
        do { try handler.perform([request]) } catch { throw ImageSelectionError.unavailable }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw ImageSelectionError.noSubject }
        var instances = observation.allInstances
        if let point {
            let buffer = observation.instanceMask
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { throw ImageSelectionError.unavailable }
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
            guard let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to:UInt8.self) else { throw RasterError.allocation }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let x = min(width-1,Int(point.x/CGFloat(image.width)*CGFloat(width)))
            let y = min(height-1,Int(point.y/CGFloat(image.height)*CGFloat(height)))
            let instance = Int(bytes[y*CVPixelBufferGetBytesPerRow(buffer)+x])
            guard instance > 0, instances.contains(instance) else { throw ImageSelectionError.noSubject }
            instances = IndexSet(integer:instance)
        }
        let mask: CVPixelBuffer
        do { mask = try observation.generateScaledMaskForImage(forInstances:instances,from:handler) }
        catch { throw ImageSelectionError.unavailable }
        let ci = CIImage(cvPixelBuffer:mask)
        let context = CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
        guard let output = context.createCGImage(ci,from:CGRect(x:0,y:0,width:image.width,height:image.height),
                                                 format:.L8,colorSpace:CGColorSpaceCreateDeviceGray()) else { throw RasterError.allocation }
        let values = try NumericSelectionRaster.gray(output)
        guard values.contains(where:{$0 > 0}) else { throw ImageSelectionError.noSubject }
        return try NumericSelectionRaster.grayImage(values,width:image.width,height:image.height)
    }

    /// Numeric max/min over a square neighborhood. Each pass uses a monotonic
    /// deque, so radius does not multiply work per pixel. Outside the canvas is 0.
    /// This also contracts a full-canvas selection away from its outer edges.
    static func resized(_ mask: CGImage, amount: Int) throws -> CGImage {
        guard (-100...100).contains(amount) else { throw ImageSelectionError.invalid }
        let source = try NumericSelectionRaster.gray(mask)
        guard amount != 0 else { return mask }
        let radius = abs(amount), maximum = amount > 0, width = mask.width, height = mask.height
        func filtered(_ values:[UInt8],count:Int,stride:Int,start:Int) -> [UInt8] {
            var output = [UInt8](repeating:0,count:count), indices = [Int](), queue = [UInt8](), head = 0
            indices.reserveCapacity(count+2*radius); queue.reserveCapacity(count+2*radius)
            for index in -radius..<(count+radius) {
                let value: UInt8 = (0..<count).contains(index) ? values[start+index*stride] : 0
                while indices.count > head, maximum ? queue.last! <= value : queue.last! >= value {
                    indices.removeLast(); queue.removeLast()
                }
                indices.append(index); queue.append(value)
                while head < indices.count, indices[head] < index-2*radius { head += 1 }
                let center = index-radius
                if (0..<count).contains(center) { output[center] = queue[head] }
            }
            return output
        }
        var horizontal = [UInt8](repeating:0,count:source.count)
        for row in 0..<height {
            let line = filtered(source,count:width,stride:1,start:row*width)
            horizontal.replaceSubrange(row*width..<(row+1)*width,with:line)
        }
        var result = [UInt8](repeating:0,count:source.count)
        for column in 0..<width {
            let line = filtered(horizontal,count:height,stride:width,start:column)
            for row in 0..<height { result[row*width+column] = line[row] }
        }
        return try NumericSelectionRaster.grayImage(result,width:width,height:height)
    }
}

enum NumericSelectionRaster {
    static func check(_ width:Int,_ height:Int) throws {
        guard width > 0,height > 0,width <= 4096,height <= 4096,width*height <= 16_000_000 else { throw RasterError.oversized }
    }
    static func rgba(_ image:CGImage) throws -> [UInt8] {
        try check(image.width,image.height)
        let context = try RasterImage.context(width:image.width,height:image.height)
        context.setBlendMode(.copy); context.interpolationQuality = .none
        RasterImage.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height),context:context)
        guard let bytes = context.data?.assumingMemoryBound(to:UInt8.self) else { throw RasterError.allocation }
        return (0..<image.height).flatMap { Array(UnsafeBufferPointer(start:bytes+$0*context.bytesPerRow,count:image.width*4)) }
    }
    static func gray(_ image:CGImage) throws -> [UInt8] {
        try check(image.width,image.height)
        guard image.bitsPerComponent == 8,image.bitsPerPixel == 8,image.alphaInfo == .none,
              image.colorSpace?.model == .monochrome,image.decode == nil,image.bytesPerRow >= image.width,
              let data = image.dataProvider?.data,CFDataGetLength(data) >= image.bytesPerRow*image.height,
              let bytes = CFDataGetBytePtr(data) else { throw ImageSelectionError.invalid }
        return (0..<image.height).flatMap { Array(UnsafeBufferPointer(start:bytes+$0*image.bytesPerRow,count:image.width)) }
    }
    static func grayImage(_ values:[UInt8],width:Int,height:Int) throws -> CGImage {
        try check(width,height)
        guard values.count == width*height,let provider = CGDataProvider(data:Data(values) as CFData),
              let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
                decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw RasterError.allocation }
        return image
    }
}
