import XCTest
import CoreGraphics
import ImageIO
@testable import CompositorKit

final class CoreDocumentTests: XCTestCase {
    private func png(width: Int = 8, height: Int = 6, gray: Bool = false) throws -> Data {
        let colorSpace = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * (gray ? 1 : 4), space: colorSpace, bitmapInfo: bitmapInfo))
        context.setFillColor(gray ? CGColor(gray: 0.75, alpha: 1) : CGColor(red: 0.8, green: 0.1, blue: 0.3, alpha: 0.75))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func fixture() throws -> CanvasDocument {
        let layer = RasterLayer(name: "原始笔迹", pngData: try png(), transform: LayerTransform(size: CGSize(width: 8, height: 6)))
        return CanvasDocument(name: "测试画稿", width: 32, height: 24, layers: [layer], activeLayerID: layer.id)
    }

    private func packageURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("Test.comp")
    }

    func testAtomicTransactionRollbackNoOpAndMonotonicHistory() throws {
        let document = try fixture()
        let editor = try DocumentEditor(document: document)
        try editor.transaction("不透明度") { $0.layers[0].opacity = 0.5 }
        XCTAssertEqual(editor.document.revision, 1)
        XCTAssertEqual(editor.undoCount, 1)
        try editor.undo()
        XCTAssertEqual(editor.document.layers[0].opacity, 1)
        XCTAssertEqual(editor.document.revision, 2)
        XCTAssertTrue(editor.canRedo)
        try editor.transaction("空操作") { $0.layers[0].opacity = 1 }
        try editor.selectLayer(nil)
        XCTAssertTrue(editor.canRedo)
        XCTAssertEqual(editor.document.revision, 2)
        let before = editor.document
        XCTAssertThrowsError(try editor.transaction("坏编辑") { $0.layers[0].opacity = .nan })
        XCTAssertEqual(editor.document, before)
        XCTAssertTrue(editor.canRedo)
        try editor.redo()
        XCTAssertEqual(editor.document.layers[0].opacity, 0.5)
        XCTAssertEqual(editor.document.revision, 3)
        editor.markSaved()
        XCTAssertFalse(editor.isModified)
        try editor.transaction("新编辑") { $0.layers[0].name = "改名" }
        XCTAssertTrue(editor.isModified)
        XCTAssertFalse(editor.canRedo)
    }

    func testRevisionOverflowDoesNotPartiallyMutate() throws {
        var document = try fixture()
        document.revision = Int64.max
        let editor = try DocumentEditor(document: document)
        XCTAssertThrowsError(try editor.setOpacity(layerID: document.layers[0].id, opacity: 0.5)) {
            XCTAssertEqual($0 as? DocumentError, .revisionExhausted)
        }
        XCTAssertEqual(editor.document, document)
        XCTAssertFalse(editor.canUndo)
    }

    func testTransactionCannotReplaceDocumentIdentity() throws {
        let original = try fixture()
        let replacement = try fixture()
        let editor = try DocumentEditor(document: original)
        XCTAssertThrowsError(try editor.transaction("替换身份") { $0 = replacement }) {
            XCTAssertEqual($0 as? DocumentError, .wrongDocument)
        }
        XCTAssertEqual(editor.document, original)
        XCTAssertFalse(editor.canUndo)
    }

    func testAIResultIsIndependentSingleTransactionAndReceiptSurvivesUndoSave() throws {
        let editor = try DocumentEditor(document: fixture())
        try editor.transaction("先前编辑") { $0.layers[0].name = "保留的笔迹" }
        let key = AIResultKey(jobID: "test-job", resultID: "0")
        let crop = PixelRect(x: 7, y: 9, width: 8, height: 6)
        let anchor = GenerationAnchor(documentID: editor.document.id, baseRevision: editor.document.revision,
                                      canvasWidth: 32, canvasHeight: 24, cropRect: crop)
        let originalPixels = editor.document.layers[0].pngData
        let generatedPixels = try png()
        let id = try editor.insertAIResult(pngData: generatedPixels, key: key, anchor: anchor)
        XCTAssertEqual(editor.document.layers.count, 2)
        XCTAssertEqual(editor.document.layers.last?.id, id)
        XCTAssertEqual(editor.document.layers.last?.transform.origin, CGPoint(x: 7, y: 9))
        XCTAssertEqual(editor.document.layers.last?.pngData, generatedPixels, "No second mask or alpha multiplication")
        XCTAssertEqual(editor.document.layers[0].pngData, originalPixels)
        XCTAssertEqual(editor.undoCount, 2)
        XCTAssertThrowsError(try editor.insertAIResult(pngData: generatedPixels, key: key, anchor: anchor)) {
            XCTAssertEqual($0 as? DocumentError, .duplicateResult)
        }
        try editor.undo()
        XCTAssertEqual(editor.document.layers.count, 1)
        XCTAssertTrue(editor.document.appliedAIResults.contains(key))
        XCTAssertEqual(editor.document.layers[0].name, "保留的笔迹")
        let url = try packageURL()
        try DocumentStore.save(editor.document, to: url)
        let reopened = try DocumentStore.load(from: url)
        XCTAssertTrue(reopened.appliedAIResults.contains(key))
        try editor.redo()
        XCTAssertEqual(editor.document.layers.last?.id, id)
        XCTAssertEqual(editor.document.layers.last?.pngData, generatedPixels)
    }

    func testAICandidateGuardsWrongDocumentRevisionGeometryAndDimensions() throws {
        let editor = try DocumentEditor(document: fixture())
        let pixels = try png()
        let key = AIResultKey(jobID: "job", resultID: "0")
        func anchor(id: UUID? = nil, revision: Int64 = 0, width: Int = 32, crop: PixelRect = PixelRect(x: 0, y: 0, width: 8, height: 6)) -> GenerationAnchor {
            GenerationAnchor(documentID: id ?? editor.document.id, baseRevision: revision, canvasWidth: width, canvasHeight: 24, cropRect: crop)
        }
        for rejected in [anchor(id: UUID()), anchor(revision: 1), anchor(width: 31),
                         anchor(crop: PixelRect(x: 30, y: 0, width: 8, height: 6)),
                         anchor(crop: PixelRect(x: 0, y: 0, width: 7, height: 6))] {
            XCTAssertThrowsError(try editor.insertAIResult(pngData: pixels, key: key, anchor: rejected))
        }
        XCTAssertEqual(editor.document.revision, 0)
        XCTAssertEqual(editor.document.layers.count, 1)
        XCTAssertFalse(editor.canUndo)
    }

    func testHierarchyOpacityVisibilityReorderDuplicateDeleteAndLock() throws {
        var document = try fixture()
        let group = RasterLayer(name: "组", transform: LayerTransform(size: document.size), opacity: 0.5, isGroup: true)
        document.layers[0].parentID = group.id
        document.layers[0].opacity = 0.5
        document.layers.insert(group, at: 0)
        let editor = try DocumentEditor(document: document)
        XCTAssertEqual(editor.document.renderLayers.first?.effectiveOpacity, 0.25)
        try editor.setVisibility(layerID: group.id, isVisible: false)
        XCTAssertTrue(editor.document.renderLayers.isEmpty)
        try editor.setVisibility(layerID: group.id, isVisible: true)
        let duplicate = try editor.duplicateLayer(group.id)
        XCTAssertEqual(editor.document.layers.count, 4)
        let duplicateChild = try XCTUnwrap(editor.document.layers.first { $0.parentID == duplicate })
        XCTAssertNotEqual(duplicateChild.id, document.layers[1].id)
        XCTAssertEqual(duplicateChild.pngData, document.layers[1].pngData)
        try editor.reorderLayer(duplicate, offset: -1)
        XCTAssertEqual(editor.document.hierarchy.first?.layer.id, duplicate)
        try editor.setLocked(layerID: group.id, isLocked: true)
        XCTAssertThrowsError(try editor.setPixels(layerID: document.layers[1].id, pngData: nil)) {
            XCTAssertEqual($0 as? DocumentError, .lockedLayer)
        }
        XCTAssertThrowsError(try editor.deleteLayer(group.id))
        try editor.deleteLayer(duplicate)
        XCTAssertEqual(editor.document.layers.count, 2)
        try editor.setLocked(layerID: group.id, isLocked: false)
        XCTAssertThrowsError(try editor.moveLayer(group.id, into: group.id))
        XCTAssertEqual(editor.document.layers[0].parentID, nil)
    }

    func testDuplicatedGroupStaysBelowHigherSiblingWhenChildWasAddedLater() throws {
        let size = CGSize(width: 32, height: 24)
        let editor = try DocumentEditor(document: CanvasDocument(width: 32, height: 24))
        let group = RasterLayer(name: "原组", transform: .init(size: size), isGroup: true)
        let higher = RasterLayer(name: "上方图层", pngData: try png(), transform: .init(size: size))
        let lateChild = RasterLayer(name: "后来添加的子层", pngData: try png(), transform: .init(size: size), parentID: group.id)
        try editor.addLayer(group)
        try editor.addLayer(higher)
        try editor.addLayer(lateChild)
        let before = editor.document
        let undoCount = editor.undoCount
        let duplicate = try editor.duplicateLayer(group.id)
        let childCopy = try XCTUnwrap(editor.document.layers.first { $0.parentID == duplicate })
        XCTAssertEqual(editor.document.layers.filter { $0.parentID == nil }.map(\.id), [group.id, duplicate, higher.id])
        XCTAssertEqual(editor.document.renderLayers.map { $0.layer.id }, [lateChild.id, childCopy.id, higher.id])
        XCTAssertEqual(childCopy.pngData, lateChild.pngData)
        XCTAssertNotEqual(childCopy.id, lateChild.id)
        XCTAssertEqual(editor.document.activeLayerID, duplicate)
        XCTAssertEqual(editor.undoCount, undoCount + 1)
        let duplicated = editor.document
        try editor.undo()
        XCTAssertEqual(editor.document.layers, before.layers)
        XCTAssertEqual(editor.document.activeLayerID, before.activeLayerID)
        try editor.redo()
        XCTAssertEqual(editor.document.layers, duplicated.layers, "Redo must preserve duplicate layer identities and order")
        XCTAssertEqual(editor.document.activeLayerID, duplicate)
    }

    func testDuplicatedNestedGroupRemapsDescendantsWithoutChangingSiblingOrderOrLocks() throws {
        let size = CGSize(width: 32, height: 24)
        let outer = RasterLayer(name: "外层组", transform: .init(size: size), opacity: 0.8, isGroup: true)
        let group = RasterLayer(name: "待复制组", transform: .init(size: size), isLocked: true,
                                opacity: 0.5, parentID: outer.id, isGroup: true)
        let higher = RasterLayer(name: "同级上方图层", transform: .init(size: size), parentID: outer.id)
        let rootHigher = RasterLayer(name: "根级上方图层", transform: .init(size: size))
        let nested = RasterLayer(name: "内部组", transform: .init(size: size), opacity: 0.25, parentID: group.id, isGroup: true)
        let leaf = RasterLayer(name: "带蒙版子层", pngData: try png(), transform: .init(size: size, rotation: 35, flipX: true),
                               isVisible: false, isLocked: true, opacity: 0.6, blendMode: .multiply,
                               parentID: nested.id, maskPNGData: try png(gray: true), maskEnabled: false)
        let lastChild = RasterLayer(name: "组内上方子层", transform: .init(size: size), parentID: group.id)
        // The storage array deliberately interleaves groups, siblings and later descendants.
        let original = CanvasDocument(width: 32, height: 24,
            layers: [outer, group, higher, rootHigher, nested, leaf, lastChild], activeLayerID: group.id)
        let editor = try DocumentEditor(document: original)
        let duplicate = try editor.duplicateLayer(group.id)
        let copiedGroup = try XCTUnwrap(editor.document.layers.first { $0.id == duplicate })
        let copiedNested = try XCTUnwrap(editor.document.layers.first { $0.parentID == duplicate && $0.isGroup })
        let copiedLeaf = try XCTUnwrap(editor.document.layers.first { $0.parentID == copiedNested.id })
        let copiedLast = try XCTUnwrap(editor.document.layers.first { $0.parentID == duplicate && !$0.isGroup })
        XCTAssertEqual(editor.document.layers.filter { $0.parentID == outer.id }.map(\.id), [group.id, duplicate, higher.id])
        XCTAssertEqual(editor.document.layers.filter { $0.parentID == nil }.map(\.id), [outer.id, rootHigher.id])
        XCTAssertEqual(editor.document.hierarchy.map { $0.layer.id },
            [outer.id, group.id, nested.id, leaf.id, lastChild.id, duplicate, copiedNested.id, copiedLeaf.id, copiedLast.id, higher.id, rootHigher.id])
        XCTAssertEqual(Set(editor.document.layers.map(\.id)).count, original.layers.count + 4)
        for layer in original.layers { XCTAssertEqual(editor.document.layers.first { $0.id == layer.id }, layer) }
        XCTAssertTrue(copiedGroup.isLocked)
        XCTAssertEqual(copiedGroup.opacity, group.opacity)
        XCTAssertEqual(copiedNested.opacity, nested.opacity)
        XCTAssertEqual(copiedLeaf.pngData, leaf.pngData)
        XCTAssertEqual(copiedLeaf.transform, leaf.transform)
        XCTAssertEqual(copiedLeaf.maskPNGData, leaf.maskPNGData)
        XCTAssertEqual(copiedLeaf.maskEnabled, leaf.maskEnabled)
        XCTAssertEqual(copiedLeaf.blendMode, leaf.blendMode)
        XCTAssertEqual(copiedLeaf.opacity, leaf.opacity)
        XCTAssertEqual(copiedLeaf.isVisible, leaf.isVisible)
        XCTAssertTrue(copiedLeaf.isLocked)
        XCTAssertNoThrow(try editor.document.validate())
        try editor.setLocked(layerID: outer.id, isLocked: true)
        let locked = editor.document
        XCTAssertThrowsError(try editor.duplicateLayer(group.id)) { XCTAssertEqual($0 as? DocumentError, .lockedLayer) }
        XCTAssertEqual(editor.document, locked)
    }

    func testPackageRoundTripPreservesLayersTransformsMaskSelectionLocksAndRevision() throws {
        var document = try fixture()
        document.revision = 9_007_199_254_740_993 // More than a JSON/JavaScript float can exactly represent.
        document.layers[0].transform.rotation = 32
        document.layers[0].transform.flipX = true
        document.layers[0].maskPNGData = try png(gray: true)
        document.layers[0].maskEnabled = false
        document.layers[0].isLocked = true
        document.layers[0].blendMode = .multiply
        document.selectionMaskPNGData = try png(width: 32, height: 24, gray: true)
        document.appliedAIResults = [AIResultKey(jobID: "job", resultID: "0")]
        let blank = RasterLayer(name: "透明图层", transform: LayerTransform(size: document.size))
        document.layers.append(blank)
        let url = try packageURL()
        try DocumentStore.save(document, to: url)
        XCTAssertEqual(try DocumentStore.load(from: url), document)
        let manifestData = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["format"] as? String, "com.compositor.project")
        XCTAssertEqual(manifest["version"] as? Int, 14)
        XCTAssertNil(manifest["revision"], "iPad extensions must not alter the upstream schema")
        // A rejected save does not destroy the prior valid package.
        var invalid = document; invalid.layers[0].opacity = 2
        XCTAssertThrowsError(try DocumentStore.save(invalid, to: url))
        XCTAssertEqual(try DocumentStore.load(from: url), document)
        document.name = "再次保存"
        try DocumentStore.save(document, to: url)
        XCTAssertEqual(try DocumentStore.load(from: url), document)
    }

    func testStrictImporterRejectsUnsupportedFieldsAndUnsafeAssetPath() throws {
        let document = try fixture()
        let url = try packageURL()
        try DocumentStore.save(document, to: url)
        let manifestURL = url.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        try FileManager.default.removeItem(at: url.appendingPathComponent("ipad-state.json"))
        for key in ["text", "shape", "adjustment", "effects", "maskSourceID", "unknownEditableFeature"] {
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var layers = try XCTUnwrap(manifest["layers"] as? [[String: Any]])
            layers[0][key] = ["enabled": true]
            manifest["layers"] = layers
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            XCTAssertThrowsError(try DocumentStore.load(from: url), key)
        }
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var layers = try XCTUnwrap(manifest["layers"] as? [[String: Any]])
        layers[0]["imageFile"] = "../../outside.png"
        manifest["layers"] = layers
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertThrowsError(try DocumentStore.load(from: url))
        try original.write(to: manifestURL)
        let imported = try DocumentStore.load(from: url)
        XCTAssertEqual(imported.id, document.id)
        XCTAssertEqual(imported.layers, document.layers)
        XCTAssertGreaterThan(imported.revision, 0)
    }

    func testRejectsMissingCorruptAndSymlinkedResources() throws {
        let document = try fixture()
        let url = try packageURL()
        try DocumentStore.save(document, to: url)
        let imageURL = url.appendingPathComponent("images").appendingPathComponent("\(document.layers[0].id.uuidString).png")
        let pixels = try Data(contentsOf: imageURL)
        try FileManager.default.removeItem(at: imageURL)
        XCTAssertThrowsError(try DocumentStore.load(from: url))
        try Data("broken PNG".utf8).write(to: imageURL)
        XCTAssertThrowsError(try DocumentStore.load(from: url))
        try FileManager.default.removeItem(at: imageURL)
        let external = url.deletingLastPathComponent().appendingPathComponent("outside.png")
        try pixels.write(to: external)
        try FileManager.default.createSymbolicLink(at: imageURL, withDestinationURL: external)
        XCTAssertThrowsError(try DocumentStore.load(from: url))
    }

    func testMaskFormatAndSelectionDimensionsAreStrict() throws {
        var document = try fixture()
        document.layers[0].maskPNGData = try png()
        XCTAssertThrowsError(try document.validate())
        document.layers[0].maskPNGData = nil
        document.selectionMaskPNGData = try png(gray: true)
        XCTAssertThrowsError(try document.validate())
        document.selectionMaskPNGData = try png(width: 32, height: 24, gray: true)
        XCTAssertNoThrow(try document.validate())
    }

    func testExternalOldCopyCannotOverwriteExistingLibraryDocument() throws {
        var old = try fixture()
        old.revision = 3
        old.layers[0].maskPNGData = try png(gray: true)
        old.layers[0].isLocked = true
        old.selectionMaskPNGData = try png(width: 32, height: 24, gray: true)
        old.appliedAIResults = [AIResultKey(jobID: "old-job", resultID: "0")]
        let externalURL = try packageURL()
        try DocumentStore.save(old, to: externalURL)

        var latest = old
        latest.revision = 9
        latest.layers.append(RasterLayer(name: "较新笔迹", pngData: try png(), transform: .init(size: latest.size)))
        let libraryURL = externalURL.deletingLastPathComponent().appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let existingURL = libraryURL.appendingPathComponent(old.id.uuidString.lowercased() + ".comp")
        try DocumentStore.save(latest, to: existingURL)

        let loadedOld = try DocumentStore.load(from: externalURL)
        let imported = DocumentStore.resolvingImportCollision(loadedOld, from: externalURL,
            localDestination: existingURL, destinationExists: true)
        XCTAssertNotEqual(imported.id, old.id)
        XCTAssertEqual(imported.name, old.name + " 副本")
        XCTAssertEqual(imported.revision, 0)
        XCTAssertEqual(imported.layers, old.layers)
        XCTAssertEqual(imported.activeLayerID, old.activeLayerID)
        XCTAssertEqual(imported.selectionMaskPNGData, old.selectionMaskPNGData)
        XCTAssertTrue(imported.appliedAIResults.isEmpty)
        let copyURL = libraryURL.appendingPathComponent(imported.id.uuidString.lowercased() + ".comp")
        try DocumentStore.save(imported, to: copyURL)
        XCTAssertEqual(try DocumentStore.load(from: copyURL), imported)
        XCTAssertEqual(try DocumentStore.load(from: existingURL), latest, "The newer local artwork must remain intact")
        XCTAssertEqual(try DocumentStore.load(from: externalURL), old, "Import must not modify the external source")

        let local = DocumentStore.resolvingImportCollision(latest, from: existingURL,
            localDestination: existingURL, destinationExists: true)
        XCTAssertEqual(local, latest, "Opening the actual local library file must retain identity and revision")
        let firstImport = DocumentStore.resolvingImportCollision(old, from: externalURL,
            localDestination: existingURL, destinationExists: false)
        XCTAssertEqual(firstImport, old, "An import without a collision preserves task identity")
    }
}
