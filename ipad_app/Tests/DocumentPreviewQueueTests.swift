import XCTest
@testable import CompositorKit

final class DocumentPreviewQueueTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0, peak = 0, calls = 0
        func enter() { lock.lock(); active += 1; calls += 1; peak = max(peak,active); lock.unlock() }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
        func values() -> (Int,Int) { lock.lock(); defer { lock.unlock() }; return (peak,calls) }
    }

    func testDifferentPreviewToolsNeverAllocateConcurrently() async {
        let queue=DocumentPreviewQueue(),counter=Counter()
        await withTaskGroup(of:Void.self) { tasks in
            for _ in 0..<4 {
                tasks.addTask {
                    _=await queue.perform { counter.enter(); Thread.sleep(forTimeInterval:0.02); counter.leave(); return 1 }
                }
            }
        }
        XCTAssertEqual(counter.values().0,1)
        XCTAssertEqual(counter.values().1,4)
    }

    func testCancelledQueuedWorkDoesNotAllocateAfterRunningPreviewFinishes() async {
        let queue=DocumentPreviewQueue(),counter=Counter(),release=DispatchSemaphore(value:0)
        let started=expectation(description:"First preview owns the allocation")
        let first=Task { await queue.perform { started.fulfill(); release.wait(); return 1 } }
        await fulfillment(of:[started],timeout:2)
        let second=Task { await queue.perform { counter.enter(); counter.leave(); return 2 } }
        await Task.yield(); second.cancel(); release.signal()
        _=await first.value
        switch await second.value {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("A cancelled preview must not allocate")
        }
        XCTAssertEqual(counter.values().1,0)
    }
}
