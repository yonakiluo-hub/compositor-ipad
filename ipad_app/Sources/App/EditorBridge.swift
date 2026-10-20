import Foundation
import CoreGraphics

extension EditorModel {
    func importPairing(_ url: URL) {
        report {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let value = try BridgePairing.decode(Data(contentsOf: url))
            try KeychainPairingStore().save(value)
            pairing = value; bridge = try BridgeClient(pairing: value); capabilities = nil
            jobs.removeAll(); resetCandidateContext(); pendingRequests.removeAll(); backupStatus = ""; restartRecovery()
        }
    }
    func disconnect() {
        recoveryTask?.cancel()
        report { try KeychainPairingStore().remove(); pairing = nil; bridge = nil; capabilities = nil; jobs = []; resetCandidateContext(); pendingRequests = []; backupStatus = "" }
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
            let existing = try await taskStore.loadSnapshot(documentID: id, revision: snapshot.revision, pairing: pairing)
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
                await self.refreshJobs(retryDeletions: false)
            }
        }
    }
    func suspend() { saveNow(); recoveryTask?.cancel() }
    func refreshJobs(retryDeletions: Bool = true) async {
        // A replacement recovery task may start before its cancelled predecessor unwinds.
        // Wait asynchronously for that owner instead of silently dropping the new refresh.
        while isRefreshing || isRestoringCandidates {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled, let bridge, let pairing, let taskStore else { return }
        isRefreshing = true; defer { isRefreshing = false }
        let documentID = document.id
        let id = documentID.uuidString.lowercased()
        do {
            let hidden = try await taskStore.hiddenJobIDs(documentID: id, pairing: pairing)
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            hiddenJobIDs.formUnion(hidden)
            for jobID in hiddenJobIDs { forgetCandidateJob(jobID) }
            let locallyRemoved = try await taskStore.locallyRemovedJobIDs(documentID: id, pairing: pairing)
            let deletionIntents = try await taskStore.pendingDeletions(documentID: id, pairing: pairing)
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            locallyRemovedJobIDs = locallyRemoved
            pendingDeletionJobIDs = Set(deletionIntents.map(\.jobId))
            for job in deletionIntents {
                accept(job)
                if retryDeletions { await removeCandidateJob(job, sourcePairing: pairing, fromServer: true) }
                guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            }
            let saved = try await taskStore.listSummaries(documentID: id, pairing: pairing)
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            pendingRequests = saved.filter { $0.jobID == nil }.map { $0.metadata.clientRequestId }
            var recovered = try await bridge.jobs(documentID: id)
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            for submission in saved {
                if let jobID = submission.jobID, !hiddenJobIDs.contains(jobID), !unavailableJobIDs.contains(jobID), !recovered.contains(where: { $0.jobId == jobID }) {
                    do { recovered.append(try await bridge.job(id: jobID)) }
                    catch BridgeError.http(410, "job_deleted", _) {
                        guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
                        markCandidateUnavailable(jobID)
                        if let old = submission.lastJob, old.state == .succeeded || old.state == .failed { recovered.append(old) }
                    }
                    guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
                }
            }
            for job in recovered {
                guard !hiddenJobIDs.contains(job.jobId), !removingJobIDs.contains(job.jobId) else { continue }
                guard job.source.documentId == id else { throw BridgeError.invalidResponse("恢复任务的文档不一致") }
                if saved.contains(where: { $0.metadata.clientRequestId == job.clientRequestId }) {
                    try await taskStore.record(job: job, for: job.clientRequestId)
                }
                guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
                // A list response can recover an upload whose original receipt was lost.
                pendingRequests.removeAll { $0 == job.clientRequestId }
                accept(job)
            }
            // Preview only the newest successful candidate automatically. Older results
            // are loaded on demand into a bounded cache, never all downloaded on refresh.
            if let newest = jobs.first(where: { $0.state == .succeeded && !$0.results.isEmpty }),
               let result = newest.results.first {
                await loadCandidate(newest, result)
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
            let pending = try await taskStore.listSummaries(documentID: documentID.uuidString.lowercased(), pairing: pairing)
                .filter { $0.jobID == nil }.map { $0.metadata.clientRequestId }
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
        guard !hiddenJobIDs.contains(job.jobId), !removingJobIDs.contains(job.jobId) else { return }
        if let index = jobs.firstIndex(where: { $0.jobId == job.jobId }) { jobs[index] = job }
        else { jobs.insert(job, at: 0) }
        jobs.sort { $0.createdAt > $1.createdAt }
    }
    func candidateKey(_ job: BridgeJob, _ result: BridgeResult) -> String { job.jobId + "/" + result.resultId }

    func resetCandidateContext() {
        candidates.removeAll(); hiddenJobIDs.removeAll(); loadingCandidateKeys.removeAll()
        removingJobIDs.removeAll(); candidateManagementStatus = ""
        locallyRemovedJobIDs.removeAll(); pendingDeletionJobIDs.removeAll(); unavailableJobIDs.removeAll()
        candidateLoadOperations.removeAll(); candidateRemovalOperations.removeAll()
    }
    private func markCandidateUnavailable(_ jobID: String) {
        unavailableJobIDs.insert(jobID)
        // A 410 confirms a tombstone, not successful on-disk cleanup. Keep terminal
        // metadata and any user-authorized deletion intent until DELETE returns 200.
        jobs.removeAll { $0.jobId == jobID && ($0.state == .queued || $0.state == .running) }
        candidateManagementStatus = "部分候选已在服务端移除；文件清理尚未确认，可重试删除"
    }
    func restoreLocallyRemovedCandidates() async {
        guard let bridge, let pairing, let taskStore else { return }
        let documentID = document.id
        while isRefreshing || isRestoringCandidates {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
        isRestoringCandidates = true
        defer { isRestoringCandidates = false }
        do {
            let restored = try await taskStore.restoreLocalRemovals(documentID: documentID.uuidString.lowercased(), pairing: pairing)
            guard matchesContext(bridge, pairing: pairing, documentID: documentID) else { return }
            hiddenJobIDs.subtract(restored); locallyRemovedJobIDs.subtract(restored)
            candidateManagementStatus = "已重新显示仍在 Windows 保存的候选"
            isRestoringCandidates = false
            await refreshJobs()
        } catch { if matchesContext(bridge, pairing: pairing, documentID: documentID) { errorMessage = error.localizedDescription } }
    }
    private func forgetCandidateJob(_ jobID: String) {
        candidates.remove(jobID: jobID)
        jobs.removeAll { $0.jobId == jobID }
    }
    func candidatePlacementProblem(_ job: BridgeJob, _ result: BridgeResult) -> String? {
        guard UUID(uuidString: job.source.documentId) == document.id else { return "候选属于其他文稿" }
        guard job.source.canvasSize.width == document.width, job.source.canvasSize.height == document.height else {
            return "画布尺寸已改变，无法按原位置加入"
        }
        guard job.source.baseRevision >= 0, job.source.baseRevision <= document.revision else { return "候选版本与当前文稿不兼容" }
        let crop = result.cropRect
        guard PixelRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
            .isInside(width: document.width, height: document.height) else { return "候选位置超出画布" }
        return nil
    }
    func loadCandidate(_ job: BridgeJob, _ result: BridgeResult) async {
        let key = candidateKey(job, result)
        guard candidates[key] == nil, !loadingCandidateKeys.contains(key),
              !hiddenJobIDs.contains(job.jobId), !removingJobIDs.contains(job.jobId), !unavailableJobIDs.contains(job.jobId), !pendingDeletionJobIDs.contains(job.jobId),
              let bridge, let pairing, let taskStore else { return }
        let documentID = document.id
        guard UUID(uuidString: job.source.documentId) == documentID else { return }
        let operationID = UUID()
        candidateLoadOperations[key] = operationID; loadingCandidateKeys.insert(key)
        defer {
            if candidateLoadOperations[key] == operationID {
                candidateLoadOperations.removeValue(forKey: key); loadingCandidateKeys.remove(key)
            }
        }
        do {
            let data = try await bridge.download(result: result, job: job)
            _ = try RasterImage.decode(data)
            let hidden = try await taskStore.hiddenJobIDs(documentID: job.source.documentId, pairing: pairing)
            guard matchesContext(bridge, pairing: pairing, documentID: documentID),
                  !hidden.contains(job.jobId), !hiddenJobIDs.contains(job.jobId), !removingJobIDs.contains(job.jobId),
                  !pendingDeletionJobIDs.contains(job.jobId), !unavailableJobIDs.contains(job.jobId),
                  jobs.contains(where: { $0.jobId == job.jobId }) else { return }
            candidates[key] = data
        } catch BridgeError.http(410, "job_deleted", _) {
            if matchesContext(bridge, pairing: pairing, documentID: documentID) { markCandidateUnavailable(job.jobId) }
        } catch { if matchesContext(bridge, pairing: pairing, documentID: documentID) { errorMessage = error.localizedDescription } }
    }
    func removeCandidateJob(_ job: BridgeJob, sourcePairing: BridgePairing, fromServer: Bool) async {
        guard !networkBusy, !removingJobIDs.contains(job.jobId), let bridge, let taskStore,
              let sourceID = UUID(uuidString: job.source.documentId), sourceID == document.id,
              matchesContext(bridge, pairing: sourcePairing, documentID: sourceID) else { return }
        let documentID = document.id
        let operationID = UUID()
        candidateRemovalOperations[job.jobId] = operationID; removingJobIDs.insert(job.jobId)
        defer {
            if candidateRemovalOperations[job.jobId] == operationID {
                candidateRemovalOperations.removeValue(forKey: job.jobId); removingJobIDs.remove(job.jobId)
            }
        }
        do {
            if fromServer {
                try await taskStore.markPendingDeletion(job, pairing: sourcePairing)
                if matchesContext(bridge, pairing: sourcePairing, documentID: documentID) { pendingDeletionJobIDs.insert(job.jobId) }
            }
            let receipt = fromServer ? try await bridge.deleteJob(job, pairing: sourcePairing) : nil
            // Finish this confirmed target even after navigation. UI changes still
            // belong only to the originating document/pairing.
            try await taskStore.removeCompletedJob(job, pairing: sourcePairing, serverDeletion: receipt)
            guard matchesContext(bridge, pairing: sourcePairing, documentID: documentID) else { return }
            hiddenJobIDs.insert(job.jobId); forgetCandidateJob(job.jobId)
            if fromServer { pendingDeletionJobIDs.remove(job.jobId); locallyRemovedJobIDs.remove(job.jobId) }
            else { locallyRemovedJobIDs.insert(job.jobId) }
            candidateManagementStatus = fromServer ? "候选及本机、Windows 桥接缓存已删除；工程图层保留" : "候选已从本机移除并清理缓存；Windows 文件保留"
        } catch {
            if matchesContext(bridge, pairing: sourcePairing, documentID: documentID) {
                candidateManagementStatus = "清理尚未完成，请重试；已确认的删除会在下次恢复任务时继续"
                errorMessage = error.localizedDescription
            }
        }
    }
    func applyCandidate(_ job: BridgeJob, _ result: BridgeResult, sourcePairing: BridgePairing,
                        allowChangedRevision: Bool = false, confirmedRevision: Int64? = nil) {
        guard let data = candidates[candidateKey(job, result)] else { return }
        report {
            guard pairing == sourcePairing else { throw BridgeError.wrongServer }
            guard !hiddenJobIDs.contains(job.jobId), !removingJobIDs.contains(job.jobId), !pendingDeletionJobIDs.contains(job.jobId) else { throw BridgeError.jobRemoved }
            if let confirmedRevision, confirmedRevision != document.revision { throw DocumentError.staleRevision }
            guard let documentID = UUID(uuidString: job.source.documentId) else { throw DocumentError.wrongDocument }
            let crop = result.cropRect
            let anchor = GenerationAnchor(documentID: documentID, baseRevision: job.source.baseRevision,
                canvasWidth: job.source.canvasSize.width, canvasHeight: job.source.canvasSize.height,
                cropRect: PixelRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height))
            _ = try editor.insertAIResult(pngData: data, key: AIResultKey(jobID: job.jobId, resultID: result.resultId), anchor: anchor,
                                          name: job.isSimulation ? "模拟候选" : "AI 候选", allowChangedRevision: allowChangedRevision)
            changed()
        }
    }
}
