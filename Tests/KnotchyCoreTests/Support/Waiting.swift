import Testing

/// For work on other executors; controller timers run on the `TestClock` and never need it.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("Timed out waiting until \(description)", sourceLocation: sourceLocation)
            return
        }
        do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
    }
}
