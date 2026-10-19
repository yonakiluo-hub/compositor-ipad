import Foundation
import CoreGraphics

extension EditorModel {
    func importPairing(_ url: URL) {
        report {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let value = try BridgePairing.decode(Data(contentsOf: url))
            try KeychainPairingStore().save(value)
            pairing = value; bridge = try BridgeClient(pairing: value); capabilities = nil
            jobs.removeAll(); candidates.removeAll(); pendingRequests.removeAll(); backupStatus = ""; restartRecovery()
        }
    }
    func disconnect() {
        recoveryTask?.cancel()
        report { try KeychainPairingStore().remove(); pairing = nil; bridge = nil; capabilities = nil; jobs = []; candidates = [:]; pendingRequests = []; backupStatus = "" }
    }
    private func matchesContext(_ client: BridgeClient, pairing expectedPairing: BridgePairing, documentID: UUID? = nil) -> Bool {
        !Task.isCancelled && bridge === client && pairing == expectedPairing && (documentID == nil || document.id == documentID)
    }

    func connect() async {
        guard let bridge, let pairing else { return }
        do {
            let checked = try await bridge.preflight()
            guard matchesContext(bridge, pairing: pairing) else { return }
            capabilities = checked
            await refreshJobs()
        } catch { if matchesContext(bridge, pairing: pairing) { errorMessage = error.localizedDescription } }
    }
    func submitGeneration() async {
        guard !networkBusy, let bridge, let pairing, let taskStore else { return }
        // A result anchored to this revision must still have a source document after a crash.
        saveNow(); guard !saveFailed else { return }
        networkBusy = true; defer { networkBusy = false }
        let snapshot = document
        let frozenPrompt = prompt
        do {
            let image = try renderer.render(snapshot)
            let mask = try snapshot.selectionMaskPNGData.map(RasterImage.decode) ?? RasterImage.solidMask(width: snapshot.width, height: snapshot.height, white: true)
            let caps = try await bridge.preflight()
            guard matchesContext(bridge, pairing: pairing, documentID: snapshot.id) else { return }
            capabilities = caps
            let crop = try generationCrop(mask: mask, selected: snapshot.selectionMaskPNGData != nil, capabilities: caps)
            guard let croppedImage = image.cropping(to: crop.cgRect), let croppedMask = mask.cropping(to: crop.cgRect) else { throw RasterError.invalidImage }
            let imageData = try RasterImage.png(croppedImage), maskData = try RasterImage.png(croppedMask)
            let metadata = BridgeJobMetadata(documentId: snapshot.id.uuidString.lowercased(), baseRevision: snapshot.revision,
                sourceLayerIds: snapshot.renderLayers.map { $0.layer.id.uuidString.lowercased() },
                canvasSize: .init(width: snapshot.width, height: snapshot.height),
                cropRect: .init(x: crop.x, y: crop.y, width: crop.width, height: crop.height),
                workflowPreset: caps.presets[0].id, prompt: frozenPrompt, seed: Int64.random(in: 0...Int64.max))
            try metadata.validate(capabilities: caps)
            let submission = try await taskStore.prepare(metadata: metadata, imagePNG: imageData, maskPNG: maskData, pairing: pairing)
            guard matchesContext(bridge, pairing: pairing, documentID: snapshot.id) else { return }
            pendingRequests.append(metadata.clientRequestId)
            let job = try await bridge.submit(submission, store: taskStore)
            guard matchesContext(bridge, pairing: pairing, documentID: snapshot.id) else { return }
            accept(job)
            pendingRequests.removeAll { $0 == metadata.clientRequestId }
            restartRecovery()
        } catch {
            guard matchesContext(bridge, pairing: pairing, documentID: snapshot.id) else { return }
            errorMessage = error.localizedDescription
            await loadPendingRequests()
        }
    }

