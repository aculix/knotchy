import Testing
@testable import KnotchyCore

struct ContainerRuntimeTests {
    @Test func readsTheVersionFromTheCLIOutput() {
        #expect(ContainerRuntime.version(in: "container CLI version 1.4.1 (build: release, commit: 9a8917c)\n") == "1.4.1")
        #expect(ContainerRuntime.version(in: "warning: x\ncontainer CLI version 2.0 (build: debug)") == "2.0")
        #expect(ContainerRuntime.version(in: "container version 1.4.1") == nil)
    }

    @Test func comparesVersionsNumerically() {
        #expect(ContainerRuntime.isOlder("1.3.9", than: "1.4.0"))
        #expect(ContainerRuntime.isOlder("1.4", than: "1.4.1"))
        #expect(!ContainerRuntime.isOlder("1.10.0", than: "1.4.0"))
        #expect(!ContainerRuntime.isOlder("1.4.0", than: "1.4"))
    }

    @Test func judgesAnInstalledRuntime() {
        #expect(ContainerRuntime.status(versionOutput: nil) == .missing)
        #expect(ContainerRuntime.status(versionOutput: "container CLI version 1.3.1 (build: release)") == .outdated("1.3.1"))
        #expect(ContainerRuntime.status(versionOutput: "container CLI version 1.4.1 (build: release)") == .current("1.4.1"))
        #expect(ContainerRuntime.status(versionOutput: "container CLI version 9.0.0") == .current("9.0.0"))
    }

    @Test func unreadableOutputNeverTriggersAnUpdate() {
        #expect(ContainerRuntime.status(versionOutput: "container 3 (a new format)") == .current(nil))
        #expect(ContainerRuntime.status(versionOutput: "") == .current(nil))
    }

    @Test func thePinnedReleaseIsNewEnough() {
        #expect(!ContainerRuntime.isOlder(ContainerRuntime.pinned.version, than: ContainerRuntime.minimumVersion))
        #expect(ContainerRuntime.pinned.sha256.count == 64)
    }
}
