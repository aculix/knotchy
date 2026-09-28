import Testing
@testable import KnotchyCore

@Suite(.timeLimit(.minutes(1)))
struct TestClockTests {
    @Test func sleepReturnsOnlyOnceTimeIsAdvancedPastTheDeadline() async throws {
        let clock = TestClock()
        let deadline = clock.now + .seconds(10)
        let sleeper = Task { try await clock.sleep(until: deadline) }
        await waitUntil("the task sleeps") { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(9))
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(clock.sleeperCount == 0)
    }

    @Test func sleepingUntilNowOrThePastReturnsImmediately() async throws {
        let clock = TestClock()
        try await clock.sleep(until: clock.now)
        try await clock.sleep(until: clock.now - .seconds(1))
    }

    @MainActor
    @Test func aSleepInAnAlreadyCancelledTaskThrows() async {
        @MainActor final class Outcome {
            var error: (any Error)?
            var finished = false
        }
        let clock = TestClock()
        let outcome = Outcome()
        Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await clock.sleep(until: clock.now + .seconds(10)) } catch { outcome.error = error }
            outcome.finished = true
        }
        // Bounded: a sleep that wrongly registers would never return.
        await waitUntil("the sleep ends") { outcome.finished }
        #expect(outcome.error is CancellationError)
        #expect(clock.sleeperCount == 0)
    }

    @Test func cancellingASleeperThrowsAndForgetsIt() async {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(until: clock.now + .seconds(10)) }
        await waitUntil("the task sleeps") { clock.sleeperCount == 1 }

        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }
}

@MainActor
struct DeadlineTimersTests {
    @Test func firesDueDeadlinesInOrder() {
        let clock = TestClock()
        let timers = DeadlineTimers<String>(clock: clock)
        var fired: [String] = []
        timers.onFire = { fired.append($0) }

        // Seven keys share a deadline, so a lost tie-break shows up nearly every run.
        let ties = (1...6).map { "tie\($0)" }
        timers.set("late", after: .seconds(2))
        timers.set("early", after: .seconds(1))
        for key in ties { timers.set(key, after: .seconds(2)) }
        clock.advance(by: .milliseconds(999))
        timers.fireDue()
        #expect(fired == [])

        clock.advance(by: .seconds(2))
        timers.fireDue()
        #expect(fired == ["early", "late"] + ties)

        timers.fireDue()
        #expect(fired == ["early", "late"] + ties)
    }

    @Test func settingAKeyAgainReplacesItsDeadline() {
        let clock = TestClock()
        let timers = DeadlineTimers<String>(clock: clock)
        var fired: [String] = []
        timers.onFire = { fired.append($0) }

        timers.set("a", after: .seconds(1))
        timers.set("a", after: .seconds(5))
        #expect(timers.deadline(of: "a") == clock.now + .seconds(5))
        clock.advance(by: .seconds(4))
        timers.fireDue()
        #expect(fired == [])
    }

    @Test func cancelledDeadlinesNeverFire() {
        let clock = TestClock()
        let timers = DeadlineTimers<String>(clock: clock)
        var fired: [String] = []
        timers.onFire = { fired.append($0) }

        timers.set("a", after: .seconds(1))
        timers.cancel("a")
        clock.advance(by: .seconds(2))
        timers.fireDue()
        #expect(fired == [])
        #expect(timers.deadline(of: "a") == nil)
    }

    @Test func onFireMaySetAndCancelTimers() {
        let clock = TestClock()
        let timers = DeadlineTimers<String>(clock: clock)
        var fired: [String] = []
        timers.onFire = { [unowned timers] key in
            fired.append(key)
            if key == "a" {
                timers.cancel("b")
                timers.set("c", after: .zero)
                timers.set("d", after: .seconds(1))
            }
        }
        timers.set("a", after: .seconds(1))
        timers.set("b", after: .seconds(1))
        clock.advance(by: .seconds(1))
        timers.fireDue()
        #expect(fired == ["a", "c"])
        #expect(timers.deadline(of: "d") == clock.now + .seconds(1))
    }

    @Test func theDriverFiresEveryTimerInDeadlineOrder() async {
        let clock = TestClock()
        let timers = DeadlineTimers<String>(clock: clock)
        var fired: [String] = []
        timers.onFire = { fired.append($0) }

        timers.set("b", after: .seconds(2))
        timers.set("a", after: .seconds(1))
        await waitUntil("the driver sleeps") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        await waitUntil("the driver fires a") { fired == ["a"] }
        await waitUntil("the driver sleeps again") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        await waitUntil("the driver fires b") { fired == ["a", "b"] }
    }

    @Test func theDriverFiresWithoutHelp() async {
        let clock = TestClock()
        let timers = DeadlineTimers<String>(clock: clock)
        var fired: [String] = []
        timers.onFire = { fired.append($0) }

        timers.set("a", after: .seconds(1))
        await waitUntil("the driver sleeps") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        await waitUntil("the driver fires") { fired == ["a"] }
    }
}
