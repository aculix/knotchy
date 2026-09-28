import Foundation
import Observation

/// The single-session state machine behind the notch UI. Inputs never block; backend calls run serially.
@MainActor
@Observable
public final class SessionController {
    // MARK: - Timings and limits

    public static let renderSize = PixelSize(width: 1024, height: 640)
    public static let foldGrace: Duration = .milliseconds(400)
    public static let neverEnteredFoldDelay: Duration = .seconds(30)
    public static let defaultIdleDestroyDelay: Duration = .seconds(5 * 60)
    public static let idleQuitDelay: Duration = .seconds(60)
    public static let destroyedDisplay: Duration = .milliseconds(1500)
    public static let endedDisplay: Duration = .seconds(3)
    public static let destroyStuckDisplay: Duration = .seconds(30)
    public static let noticeDisplay: Duration = .seconds(2)
    public static let progressLinger: Duration = .seconds(2)
    public static let minimumFreeBytes: Int64 = 2_000_000_000
    public static let setupOutputLimit = 200
    public static let stillBrokenMessage = "Setup finished, but the runtime still reports a problem."

    // MARK: - Outputs

    public private(set) var state: SessionState = .idle

    // MARK: - Preferences

    /// Takes effect the next time a session folds.
    public var idleDestroyDelay: Duration = SessionController.defaultIdleDestroyDelay
    public var opensExpanded = false
    public var quitsWhenIdle = true
    /// Opens the setup window; the app sets it.
    @ObservationIgnored public var showSetup: @MainActor () -> Void = {}

    public private(set) var setupFolded = false
    @ObservationIgnored private var setupOpenedByHover = false

    public private(set) var notice: Notice?
    public private(set) var progress: Int?
    public private(set) var openedURL: URL?
    /// Reported by the VM, so untrusted: shown, never opened or retried.
    public private(set) var pageURL: URL?
    public private(set) var setupLog: String?
    /// The latest setup action's last lines, for the setup window's details.
    public private(set) var setupOutput: [String] = []
    public private(set) var connection: (any StreamConnection)?
    public private(set) var staleImage: StaleImage?
    public private(set) var idleDeadline: ContinuousClock.Instant?

    public var countdown: Duration? {
        idleDeadline.map { max(.zero, $0 - clock.now) }
    }

    public nonisolated let liveIDs = LiveIDs()

    // MARK: - Dependencies

    private let backend: any VMBackend
    private let connector: any StreamConnector
    private let diskSpace: any DiskSpaceChecking
    private let clock: any KnotchyClock
    private let hostNetworks: () -> [String]
    private let requestQuit: @MainActor () -> Void
    private let makeSessionID: () -> String

    // MARK: - Internal state

    @MainActor
    private final class Session {
        let id: String
        let url: URL
        /// `backend.start` has been called, so a VM may exist.
        var startBegan = false
        var retired = false
        var contentReady = false
        var connection: (any StreamConnection)?
        var tasks: [Task<Void, Never>] = []

        init(id: String, url: URL) {
            self.id = id
            self.url = url
        }
    }

    private enum TimerKey: Hashable, Sendable {
        case foldGrace, neverEnteredFold, idleDestroy, transient, notice, progressHide, idleQuit
    }

    private enum RunMode: Equatable {
        /// From the notch or the menu: stops at the next card, as before.
        case link
        /// From the setup window.
        case window(continuing: Bool)
        /// The setup window's check: starts the service, never builds.
        case check
    }

    private struct SetupRun {
        var mode: RunMode
        /// The loop guard: each issue is fixed at most once per run.
        var fixed: [SetupIssue]
        var waiter: CheckedContinuation<SetupRunOutcome, Never>?
    }

