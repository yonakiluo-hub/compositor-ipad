// Synthetic cached-image CPU composition only; not Pencil, display or iPad latency.
import Foundation
import CoreGraphics
import Dispatch

@main struct ClippingBenchmark {
    static func png(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) throws -> Data {
        let context = try RasterImage.context(width: width, height: height)
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try RasterImage.png(context.makeImage()!)
    }
    static func main() throws {
        let width = 1200, height = 900
        var checksum = 0
        for partial in [false, true] {
            for count in [1, 3] {
                let size = partial ? CGSize(width: 300, height: 200) : CGSize(width: width, height: height)
                let origin = partial ? CGPoint(x: 410, y: 333) : CGPoint.zero
                let base = RasterLayer(name: "Synthetic base", pngData: try png(width: Int(size.width), height: Int(size.height), red: 1, green: 0, blue: 0, alpha: 0.5),
                    transform: LayerTransform(origin: origin, size: size, sampling: .nearest))
                var layers = [base]
                for index in 0..<count {
                    layers.append(RasterLayer(name: "Synthetic clipped \(index)",
                        pngData: try png(width: width, height: height, red: 0, green: index == 1 ? 1 : 0, blue: 1, alpha: 0.6),
                        transform: LayerTransform(size: CGSize(width: width, height: height), sampling: .nearest), maskSourceID: base.id))
                }
                let document = CanvasDocument(width: width, height: height, layers: layers)
                try document.validate()
                let renderer = DocumentRenderer()
                for _ in 0..<3 { try autoreleasepool { _ = try renderer.render(document) } }
                var milliseconds: [Double] = []
                for _ in 0..<10 {
                    try autoreleasepool {
                        let started = DispatchTime.now().uptimeNanoseconds
                        let image = try renderer.render(document)
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                        milliseconds.append(elapsed)
                        checksum += image.width + image.height
                    }
                }
                let sorted = milliseconds.sorted()
                let mean = milliseconds.reduce(0, +) / Double(milliseconds.count), median = (sorted[4] + sorted[5]) / 2
                print(String(format: "canvas=%dx%d base=%dx%d clipped=%d n=10 mean_ms=%.3f median_ms=%.3f min_ms=%.3f max_ms=%.3f", width, height, Int(size.width), Int(size.height), count, mean, median, sorted.first!, sorted.last!))
            }
        }
        print("checksum=\(checksum)")
    }
}
