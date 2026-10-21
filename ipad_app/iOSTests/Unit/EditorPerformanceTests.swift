import XCTest
import UIKit
import Darwin
@testable import CompositorPad

/// Synthetic CPU/rendering measurements, not Pencil-to-display latency. Run on an
/// isolated test host; this test never opens the production app's document directory.
final class EditorPerformanceTests: XCTestCase {
    private struct Distribution: Encodable {
        let count: Int
        let medianMS: Double
        let p95MS: Double
        let maximumMS: Double
        init(_ values: [Double]) {
            let sorted = values.sorted()
            count = sorted.count
            medianMS = sorted[sorted.count / 2]
            p95MS = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
            maximumMS = sorted.last!
        }
    }
    private struct Report: Encodable {
        let schemaVersion = 1
        let workload = "synthetic-coalesced-stroke-and-full-document-composite"
        let platform: String
        let osVersion: String
        let buildConfiguration: String
        let width: Int
        let height: Int
        let layerCount: Int
        let frameBatches: Int
        let samplesPerBatch: Int
        let brushDiameter = 28
        let brushHardness = 0.8
        let coldCompositeMS: Double
        let strokeAllocationMS: Double
        let sampleBatch: Distribution
        let strokeImage: Distribution
        let fullComposite: Distribution
        let batchTotal: Distribution
        let finalPNGEncodingMS: Double
        let commitAndRefreshMS: Double
        let memoryBaselineBytes: UInt64
        let memorySampledPeakBytes: UInt64
        let memoryObservedIncreaseBytes: UInt64
        let memorySampleCount: Int
        let memorySampleIntervalMS = 2
        let memoryMeasurementWindow = "After fixture construction and cold composition, through stroke preview and commit; excludes fixture setup."
        let limits = "No touch delivery, display scanout, GPU presentation, Pencil hardware, thermal soak or memory-pressure simulation. Memory peak is sampled process footprint, not a guaranteed OS high-water mark."
    }