    private let chain = BackendChain()
    private let timers: DeadlineTimers<TimerKey>
    // Invariants: at most one session isn't retired, and it is `current`; only `transition(to:)`
    // writes `state` (and owns its timers); while `settingUp`, only the setup outcome changes it.
    @ObservationIgnored private var current: Session?
    @ObservationIgnored private var pendingURL: URL?
    /// IDs whose destroy failed; they stay in `liveIDs`.
    @ObservationIgnored private var pendingCleanup: [String] = []
    @ObservationIgnored private var requestedImageUpdate: StaleImage?
    @ObservationIgnored private var lastProgressAt: ContinuousClock.Instant?
    @ObservationIgnored private var entered = false
    @ObservationIgnored private var pointerInside = false
    @ObservationIgnored private var focused = false
    @ObservationIgnored private var run: SetupRun?
    @ObservationIgnored private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The issues started automatically for the link now waiting; each is tried once per request.
    @ObservationIgnored private var autoFixed: (url: URL, issues: [SetupIssue])?

    public init(
        backend: any VMBackend,
        connector: any StreamConnector,
        diskSpace: any DiskSpaceChecking,
        clock: any KnotchyClock = SystemClock(),
        hostNetworks: @escaping () -> [String],
        requestQuit: @escaping @MainActor () -> Void,
        makeSessionID: @escaping () -> String = SessionController.randomSessionID
    ) {
        self.backend = backend
        self.connector = connector
        self.diskSpace = diskSpace
        self.clock = clock
        self.hostNetworks = hostNetworks
        self.requestQuit = requestQuit
        self.makeSessionID = makeSessionID
        timers = DeadlineTimers(clock: clock)
        timers.onFire = { [weak self] key in self?.timerFired(key) }
        enqueue { [backend] in await backend.sweepOrphans(keeping: []) }
        timers.set(.idleQuit, after: Self.idleQuitDelay)
    }

