import Foundation
import Synchronization
import Testing
@testable import KnotchyCore

/// A forgotten `release` fails the test after this instead of hanging the run.
private let heldCallLimit: Duration = .seconds(10)

final class FakeVMBackend: VMBackend {
    enum Call: Equatable, Sendable {
        case sweep(keeping: Set<String>)
        case preflight
        case start(String)
        case destroy(String)
        case forceDestroy(String)
        case fix(SetupIssue)
        case destroyBlocking([String])
        case stopService

        var kind: Kind {
            switch self {
            case .sweep: .sweep
            case .preflight: .preflight
            case .start: .start
            case .destroy: .destroy
            case .forceDestroy: .forceDestroy
            case .fix: .fix
            case .destroyBlocking: .destroyBlocking
            case .stopService: .stopService
            }
        }
    }

    enum Kind: Hashable, Sendable {
        case sweep, preflight, start, destroy, forceDestroy, fix, destroyBlocking, stopService
    }

    struct StartArguments: Equatable, Sendable {
        var id: String
        var url: URL
        var renderSize: PixelSize
        var blockCIDRs: [String]
    }

    private struct State {
        var calls: [Call] = []
        var startArguments: [StartArguments] = []
        var active = 0
        var maxActive = 0
        var held: Set<Kind> = []
        var nextParkID = 0
        var parked: [Kind: [(id: Int, continuation: CheckedContinuation<Void, Never>)]] = [:]
        var preflightResults: [PreflightResult] = []
        var startError: (any Error)?
        var destroyError: (any Error)?
        var forceDestroyError: (any Error)?
        var fixOutput: [String] = []
        var fixError: (any Error)?
        var runtimeStatus: RuntimeStatus = .current("1.4.1")
        var stopError: (any Error)?
    }

    private let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }
    var startArguments: [StartArguments] { state.withLock { $0.startArguments } }
    var maxConcurrentCalls: Int { state.withLock { $0.maxActive } }

    /// Used in order; after them, preflight is ready.
    func queuePreflight(_ results: PreflightResult...) {
        state.withLock { $0.preflightResults += results }
    }

    func failStarts(with error: (any Error)?) { state.withLock { $0.startError = error } }
    func failDestroys(with error: (any Error)?) { state.withLock { $0.destroyError = error } }
    func failForceDestroys(with error: (any Error)?) { state.withLock { $0.forceDestroyError = error } }

    func scriptFix(output: [String], error: (any Error)? = nil) {
        state.withLock {
            $0.fixOutput = output
            $0.fixError = error
        }
    }

    func hold(_ kind: Kind) {
        precondition(kind != .destroyBlocking, "destroyBlocking is synchronous and can't be held")
        _ = state.withLock { $0.held.insert(kind) }
    }

    func release(_ kind: Kind) {
        let parked = state.withLock { s in
            s.held.remove(kind)
            return s.parked.removeValue(forKey: kind) ?? []
        }
        for call in parked { call.continuation.resume() }
    }

    func parkedCount(_ kind: Kind) -> Int {
        state.withLock { $0.parked[kind]?.count ?? 0 }
    }

    func sweepOrphans(keeping: Set<String>) async {
        await begin(.sweep(keeping: keeping))
        end()
    }

    func preflight() async -> PreflightResult {
        await begin(.preflight)
        defer { end() }
        return state.withLock { s in
            s.preflightResults.isEmpty ? .ready(appRoot: "/fake/appRoot", staleImage: nil) : s.preflightResults.removeFirst()
        }
    }

    func start(id: String, url: URL, renderSize: PixelSize, blockCIDRs: [String]) async throws -> VMSession {
        state.withLock {
            $0.startArguments.append(StartArguments(id: id, url: url, renderSize: renderSize, blockCIDRs: blockCIDRs))
        }
        await begin(.start(id))
        defer { end() }
        if let error = state.withLock({ $0.startError }) { throw error }
        return VMSession(id: id, socketPath: "/fake/\(id).sock")
    }

    func destroy(id: String) async throws {
        await begin(.destroy(id))
        defer { end() }
        if let error = state.withLock({ $0.destroyError }) { throw error }
    }

    func forceDestroy(id: String) async throws {
        await begin(.forceDestroy(id))
        defer { end() }
        if let error = state.withLock({ $0.forceDestroyError }) { throw error }
    }

    func fix(_ issue: SetupIssue, output: @escaping @Sendable (String) -> Void) async throws {
        record(.fix(issue))
        state.withLock { $0.fixOutput }.forEach(output)
        await parkIfHeld(.fix)
        defer { end() }
        if let error = state.withLock({ $0.fixError }) { throw error }
    }

    func destroyBlocking(ids: [String], deadline: Duration) {
        state.withLock { $0.calls.append(.destroyBlocking(ids)) }
    }

    func setRuntimeStatus(_ status: RuntimeStatus) { state.withLock { $0.runtimeStatus = status } }
    func failStopService(with error: (any Error)?) { state.withLock { $0.stopError = error } }

    func runtimeStatus() async -> RuntimeStatus {
        state.withLock { $0.runtimeStatus }
    }

    func stopService() async throws {
        await begin(.stopService)
        defer { end() }
        if let error = state.withLock({ $0.stopError }) { throw error }
    }

    private func begin(_ call: Call) async {
        record(call)
        await parkIfHeld(call.kind)
    }

    private func record(_ call: Call) {
        state.withLock { s in
            s.calls.append(call)
            s.active += 1
            s.maxActive = max(s.maxActive, s.active)
        }
    }

    private func end() {
        state.withLock { $0.active -= 1 }
    }

    private func parkIfHeld(_ kind: Kind) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id: Int? = state.withLock { s in
                guard s.held.contains(kind) else { return nil }
                s.nextParkID += 1
                s.parked[kind, default: []].append((s.nextParkID, continuation))
                return s.nextParkID
            }
            guard let id else { return continuation.resume() }
            Task {
                try? await Task.sleep(for: heldCallLimit)
                let forgotten = self.state.withLock { s -> CheckedContinuation<Void, Never>? in
                    guard let index = s.parked[kind]?.firstIndex(where: { $0.id == id }) else { return nil }
                    return s.parked[kind]?.remove(at: index).continuation
                }
                if let forgotten {
                    Issue.record("A held \(kind) call was never released")
                    forgotten.resume()
                }
            }
        }
    }
}