    @MainActor
    func testSyntheticStrokePerformanceBaseline() throws {
        // The current accepted artwork size is 1200x900. Both workloads contain
        // synthetic pixels only; two layers match its layer count, eight add stress.
        let requestedWidth = ProcessInfo.processInfo.environment["COMPOSITOR_PERFORMANCE_WIDTH"].flatMap(Int.init) ?? 1200
        let requestedHeight = ProcessInfo.processInfo.environment["COMPOSITOR_PERFORMANCE_HEIGHT"].flatMap(Int.init) ?? 900
        guard requestedWidth > 0, requestedHeight > 0, requestedWidth <= 4096, requestedHeight <= 4096,
              requestedWidth * requestedHeight <= 16_000_000 else { throw RasterError.oversized }
        for layerCount in [2, 8] {
            try autoreleasepool {
                let document = try fixture(width: requestedWidth, height: requestedHeight, layers: layerCount)
                let renderer = DocumentRenderer()
                let startCold = CACurrentMediaTime()
                let base = try renderer.render(document)
                let coldCompositeMS = elapsedMS(startCold)
                XCTAssertEqual(base.width, requestedWidth)
                let active = try XCTUnwrap(document.activeLayer)
                let original = try renderer.image(for: active)
                let selection = try document.selectionMaskPNGData.map(RasterImage.decode)
                let localSelection = try renderer.localSelection(selection, layer: active, document: document)
                var settings = PadBrushSettings()
                settings.diameter = 28; settings.hardness = 0.8; settings.opacity = 0.7
                settings.color = UIColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
                let memory = FootprintSampler()
                defer { memory.stop() }
                let startAllocation = CACurrentMediaTime()
                let stroke = try PadBrushStroke(width: requestedWidth, height: requestedHeight, original: original,
                                                settings: settings, selection: localSelection, maskMode: false)
                let allocationMS = elapsedMS(startAllocation)
                let frames = 40, perBatch = 4
                var sampleTimes: [Double] = [], previewTimes: [Double] = [], compositeTimes: [Double] = [], totals: [Double] = []
                var lastImage: CGImage?
                for frame in 0..<frames {
                    try autoreleasepool {
                        let startBatch = CACurrentMediaTime()
                        for sample in 0..<perBatch {
                            let t = CGFloat(frame * perBatch + sample) / CGFloat(frames * perBatch - 1)
                            stroke.add(BrushSample(point: CGPoint(x: CGFloat(requestedWidth) * (0.1 + 0.8 * t),
                                                                 y: CGFloat(requestedHeight) * (0.5 + 0.25 * sin(t * .pi * 4))),
                                                   pressure: 0.2 + 0.8 * abs(sin(t * .pi * 2)),
                                                   altitude: 0.6 + t, azimuth: t * .pi / 2))
                        }
                        sampleTimes.append(elapsedMS(startBatch))
                        let startImage = CACurrentMediaTime()
                        let image = try stroke.image()
                        previewTimes.append(elapsedMS(startImage))
                        let startComposite = CACurrentMediaTime()
                        let composite = try renderer.render(document, replacing: active.id, with: image)
                        compositeTimes.append(elapsedMS(startComposite))
                        XCTAssertEqual(composite.width, requestedWidth)
                        lastImage = image
                        totals.append(elapsedMS(startBatch))
                        memory.sample()
                    }
                }
                let startEncoding = CACurrentMediaTime()
                let encoded = try RasterImage.png(XCTUnwrap(lastImage))
                let encodingMS = elapsedMS(startEncoding)
                let editor = try DocumentEditor(document: document)
                let startCommit = CACurrentMediaTime()
                try editor.transaction("Synthetic measured stroke") { changed in
                    let index = try XCTUnwrap(changed.layers.firstIndex(where: { $0.id == active.id }))
                    changed.layers[index].pngData = encoded
                }
                _ = try renderer.render(editor.document)
                let commitMS = elapsedMS(startCommit)
                memory.sample(); memory.stop()
                let footprint = memory.snapshot()
                XCTAssertEqual(editor.document.layers.count, layerCount)
                XCTAssertEqual(editor.document.revision, document.revision + 1)
                let report = Report(platform: platform, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                    buildConfiguration: buildConfiguration, width: requestedWidth, height: requestedHeight,
                                    layerCount: layerCount, frameBatches: frames, samplesPerBatch: perBatch,
                                    coldCompositeMS: coldCompositeMS, strokeAllocationMS: allocationMS,
                                    sampleBatch: Distribution(sampleTimes), strokeImage: Distribution(previewTimes),
                                    fullComposite: Distribution(compositeTimes), batchTotal: Distribution(totals),
                                    finalPNGEncodingMS: encodingMS, commitAndRefreshMS: commitMS,
                                    memoryBaselineBytes: footprint.baseline, memorySampledPeakBytes: footprint.peak,
                                    memoryObservedIncreaseBytes: footprint.peak - min(footprint.peak, footprint.baseline),
                                    memorySampleCount: footprint.count)
                let data = try JSONEncoder().encode(report)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "EditorPerformance-\(requestedWidth)x\(requestedHeight)-\(layerCount)layers"
                attachment.lifetime = .keepAlways; add(attachment)
                print("COMPOSITOR_PERFORMANCE " + String(decoding: data, as: UTF8.self))
            }
        }
    }

