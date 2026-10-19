import XCTest
@testable import CompositorKit

final class CoreArchiveTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoreArchive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("画稿.comp")
        let layer = RasterLayer(name: "空白图层", transform: LayerTransform(size: CGSize(width: 32, height: 24)))
        let document = CanvasDocument(id: UUID(uuidString: "12345678-1234-5678-9123-123456789abc")!,
                                      name: "跨平台测试画稿", width: 32, height: 24, layers: [layer], activeLayerID: layer.id)
        try DocumentStore.save(document, to: url)
        return url
    }

    func testDeterministicStoredArchiveRoundTripsThroughSystemReader() throws {
        let url = try fixture()
        let first = try ProjectArchive.zip(contentsOf: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
                                             ofItemAtPath: url.appendingPathComponent("manifest.json").path)
        XCTAssertEqual(try ProjectArchive.zip(contentsOf: url), first, "Filesystem timestamps must not affect immutable retry bytes")
        let zipURL = url.deletingLastPathComponent().appendingPathComponent("archive.zip")
        try first.write(to: zipURL)
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", zipURL.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        #endif
        XCTAssertEqual(Array(first.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(Array(first.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])
    }

    func testSizeLimitRejectsWithoutChangingPackage() throws {
        let url = try fixture()
        let original = try DocumentStore.load(from: url)
        XCTAssertThrowsError(try ProjectArchive.zip(contentsOf: url, maximumBytes: 100))
        XCTAssertEqual(try DocumentStore.load(from: url), original)
    }

    func testUnsafeExtraFileAndSymlinkAreRejected() throws {
        let url = try fixture()
        let unsafe = url.appendingPathComponent("CON.txt")
        try Data("unsafe".utf8).write(to: unsafe)
        XCTAssertThrowsError(try ProjectArchive.zip(contentsOf: url))
        try FileManager.default.removeItem(at: unsafe)
        let external = url.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("not a project resource".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("extra.txt"), withDestinationURL: external)
        XCTAssertThrowsError(try ProjectArchive.zip(contentsOf: url))
    }
}