    func backupCurrentDocument() async {
        guard !networkBusy, let bridge, let pairing, let taskStore else { return }
        saveNow(); guard !saveFailed else { return }
        let snapshot = document
        let id = snapshot.id.uuidString.lowercased()
        networkBusy = true; defer { networkBusy = false }
        backupStatus = "正在准备版本 \(snapshot.revision) 的备份…"
        do {
            let existing = try await taskStore.loadSnapshot(documentID: id, revision: snapshot.revision)
            let upload: BridgeSnapshotUpload
            if let existing { upload = existing }
            else {
                // Autosave can replace documentURL while ZIP is being built. Export the frozen
                // value to a private package on a utility thread, so editing remains responsive.
                let archive = try await Task.detached(priority: .utility) {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try DocumentStore.save(snapshot, to: temporary)
                    return try ProjectArchive.zip(contentsOf: temporary)
                }.value
                upload = try await taskStore.prepareSnapshot(documentID: id, revision: snapshot.revision, archive: archive, pairing: pairing)
            }
            guard matchesContext(bridge, pairing: pairing, documentID: snapshot.id) else { return }
            backupStatus = "正在上传版本 \(snapshot.revision)…"
            let receipt = try await bridge.uploadSnapshot(upload)
            guard matchesContext(bridge, pairing: pairing, documentID: snapshot.id) else { return }
            backupStatus = "已备份版本 \(receipt.revision) · \(ByteCountFormatter.string(fromByteCount: Int64(receipt.bytes), countStyle: .file))"
        } catch {
            guard matchesContext(bridge, pairing: pairing, documentID: snapshot.id) else { return }
            backupStatus = "备份未完成；重试同一版本会复用已保存的备份"
            errorMessage = error.localizedDescription
        }
    }
    private func generationCrop(mask: CGImage, selected: Bool, capabilities: BridgeCapabilities) throws -> PixelRect {
        var rect = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        if selected {
            let context = try RasterImage.context(width: mask.width, height: mask.height, gray: true)
            RasterImage.draw(mask, in: rect, context: context)
            guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw RasterError.allocation }
            var minX = mask.width, minY = mask.height, maxX = -1, maxY = -1
            for y in 0..<mask.height { for x in 0..<mask.width where bytes[y * context.bytesPerRow + x] > 0 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            } }
            guard maxX >= minX else { throw BridgeError.invalidInput("选区为空，请绘制选区或取消选区") }
            let margin = max(32, capabilities.minInputSide)
            rect = CGRect(x: max(0, minX - margin), y: max(0, minY - margin),
                          width: min(mask.width, maxX + margin + 1) - max(0, minX - margin),
                          height: min(mask.height, maxY + margin + 1) - max(0, minY - margin))
        }
        guard Int(rect.width * rect.height) <= capabilities.maxInputPixels else {
            throw BridgeError.invalidInput("生成区域超过服务像素限制，请绘制较小选区；本地画布不会被缩小")
        }
        return PixelRect(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height))
    }
    func restartRecovery() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshJobs()
            while !Task.isCancelled && self.jobs.contains(where: { $0.state == .queued || $0.state == .running }) {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                guard !Task.isCancelled else { break }
                await self.refreshJobs()
            }
        }
    }
    func suspend() { saveNow(); recoveryTask?.cancel() }
    func refreshJobs() async {
        // A replacement recovery task may start before its cancelled predecessor unwinds.
        // Wait asynchronously for that owner instead of silently dropping the new refresh.
        while isRefreshing {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled, let bridge, let pairing, let taskStore else { return }
        isRefreshing = true; defer { isRefreshing = false }
        let documentID = document.id
        let id = documentID.uuidString.lowercased()
        do {
            let saved = try await taskStore.list(documentID: id).filter { $0.origin == pairing.origin && $0.backend == pairing.backend }
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            pendingRequests = saved.filter { $0.jobID == nil }.map { $0.metadata.clientRequestId }
            var recovered = try await bridge.jobs(documentID: id)
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            for submission in saved {
                if let jobID = submission.jobID, !recovered.contains(where: { $0.jobId == jobID }) {
                    recovered.append(try await bridge.job(id: jobID))
                    guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
                }
            }
            for job in recovered {
                guard job.source.documentId == id else { throw BridgeError.invalidResponse("恢复任务的文档不一致") }
                if saved.contains(where: { $0.metadata.clientRequestId == job.clientRequestId }) {
                    try await taskStore.record(job: job, for: job.clientRequestId)
                }
                guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
                // A list response can recover an upload whose original receipt was lost.
                pendingRequests.removeAll { $0 == job.clientRequestId }
                accept(job)
                if job.state == .succeeded {
                    for result in job.results where candidates[candidateKey(job, result)] == nil {
                        let bytes = try await bridge.download(result: result, job: job)
                        _ = try RasterImage.decode(bytes)
                        guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
                        candidates[candidateKey(job, result)] = bytes
                    }
                }
            }
        } catch {
            if matchesContext(bridge, pairing: pairing, documentID: documentID) {
                // Stop this recovery loop after an outage. Foreground activation or refresh
                // resumes the original IDs, with the persisted submissions still intact.
                recoveryTask?.cancel(); errorMessage = error.localizedDescription
            }
        }
    }
    func loadPendingRequests() async {
        guard let bridge, let pairing, let taskStore else { return }
        let documentID = document.id
        do {
            let pending = try await taskStore.list(documentID: documentID.uuidString.lowercased())
                .filter { $0.origin == pairing.origin && $0.backend == pairing.backend && $0.jobID == nil }.map { $0.metadata.clientRequestId }
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            pendingRequests = pending
        } catch { if matchesContext(bridge, pairing: pairing, documentID: documentID) { errorMessage = error.localizedDescription } }
    }
    func retryPending(_ id: String) async {
        guard !networkBusy, let bridge, let pairing, let taskStore else { return }
        let documentID = document.id
        networkBusy = true; defer { networkBusy = false }
        do {
            let submission = try await taskStore.load(requestID: id)
            guard submission.metadata.documentId == documentID.uuidString.lowercased(),
                  matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            let job = try await bridge.submit(submission, store: taskStore)
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            accept(job)
            pendingRequests.removeAll { $0 == id }; restartRecovery()
        } catch { if matchesContext(bridge, pairing: pairing, documentID: documentID) { errorMessage = error.localizedDescription } }
    }
    func accept(_ job: BridgeJob) {
        if let index = jobs.firstIndex(where: { $0.jobId == job.jobId }) { jobs[index] = job }
        else { jobs.insert(job, at: 0) }
        jobs.sort { $0.createdAt > $1.createdAt }
    }
    func candidateKey(_ job: BridgeJob, _ result: BridgeResult) -> String { job.jobId + "/" + result.resultId }
    func applyCandidate(_ job: BridgeJob, _ result: BridgeResult) {
        guard let data = candidates[candidateKey(job, result)] else { return }
        report {
            guard let documentID = UUID(uuidString: job.source.documentId) else { throw DocumentError.wrongDocument }
            let crop = result.cropRect
            let anchor = GenerationAnchor(documentID: documentID, baseRevision: job.source.baseRevision,
                canvasWidth: job.source.canvasSize.width, canvasHeight: job.source.canvasSize.height,
                cropRect: PixelRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height))
            _ = try editor.insertAIResult(pngData: data, key: AIResultKey(jobID: job.jobId, resultID: result.resultId), anchor: anchor,
                                          name: job.isSimulation ? "模拟候选" : "AI 候选")
            changed()
        }
    }
}