    /// `knotchy-<8 hex>`: the only names the launch sweep deletes.
    public nonisolated static func randomSessionID() -> String {
        "knotchy-" + String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    // MARK: - Links

    /// A new link always wins. Anything but http/https shows "No web link found".
    public func open(_ url: URL) {
        guard let url = LinkIntake.validate(url) else { return show(.noWebLink) }
        guard !chain.isClosed else { return }
        autoFixed = nil
        if case .settingUp = state {
            pendingURL = url
            setupFolded = false
        } else {
            startSession(url)
        }
    }

    public func open(text: String) {
        guard let url = LinkIntake.extractURL(from: text) else { return show(.noWebLink) }
        open(url)
    }

    // MARK: - Toolbar

    public func navigate(_ url: URL) {
        guard let url = LinkIntake.validate(url) else { return show(.noWebLink) }
        guard case .live = state, let connection else { return }
        openedURL = url
        pageURL = nil
        connection.send(.navigate(url.absoluteString))
    }

    public func goBack() { runScript("history.back()") }
    public func goForward() { runScript("history.forward()") }
    public func reload() { runScript("location.reload()") }

    private func runScript(_ javaScript: String) {
        guard case .live = state else { return }
        connection?.send(.script(javaScript))
    }

    // MARK: - Panel

    public func expand() {
        guard state == .live(.peek) else { return }
        entered = true
        focused = true
        transition(to: .live(.expanded))
    }

    public func shrink() {
        guard state == .live(.expanded) else { return }
        transition(to: .live(.peek))
    }

    public func pointerEntered() {
        pointerInside = true
        timers.cancel(.foldGrace)
        switch state {
        case .settingUp:
            if setupFolded { setupOpenedByHover = true }
            setupFolded = false
        case .starting(let step, folded: true):
            unfold(to: .starting(step, folded: false))
        case .live(.collapsed):
            unfold(to: .live(.peek))
        case .starting, .live:
            entered = true
            timers.cancel(.neverEnteredFold)
        default:
            break
        }
    }

    public func pointerExited() {
        pointerInside = false
        if isPeekLike, entered, !focused {
            timers.set(.foldGrace, after: Self.foldGrace)
        }
        if case .settingUp = state, setupOpenedByHover {
            timers.set(.foldGrace, after: Self.foldGrace)
        }
    }

    public func panelClicked() {
        guard isOpenPanel else { return }
        entered = true
        focused = true
        timers.cancel(.foldGrace)
        timers.cancel(.neverEnteredFold)
    }

    public func clickedOutside() {
        if isOpenPanel { fold() }
        if case .settingUp = state { setupFolded = true }
    }

    public func foldSetup() {
        if case .settingUp = state { setupFolded = true }
        setupOpenedByHover = false
    }

    private var isPeekLike: Bool {
        switch state {
        case .starting(_, folded: false), .live(.peek): true
        default: false
        }
    }

    private var isOpenPanel: Bool {
        isPeekLike || state == .live(.expanded)
    }

    private var isFolded: Bool {
        if case .starting(_, folded: true) = state { true } else { false }
    }

    private func fold() {
        focused = false
        pointerInside = false
        switch state {
        case .starting(let step, folded: false):
            transition(to: .starting(step, folded: true))
        case .live(.peek), .live(.expanded):
            transition(to: .live(.collapsed))
        default:
            break
        }
    }

    private func unfold(to newState: SessionState) {
        entered = true
        focused = false
        transition(to: newState)
    }

    // MARK: - Destroy, retry, dismiss

    public func destroy() {
        guard let session = current else { return }
        switch state {
        case .starting, .live:
            transition(to: .destroying)
            retire(session) { [weak self] gone in self?.destroyFinished(session, gone: gone) }
        default:
            break
        }
    }

    public func retry() {
        switch state {
        case .failed(.start):
            autoFixed = nil   // A retry is a new request: it gets its own automatic start.
            if let url = current?.url { startSession(url, pointerStays: true) }
        case .failed(.destroyStuck):
            guard let session = current else { return }
            pendingCleanup.removeAll { $0 == session.id }
            transition(to: .destroying)
            enqueue { [weak self] in
                await self?.runDestroy(session) { gone in self?.destroyFinished(session, gone: gone) }
            }
        default:
            break
        }
    }

    public func dismiss() {
        switch state {
        case .failed(.start):
            enterIdle()
        case .setupRequired:
            pendingURL = nil
            enterIdle()
        default:
            break
        }
    }

    // MARK: - Setup

    public func performSetupAction() {
        guard case .setupRequired(let issue, _) = state else { return }
        switch issue {
        case .cliMissing, .cliOutdated:
            showSetup()
        case .lowDisk:
            break
        default:
            startRun(issue, mode: .link, folded: false)
        }
    }

    /// Rebuilds the image once this session ends.
    public func requestImageUpdate() {
        guard let stale = staleImage else { return }
        staleImage = nil
        requestedImageUpdate = stale
    }

    public func rebuildImage() {
        switch state {
        case .idle:
            startRun(.imageStale(builtDaysAgo: nil), mode: .link, folded: false)
        case .settingUp:
            break
        default:
            staleImage = nil
            requestedImageUpdate = StaleImage(builtDaysAgo: nil)
        }
    }

    public func showPanel() {
        switch state {
        case .settingUp:
            setupFolded = false
            setupOpenedByHover = false
        case .starting(let step, folded: true): unfold(to: .starting(step, folded: false))
        case .live(.collapsed): unfold(to: .live(.peek))
        default: break
        }
    }

    public func dismissStaleImageWarning() {
        staleImage = nil
    }

    /// Quit path: queued backend jobs never start after this. One already running may still call
    /// the backend, which is safe because `destroyBlocking` then blocks the main thread until exit.
    public func closeBackendChain() {
        chain.close()
    }

    // MARK: - Setup window

    /// Runs `issue`'s fix folded into the notch; when `continuing`, also each fixable issue preflight
    /// finds next, each at most once. A waiting link opens only once everything is ready. nil when busy.
    public func runSetup(_ issue: SetupIssue, continuing: Bool) async -> SetupRunOutcome? {
        guard acceptsSetupWindow else { return nil }
        return await withCheckedContinuation { continuation in
            startRun(issue, mode: .window(continuing: continuing), folded: true, waiter: continuation)
        }
    }

    /// Preflight for the setup window: starts a stopped service or missing kernel, never builds. nil when busy.
    public func checkSetup() async -> SetupRunOutcome? {
        guard acceptsSetupWindow else { return nil }
        let preflight = await onChain { [backend] in await backend.preflight() }
        guard acceptsSetupWindow else { return nil }
        switch preflight {
        case .ready:
            // Fixed outside Knotchy while a card held a link: open it.
            if case .setupRequired = state, let url = pendingURL { startSession(url, pointerStays: true) }
            return .ready
        case .issue(let issue) where Self.fixes(issue, in: .check):
            return await withCheckedContinuation { continuation in
                startRun(issue, mode: .check, folded: true, waiter: continuation)
            }
        case .issue(let issue):
            return .needs(issue)
        }
    }

    /// Around a runtime install: links wait, and an update stops the service first.
    public func beginRuntimeInstall(replacing found: String?) async -> Result<Void, RuntimeHoldRefusal> {
        guard acceptsSetupWindow else {
            if case .settingUp = state { return .failure(.setupRunning) }
            return .failure(.sessionOpen)
        }
        setupLog = nil
        setupOutput = []
        transition(to: .settingUp(found.map { .cliOutdated(found: $0) } ?? .cliMissing))
        setupFolded = true
        guard found != nil else { return .success(()) }
        let stopped: String? = await onChain { [backend] in
            do {
                try await backend.stopService()
                return nil
            } catch {
                return Self.message(for: error)
            }
        }
        guard let stopped else { return .success(()) }
        _ = await finishRuntimeInstall(.failed(stopped))
        return .failure(.stopFailed(stopped))
    }

    /// After an install, starts the service and builds, like `runSetup(continuing: true)`.
    public func finishRuntimeInstall(_ result: RuntimeInstallResult) async -> SetupRunOutcome {
        guard case .settingUp(let issue) = state, Self.isRuntimeInstall(issue), run == nil else {
            return .failed(.cliMissing, "No runtime install was in progress.")
        }
        switch result {
        case .installed:
            return await withCheckedContinuation { continuation in
                startRun(.serviceStopped, mode: .window(continuing: true), folded: false, waiter: continuation)
            }
        case .cancelled:
            endHold(issue, error: nil)
            return .needs(issue)
        case .failed(let message):
            endHold(issue, error: message)
            return .failed(issue, message)
        }
    }

    private func endHold(_ issue: SetupIssue, error: String?) {
        if pendingURL != nil { transition(to: .setupRequired(issue, error: error)) } else { enterIdle() }
    }

    private static func isRuntimeInstall(_ issue: SetupIssue) -> Bool {
        switch issue {
        case .cliMissing, .cliOutdated: true
        default: false
        }
    }

    public func waitWhileSettingUp() async {
        guard case .settingUp = state else { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    public func runtimeStatus() async -> RuntimeStatus {
        await backend.runtimeStatus()
    }

    /// The states where no VM exists. A stuck destroy may still have one.
    private var acceptsSetupWindow: Bool {
        switch state {
        case .idle, .setupRequired, .failed(.start), .failed(.ended), .destroyed: true
        default: false
        }
    }

    /// After `closeBackendChain()` the job never runs and this never returns; that only happens while quitting.
    private func onChain<T: Sendable>(_ job: @escaping @MainActor () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: await job()) }
        }
    }