    @MainActor
    func testSuspendSavesLayerPixelsMasksAndSelectionForReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editor-performance-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        let support = root.appendingPathComponent("Support")
        let suite = "editor-performance-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let initial = try fixture(width: 1200, height: 900, layers: 2)
        let url = documents.appendingPathComponent(initial.id.uuidString.lowercased() + ".comp")
        try DocumentStore.save(initial, to: url)
        preferences.set(initial.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: documents, supportURL: support, preferences: preferences, loadPairing: false)
        XCTAssertNil(model.errorMessage)
        model.addLayer()
        let selection = try RasterImage.context(width: 1200, height: 900, gray: true)
        selection.setFillColor(gray: 0.5, alpha: 1)
        selection.fill(CGRect(x: 100, y: 80, width: 700, height: 550))
        model.commitSelection(try XCTUnwrap(selection.makeImage()))
        let expected = model.document
        let start = CACurrentMediaTime()
        model.suspend() // Same synchronous save boundary used by scene backgrounding.
        let saveMS = elapsedMS(start)
        XCTAssertFalse(model.saveFailed)
        let reopened = EditorModel(documentsURL: documents, supportURL: support, preferences: preferences, loadPairing: false)
        defer { reopened.suspend() }
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.document, expected)
        XCTAssertEqual(reopened.document.layers.count, 3)
        XCTAssertNotNil(reopened.document.selectionMaskPNGData)
        XCTAssertNotNil(reopened.document.layers[1].maskPNGData)
        print("COMPOSITOR_BACKGROUND_SAVE " + String(format: "%.3f ms; 1200x900; 3 synthetic layers; masks and selection retained; model lifecycle only, not OS termination", saveMS))
    }

    private func fixture(width: Int, height: Int, layers count: Int) throws -> CanvasDocument {
        let selection = try RasterImage.context(width: width, height: height, gray: true)
        selection.setFillColor(gray: 1, alpha: 1)
        selection.fill(CGRect(x: width / 12, y: height / 12, width: width * 5 / 6, height: height * 5 / 6))
        let selectionData = try RasterImage.png(XCTUnwrap(selection.makeImage()))
        var layers: [RasterLayer] = []
        for index in 0..<count {
            let context = try RasterImage.context(width: width, height: height)
            for band in 0..<24 {
                context.setFillColor(CGColor(red: CGFloat((index + band) % 7) / 7,
                                             green: CGFloat((2 * index + band) % 11) / 11,
                                             blue: CGFloat((index + 3 * band) % 13) / 13,
                                             alpha: index == 0 ? 1 : 0.65))
                context.fill(CGRect(x: band * width / 24, y: 0, width: width / 24 + 1, height: height))
            }
            let png = try RasterImage.png(XCTUnwrap(context.makeImage()))
            var layer = RasterLayer(name: "Synthetic layer \(index + 1)", pngData: png,
                                    transform: LayerTransform(size: CGSize(width: width, height: height)))
            if index % 3 == 1 { layer.maskPNGData = selectionData }
            if index % 4 == 3 { layer.blendMode = .multiply }
            layers.append(layer)
        }
        var document = CanvasDocument(name: "Synthetic performance fixture", width: width, height: height,
                                      layers: layers, activeLayerID: layers.last?.id)
        document.selectionMaskPNGData = selectionData
        return document
    }
    private func elapsedMS(_ start: CFTimeInterval) -> Double { (CACurrentMediaTime() - start) * 1000 }
    private var platform: String {
        #if targetEnvironment(simulator)
        "iOS Simulator"
        #else
        "physical iOS device"
        #endif
    }
    private var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }
}

/// A sampled process footprint includes the test host and renderer caches. It is
/// deliberately labelled as sampled: allocations shorter than 2 ms can be missed.
private final class FootprintSampler {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "compositor.synthetic-footprint", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let baseline: UInt64
    private var peak: UInt64
    private var count = 0
    init() {
        let initial = Self.footprint()
        baseline = initial; peak = initial
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel() }
    func sample() {
        let value = Self.footprint()
        lock.lock(); peak = max(peak, value); count += 1; lock.unlock()
    }
    func stop() { timer?.cancel(); timer = nil; queue.sync {} }
    func snapshot() -> (baseline: UInt64, peak: UInt64, count: Int) {
        lock.lock(); defer { lock.unlock() }
        return (baseline, peak, count)
    }
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
