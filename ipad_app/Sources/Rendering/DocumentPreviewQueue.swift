import Foundation
import CoreGraphics

/// All full-document preview tools share one worker allocation. A canceled job
/// already running keeps its place until it exits; a canceled queued job skips.
actor DocumentPreviewQueue {
    static let shared = DocumentPreviewQueue()
    private var tail: Task<Void, Never>?
    private var latest: UUID?

    func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async -> Result<Value, Error> {
        guard !Task.isCancelled else { return .failure(CancellationError()) }
        let previous = tail, id = UUID()
        let worker = Task.detached(priority: .userInitiated) {
            await previous?.value
            guard !Task.isCancelled else { return Result<Value, Error>.failure(CancellationError()) }
            return Result(catching: operation)
        }
        tail = Task { _ = await worker.value }; latest = id
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        if latest == id { tail = nil; latest = nil }
        return result
    }
}

/// CGImage is immutable after creation and may safely cross the preview queue.
struct DocumentPreviewImage: @unchecked Sendable { let image: CGImage }
struct PreparedLayerContent: @unchecked Sendable { let document: CanvasDocument; let image: CGImage }
