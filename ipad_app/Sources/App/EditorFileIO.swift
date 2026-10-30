import SwiftUI
import UniformTypeIdentifiers

enum EditorFileExport: String { case tiff = "tiff", pdf = "pdf", psd = "psd" }

extension EditorModel {
    func openPSD(_ url: URL) {
        cancelTransform(); layerEditTarget = .pixels
        saveNow(); guard !saveFailed else { return }
        report {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let loaded = try PSDCodec.read(ImageFileCodec.data(from: url), name: url.deletingPathExtension().lastPathComponent)
            try Self.checkRenderLimits(loaded)
            try editorReplaceForImport(loaded)
        }
    }

    func exportFile(_ format: EditorFileExport) -> URL? {
        do {
            let data: Data
            switch format {
            case .psd: data = try PSDCodec.write(document, renderer: renderer)
            case .tiff: data = try ImageFileCodec.tiff(renderer.render(document), resolution: document.resolution)
            case .pdf: data = try ImageFileCodec.pdf(renderer.render(document), resolution: document.resolution)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Compositor-" + UUID().uuidString + "." + format.rawValue)
            try data.write(to: url, options: .atomic); return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

}