    // MARK: - Session lifecycle

    private func startSession(_ url: URL, pointerStays: Bool = false) {
        let pointerOnPanel = pointerStays && pointerInside
        let startsFolded: Bool
        if case .settingUp = state { startsFolded = setupFolded } else { startsFolded = false }
        if let old = current { retire(old) }
        let session = Session(id: makeSessionID(), url: url)
        current = session
        pendingURL = nil
        setupLog = nil
        openedURL = url
        pageURL = nil
        connection = nil
        staleImage = nil
        progress = nil
        lastProgressAt = nil
        entered = pointerOnPanel
        pointerInside = pointerOnPanel
        focused = false
        for key in [TimerKey.foldGrace, .neverEnteredFold, .progressHide] { timers.cancel(key) }
        liveIDs.insert(session.id)
        transition(to: .starting(.booting, folded: startsFolded))
        enqueue { [weak self] in await self?.runStart(session) }
    }

    private func retire(_ session: Session, onGone: (@MainActor (Bool) -> Void)? = nil) {
        guard !session.retired else { return }
        session.retired = true
        for task in session.tasks { task.cancel() }
        session.connection?.close()
        session.connection = nil
        if current === session {
            connection = nil
            progress = nil
            timers.cancel(.progressHide)
        }
        enqueue { [weak self] in await self?.runDestroy(session, onGone: onGone) }
    }

