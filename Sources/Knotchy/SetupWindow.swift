import AppKit
import KnotchyCore
import SwiftUI

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    enum Content {
        case setup(SetupFlow)
        case unsupported(Unsupported)
    }

    private let content: Content
    private(set) var window: NSWindow?

    init(_ content: Content) {
        self.content = content
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // An accessory app's windows open behind the frontmost app unless it activates first.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if case .setup(let flow) = content { Task { await flow.refresh() } }
    }

    private func makeWindow() -> NSWindow {
        let root = switch content {
        case .setup(let flow): AnyView(SetupView(flow: flow) { [weak self] in self?.window?.close() })
        case .unsupported(let reason): AnyView(UnsupportedView(reason: reason))
        }
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Knotchy"
        window.isReleasedWhenClosed = false
        window.setContentSize(host.view.fittingSize)
        window.center()
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        switch content {
        case .unsupported:
            NSApp.terminate(nil)
        case .setup(let flow):
            if flow.allRequiredDone { UserDefaults.standard.set(true, forKey: SetupLaunchRule.completedKey) }
        }
    }
}

struct SetupView: View {
    let flow: SetupFlow
    let close: () -> Void
    @State private var browser = ChromeExtension.installedBrowser()
    @State private var addedToBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Knotchy").font(.title2.weight(.semibold))
                    Text("A few things to set up before your first link.").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(spacing: 0) {
                    SetupRow(title: "This Mac", status: flow.mac) { Task { await flow.refresh() } }
                    Divider()
                    SetupRow(title: "Container runtime", status: flow.runtime) { flow.start() }
                    Divider()
                    SetupRow(title: "Browser VM", status: flow.vm) { flow.start() }
                    if let browser {
                        Divider()
                        BrowserRow(browser: browser, added: $addedToBrowser)
                    }
                }
                .padding(.horizontal, 6)
            }
            HStack {
                Spacer()
                if flow.allRequiredDone {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: close)
                    Button("Set Up") { flow.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!flow.canSetUp)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct SetupRow: View {
    let title: String
    let status: SetupFlow.Status
    let tryAgain: () -> Void
    @State private var showsDetails = false

    // Buttons sit on the title line and the detail reserves two lines, so no state changes the height.
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            symbol.frame(width: 20, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                    Spacer(minLength: 8)
                    if case .failed(_, let details) = status {
                        if !details.isEmpty {
                            Button("Show Details") { showsDetails = true }
                                .popover(isPresented: $showsDetails, arrowEdge: .bottom) { DetailsView(lines: details) }
                        }
                        Button("Try Again", action: tryAgain)
                    }
                }
                .controlSize(.small)
                .frame(minHeight: 22)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(.vertical, 10)
    }

    private var detail: String {
        switch status {
        case .pending(let text), .running(let text, _), .done(let text), .failed(let text, _): text
        }
    }

    private var isFailed: Bool {
        if case .failed = status { true } else { false }
    }

    @ViewBuilder private var symbol: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").imageScale(.large).foregroundStyle(.tertiary)
        case .running(_, let fraction?):
            ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").imageScale(.large).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").imageScale(.large).foregroundStyle(.red)
        }
    }
}

private struct BrowserRow: View {
    let browser: ChromeExtension.Browser
    @Binding var added: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Open links from \(browser.name)")
                    Text("Optional").font(.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Button("Add to \(browser.name)") {
                        ChromeExtension.open(in: browser)
                        added = true
                    }
                    .controlSize(.small)
                }
                .frame(minHeight: 22)
                Text(added ? "In \(browser.name), right-click a link and choose Open in Knotchy."
                           : "Safari and Mail already work from the right-click menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct DetailsView: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 440, height: 220)
    }
}

private struct UnsupportedView: View {
    let reason: Unsupported

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(width: 440)
    }

    private var title: String {
        switch reason {
        case .noVirtualization: "This Mac can't run virtual machines right now"
        }
    }

    private var message: String {
        switch reason {
        case .noVirtualization:
            "Knotchy opens every link in its own virtual machine. If macOS is itself running in a virtual machine, run Knotchy on the host Mac instead."
        }
    }
}
