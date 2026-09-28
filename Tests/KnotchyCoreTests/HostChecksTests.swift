import Testing
@testable import KnotchyCore

struct HostChecksTests {
    @Test func unsupportedMacsAlwaysSeeTheWindow() {
        #expect(SetupLaunchRule.shouldOpen(hostSupported: false, setupCompleted: true, runtime: .current("1.4.1")))
    }

    @Test func theFirstLaunchAlwaysSeesTheWindow() {
        #expect(SetupLaunchRule.shouldOpen(hostSupported: true, setupCompleted: false, runtime: .current("1.4.1")))
    }

    @Test func anUnsupportedMacOrAFirstLaunchOpensItWhateverTheRuntime() {
        #expect(SetupLaunchRule.shouldOpen(hostSupported: false, setupCompleted: false, runtime: .missing))
        #expect(SetupLaunchRule.shouldOpen(hostSupported: true, setupCompleted: false, runtime: .missing))
        #expect(SetupLaunchRule.shouldOpen(hostSupported: true, setupCompleted: false, runtime: .outdated("1.3.0")))
    }

    @Test func laterOnlyAMissingOrOldRuntimeOpensIt() {
        #expect(SetupLaunchRule.shouldOpen(hostSupported: true, setupCompleted: true, runtime: .missing))
        #expect(SetupLaunchRule.shouldOpen(hostSupported: true, setupCompleted: true, runtime: .outdated("1.3.0")))
        #expect(!SetupLaunchRule.shouldOpen(hostSupported: true, setupCompleted: true, runtime: .current("1.4.1")))
        #expect(!SetupLaunchRule.shouldOpen(hostSupported: true, setupCompleted: true, runtime: .current(nil)))
    }

    @MainActor @Test func thisMacCanRunVirtualMachines() {
        #expect(SystemHost.unsupported() == nil)
    }

    @Test func factsIncludeTheSystemAndFreeSpace() async {
        let facts = await SystemHost().facts()
        #expect(facts.osVersion.hasPrefix("macOS "))
        #expect((facts.bytesFree ?? 0) > 0)
    }
}