    private func runStart(_ session: Session) async {
        guard !session.retired else { return }
        let preflight = await backend.preflight()
        guard !session.retired else { return }
        switch preflight {
        case .issue(let issue):
            return needsSetup(issue, for: session)
        case .ready(let appRoot, let stale):
            let free = await diskSpace.bytesFree(atPath: appRoot)
            guard !session.retired else { return }
            if let free, free < Self.minimumFreeBytes {
                return needsSetup(.lowDisk(bytesFree: free), for: session)
            }
            if requestedImageUpdate == nil { staleImage = stale }
        }

        session.startBegan = true
        do {
            let vm = try await backend.start(id: session.id, url: session.url,
                                             renderSize: Self.renderSize, blockCIDRs: hostNetworks())
            guard !session.retired else { return }   // Superseded mid-start: its destroy job runs next.
            transition(to: .starting(.connecting, folded: isFolded))
            session.tasks.append(Task { [weak self] in await self?.connect(session, socketPath: vm.socketPath) })
        } catch {
            guard !session.retired else { return }
            retire(session)
            transition(to: .failed(.start(Self.message(for: error))))
        }
    }

    /// No VM exists yet, so there is nothing to destroy. Starting the service needs no password, so it just happens.
    private func needsSetup(_ issue: SetupIssue, for session: Session) {
        session.retired = true
        liveIDs.remove(session.id)
        pendingURL = session.url
        guard issue == .serviceStopped || issue == .kernelMissing else {
            return transition(to: .setupRequired(issue, error: nil))
        }
        var tried = autoFixed?.url == session.url ? autoFixed?.issues ?? [] : []
        guard !tried.contains(where: { Self.sameFix($0, issue) }) else {
            return transition(to: .setupRequired(issue, error: Self.stillBrokenMessage))
        }
        tried.append(issue)
        autoFixed = (session.url, tried)
        startRun(issue, mode: .link, folded: false)
    }

    private func connect(_ session: Session, socketPath: String) async {
        let outcome: Result<any StreamConnection, any Error>
        do {
            outcome = .success(try await connector.connect(socketPath: socketPath))
        } catch {
            outcome = .failure(error)
        }
        guard !session.retired else {
            if case .success(let late) = outcome { late.close() }
            return
        }
        switch outcome {
        case .success(let stream):
            session.connection = stream
            connection = stream
            transition(to: .starting(.loading, folded: isFolded))
            session.tasks.append(Task { [weak self] in
                for await event in stream.events { self?.handle(event, from: session) }
                // A stream that finishes without `.ended` has still ended.
                self?.handle(.ended(.closed), from: session)
            })
        case .failure(StreamError.versionMismatch(let found, let need)):
            retire(session)
            pendingURL = session.url
            transition(to: .setupRequired(.imageOutdated(found: found, need: need), error: nil))
        case .failure(let error):
            retire(session)
            transition(to: .failed(.start(Self.message(for: error))))
        }
    }

