import Foundation
import Testing
@testable import KnotchyCore

@MainActor
struct BackendChainTests {
    @Test func runsJobsOneAtATimeInOrder() async {
        let chain = BackendChain()
        var log: [String] = []
        for name in ["a", "b", "c"] {
            chain.enqueue {
                log.append("\(name) begins")
                await Task.yield()
                log.append("\(name) ends")
            }
        }
        await chain.waitUntilIdle()
        #expect(log == ["a begins", "a ends", "b begins", "b ends", "c begins", "c ends"])
    }

    @Test func waitsForJobsEnqueuedByJobs() async {
        let chain = BackendChain()
        var log: [String] = []
        chain.enqueue {
            log.append("outer")
            chain.enqueue {
                await Task.yield()   // Still running when the outer job's Task finishes.
                log.append("inner")
            }
        }
        await chain.waitUntilIdle()
        #expect(log == ["outer", "inner"])
    }

    @Test func closingSkipsJobsThatHaveNotStarted() async {
        let chain = BackendChain()
        var log: [String] = []
        chain.enqueue {
            log.append("running")
            chain.close()
        }
        chain.enqueue { log.append("queued") }
        await chain.waitUntilIdle()
        chain.enqueue { log.append("after close") }
        await chain.waitUntilIdle()
        #expect(log == ["running"])
    }

    @Test func liveIDsAreASnapshot() {
        let ids = LiveIDs()
        ids.insert("knotchy-00000001")
        ids.insert("knotchy-00000002")
        ids.remove("knotchy-00000001")
        #expect(ids.snapshot == ["knotchy-00000002"])
    }

    @Test nonisolated func liveIDsCanBeUsedFromManyThreadsAtOnce() {
        let ids = LiveIDs()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            ids.insert("knotchy-\(i)")
            _ = ids.snapshot
            if i.isMultiple(of: 2) { ids.remove("knotchy-\(i)") }
        }
        #expect(ids.snapshot.count == 500)
    }
}