/// Queued errors go to connects in call order; `connections` is in completion order.
final class FakeStreamConnector: StreamConnector {
    private struct State {
        var socketPaths: [String] = []
        var connections: [FakeStreamConnection] = []
        var errors: [StreamError] = []
        var held = false
        var nextParkID = 0
        var parked: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var socketPaths: [String] { state.withLock { $0.socketPaths } }
    var connections: [FakeStreamConnection] { state.withLock { $0.connections } }
    var parkedCount: Int { state.withLock { $0.parked.count } }

    func failNextConnect(with error: StreamError) {
        state.withLock { $0.errors.append(error) }
    }

    func hold() {
        state.withLock { $0.held = true }
    }

    func release() {
        let parked = state.withLock { s in
            s.held = false
            defer { s.parked = [] }
            return s.parked
        }
        for call in parked { call.continuation.resume() }
    }

    func connect(socketPath: String) async throws -> any StreamConnection {
        let scriptedError = state.withLock { s -> StreamError? in
            s.socketPaths.append(socketPath)
            return s.errors.isEmpty ? nil : s.errors.removeFirst()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id: Int? = state.withLock { s in
                guard s.held else { return nil }
                s.nextParkID += 1
                s.parked.append((s.nextParkID, continuation))
                return s.nextParkID
            }
            guard let id else { return continuation.resume() }
            Task {
                try? await Task.sleep(for: heldCallLimit)
                let forgotten = self.state.withLock { s -> CheckedContinuation<Void, Never>? in
                    guard let index = s.parked.firstIndex(where: { $0.id == id }) else { return nil }
                    return s.parked.remove(at: index).continuation
                }
                if let forgotten {
                    Issue.record("A held connect was never released")
                    forgotten.resume()
                }
            }
        }
        if let scriptedError { throw scriptedError }
        let connection = FakeStreamConnection(socketPath: socketPath)
        state.withLock { $0.connections.append(connection) }
        return connection
    }
}

final class FakeStreamConnection: StreamConnection {
    let socketPath: String
    let events: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation

    private struct State {
        var decodeEnabled = true
        var decodeChanges: [Bool] = []
        var sent: [InputEvent] = []
        var closed = false
    }

    private let state = Mutex(State())

    init(socketPath: String) {
        self.socketPath = socketPath
        let (stream, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        events = stream
        self.continuation = continuation
    }

    var decodeEnabled: Bool {
        get { state.withLock { $0.decodeEnabled } }
        set {
            state.withLock {
                $0.decodeEnabled = newValue
                $0.decodeChanges.append(newValue)
            }
        }
    }

    var decodeChanges: [Bool] { state.withLock { $0.decodeChanges } }
    var sent: [InputEvent] { state.withLock { $0.sent } }
    var isClosed: Bool { state.withLock { $0.closed } }

    func setFrameHandler(_ handler: @escaping @Sendable (DecodedFrame) -> Void) {}

    func send(_ input: InputEvent) {
        state.withLock { $0.sent.append(input) }
    }

    func close() {
        state.withLock { $0.closed = true }
        continuation.finish()
    }

    func emit(_ event: StreamEvent) {
        continuation.yield(event)
    }

    /// Without an `.ended` event, as a buggy client might.
    func finishEvents() {
        continuation.finish()
    }
}

final class FakeDiskSpace: DiskSpaceChecking {
    private let free = Mutex<Int64?>(100_000_000_000)

    var available: Int64? {
        get { free.withLock { $0 } }
        set { free.withLock { $0 = newValue } }
    }

    func bytesFree(atPath path: String) -> Int64? {
        free.withLock { $0 }
    }
}