    private func handle(_ event: StreamEvent, from session: Session) {
        guard current === session, !session.retired else { return }
        switch event {
        case .hello:
            break
        case .progress(let percent):
            progressChanged(percent)
        case .pageURL(let url):
            pageURL = url
        case .contentReady:
            contentReady(session)
        case .ended(let reason):
            let wasStarting = if case .starting = state { true } else { false }
            retire(session)
            transition(to: .failed(wasStarting ? .start(Self.message(for: reason)) : .ended(reason)))
        }
    }

    private func contentReady(_ session: Session) {
        guard case .starting(_, let folded) = state, !session.contentReady else { return }
        session.contentReady = true
        if folded {
            transition(to: .live(.collapsed))
        } else if opensExpanded {
            transition(to: .live(.expanded))
        } else {
            transition(to: .live(.peek))
            if !entered { timers.set(.neverEnteredFold, after: Self.neverEnteredFoldDelay) }
        }
        scheduleProgressHide()
    }

    private func runDestroy(_ session: Session, onGone: (@MainActor (Bool) -> Void)?) async {
        guard session.startBegan else {
            liveIDs.remove(session.id)
            onGone?(true)
            return
        }
        do {
            try await backend.destroy(id: session.id)
            pendingCleanup.removeAll { $0 == session.id }
            liveIDs.remove(session.id)
            onGone?(true)
        } catch {
            if !pendingCleanup.contains(session.id) { pendingCleanup.append(session.id) }
            onGone?(false)
        }
    }

    private func destroyFinished(_ session: Session, gone: Bool) {
        guard current === session, state == .destroying else { return }
        transition(to: gone ? .destroyed : .failed(.destroyStuck))
    }

    private func enterIdle() {
        openedURL = nil
        pageURL = nil
        progress = nil
        staleImage = nil
        setupLog = nil
        connection = nil
        entered = false
        pointerInside = false
        focused = false
        if let update = requestedImageUpdate {
            requestedImageUpdate = nil
            return startRun(.imageStale(builtDaysAgo: update.builtDaysAgo), mode: .link, folded: false)
        }
        transition(to: .idle)
    }

    // MARK: - Progress bar

    private func progressChanged(_ percent: Int) {
        lastProgressAt = clock.now
        if percent >= 100 {
            progress = nil
            timers.cancel(.progressHide)
        } else {
            progress = percent
            scheduleProgressHide()
        }
    }

    /// Hides the bar 2 s after the last PROGRESS, so a load that never reports 100 doesn't leave it up.
    private func scheduleProgressHide() {
        guard current?.contentReady == true, progress != nil, let last = lastProgressAt else { return }
        let hideAt = last + Self.progressLinger
        if hideAt <= clock.now {
            progress = nil
        } else {
            timers.set(.progressHide, at: hideAt)
        }
    }

    // MARK: - Setup actions

    private func runSetupAction(_ issue: SetupIssue, folded: Bool = false) {
        setupLog = nil
        setupOutput = []
        transition(to: .settingUp(issue))
        if folded { setupFolded = true }
        let (lines, sink) = AsyncStream.makeStream(of: String.self)
        let showLines = Task { [weak self] in
            for await line in lines { self?.record(line) }
        }
        enqueue { [weak self, backend] in
            let outcome: Result<Void, any Error>
            do {
                try await backend.fix(issue) { sink.yield($0) }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            sink.finish()
            await showLines.value   // Every line is shown before the outcome.
            await self?.setupFinished(issue, outcome)
        }
    }

    private func record(_ line: String) {
        setupLog = line
        setupOutput.append(line)
        if setupOutput.count > Self.setupOutputLimit {
            setupOutput.removeFirst(setupOutput.count - Self.setupOutputLimit)
        }
    }

    private func startRun(_ issue: SetupIssue, mode: RunMode, folded: Bool,
                          waiter: CheckedContinuation<SetupRunOutcome, Never>? = nil) {
        if run != nil { endRun(.needs(issue)) }   // Never happens today; it keeps "every waiter resumes once" true.
        run = SetupRun(mode: mode, fixed: [issue], waiter: waiter)
        runSetupAction(issue, folded: folded)
    }

    private func endRun(_ outcome: SetupRunOutcome) {
        let waiter = run?.waiter
        run = nil
        waiter?.resume(returning: outcome)
    }

    /// Link runs leave a card, as before; window runs leave one only for a waiting link.
    private func stop(_ outcome: SetupRunOutcome, card: SessionState, mode: RunMode) {
        endRun(outcome)
        if mode == .link || pendingURL != nil { transition(to: card) } else { enterIdle() }
    }

    private static func fixes(_ issue: SetupIssue, in mode: RunMode) -> Bool {
        switch (mode, issue) {
        case (.window(continuing: true), .serviceStopped), (.window(continuing: true), .kernelMissing),
             (.window(continuing: true), .imageMissing), (.window(continuing: true), .imageOutdated),
             (.check, .serviceStopped), (.check, .kernelMissing):
            true
        default:
            false
        }
    }

    /// The backend runs one command for each group, so another issue from the same group means it didn't help.
    private static func sameFix(_ a: SetupIssue, _ b: SetupIssue) -> Bool {
        func group(_ issue: SetupIssue) -> Int? {
            switch issue {
            case .serviceStopped, .kernelMissing: 0
            case .imageMissing, .imageOutdated, .imageStale: 1
            default: nil
            }
        }
        guard let first = group(a) else { return a == b }
        return first == group(b)
    }

    private func setupFinished(_ issue: SetupIssue, _ outcome: Result<Void, any Error>) async {
        guard state == .settingUp(issue) else { return }
        let mode = run?.mode ?? .link
        if case .failure(let error) = outcome {
            let message = Self.message(for: error)
            // A failed "Update now" rebuild never blocks a link.
            if case .imageStale = issue, let url = pendingURL {
                endRun(.failed(issue, message))
                return startSession(url, pointerStays: true)
            }
            return stop(.failed(issue, message), card: .setupRequired(issue, error: message), mode: mode)
        }
        switch issue {
        case .imageMissing, .imageOutdated, .imageStale: requestedImageUpdate = nil
        default: break
        }
        if mode == .link, let url = pendingURL {
            endRun(.ready)
            return startSession(url, pointerStays: true)
        }
        let preflight = await backend.preflight()
        guard state == .settingUp(issue) else { return }
        switch preflight {
        case .ready:
            endRun(.ready)
            if let url = pendingURL { return startSession(url, pointerStays: true) }
            enterIdle()
        case .issue(let next) where mode == .link:
            endRun(.needs(next))
            if let url = pendingURL { return startSession(url, pointerStays: true) }
            transition(to: .setupRequired(next, error: nil))
        case .issue(let next) where run?.fixed.contains(where: { Self.sameFix($0, next) }) == true:
            stop(.failed(next, Self.stillBrokenMessage), card: .setupRequired(next, error: Self.stillBrokenMessage), mode: mode)
        case .issue(let next) where Self.fixes(next, in: mode):
            run?.fixed.append(next)
            runSetupAction(next)
        case .issue(let next):
            stop(.needs(next), card: .setupRequired(next, error: nil), mode: mode)
        }
    }

    // MARK: - Backend chain

    /// After each job, one VM left by an earlier failed destroy gets a retry, taking turns.
    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        chain.enqueue { [weak self] in
            let stuckBefore = self?.pendingCleanup ?? []
            await job()
            await self?.retryPendingCleanup(among: stuckBefore)
        }
    }

    private func retryPendingCleanup(among candidates: [String]) async {
        guard let id = candidates.first(where: pendingCleanup.contains) else { return }
        do {
            try await backend.forceDestroy(id: id)
            pendingCleanup.removeAll { $0 == id }
            liveIDs.remove(id)
        } catch {
            // Move it to the back so a VM stuck for good doesn't starve the others.
            pendingCleanup.removeAll { $0 == id }
            pendingCleanup.append(id)
        }
    }

    // MARK: - State and timers

    private func transition(to newState: SessionState) {
        let oldState = state
        guard newState != oldState else { return }
        state = newState
        if case .settingUp = newState {} else {
            setupFolded = false
            setupOpenedByHover = false
        }

        if !isPeekLike { timers.cancel(.foldGrace) }
        if newState != .live(.peek) { timers.cancel(.neverEnteredFold) }

        if newState == .live(.collapsed) {
            timers.set(.idleDestroy, after: idleDestroyDelay)
            idleDeadline = timers.deadline(of: .idleDestroy)
            connection?.decodeEnabled = false
        } else if oldState == .live(.collapsed) {
            timers.cancel(.idleDestroy)
            idleDeadline = nil
            if case .live = newState { connection?.decodeEnabled = true }
        }

        switch newState {
        case .destroyed: timers.set(.transient, after: Self.destroyedDisplay)
        case .failed(.ended): timers.set(.transient, after: Self.endedDisplay)
        case .failed(.destroyStuck): timers.set(.transient, after: Self.destroyStuckDisplay)
        default: timers.cancel(.transient)
        }

        if newState == .idle {
            timers.set(.idleQuit, after: Self.idleQuitDelay)
        } else {
            timers.cancel(.idleQuit)
        }

        if case .settingUp(let issue) = oldState {
            if case .settingUp = newState {} else { settled(after: issue) }
        }
    }

    /// So a waiting setup window never hangs, whatever ended the setup.
    private func settled(after issue: SetupIssue) {
        if run != nil { endRun(.needs(issue)) }
        let waiters = settleWaiters
        settleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func show(_ newNotice: Notice) {
        notice = newNotice
        timers.set(.notice, after: Self.noticeDisplay)
    }

    private func timerFired(_ key: TimerKey) {
        switch key {
        case .foldGrace:
            if isPeekLike, entered, !pointerInside, !focused { fold() }
            if case .settingUp = state, setupOpenedByHover, !pointerInside {
                setupOpenedByHover = false
                setupFolded = true
            }
        case .neverEnteredFold:
            if state == .live(.peek), !entered { fold() }
        case .idleDestroy:
            destroy()
        case .transient:
            enterIdle()
        case .notice:
            notice = nil
        case .progressHide:
            progress = nil
        case .idleQuit:
            if quitsWhenIdle { requestQuit() }
        }
    }

    nonisolated static func message(for error: any Error) -> String {
        switch error {
        case VMBackendError.failed(let message): message
        case StreamError.protocolViolation(let detail): "The VM sent a malformed message: \(detail)."
        case StreamError.timedOut: "The VM didn't answer in time."
        case StreamError.refused: "Couldn't connect to the VM."
        default: String(describing: error)
        }
    }

    nonisolated static func message(for reason: EndReason) -> String {
        switch reason {
        case .closed: "The VM closed the connection."
        case .protocolViolation(let detail): "The VM sent a malformed message: \(detail)."
        case .noFirstFrame: "The VM didn't send a first frame in time."
        case .decodeErrors: "The video stream couldn't be decoded."
        case .socketError(let detail): "The connection to the VM failed: \(detail)."
        }
    }

    // MARK: - Test hooks

    func fireDueTimers() {
        timers.fireDue()
    }

    func waitForBackendIdle() async {
        await chain.waitUntilIdle()
    }

    /// Call once the session is retired: a live session's events task runs until its stream ends.
    func waitForSessionTasks() async {
        for task in current?.tasks ?? [] { await task.value }
    }
}
