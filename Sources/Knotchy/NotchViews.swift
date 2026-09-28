import KnotchyCore
import SwiftUI

struct NotchRootView: View {
    let controller: SessionController
    let chrome: NotchChrome

    var body: some View {
        let size = chrome.bodySize
        ZStack(alignment: .top) {
            switch chrome.content {
            case .hidden:
                Color.clear.frame(width: 0, height: 0)
            case .compact:
                CompactView(controller: controller, state: chrome.state, notchWidth: chrome.notchSize.width)
                    .frame(width: NotchChrome.bodySize(.compact, notch: chrome.notchSize, panel: chrome.panelSize,
                                                       hasNotch: chrome.hasNotch).width,
                           height: chrome.notchSize.height)
                    .transition(.island)
            case .banner:
                BannerView(controller: controller, state: chrome.state, notice: chrome.notice,
                           notchHeight: chrome.notchSize.height)
                    .frame(width: NotchChrome.bodySize(.banner, notch: chrome.notchSize, panel: chrome.panelSize,
                                                       hasNotch: chrome.hasNotch).width)
                    .transition(.island)
            case .panel:
                PanelView(controller: controller, chrome: chrome)
                    .frame(width: chrome.panelSize.width, height: chrome.panelSize.height)
                    .transition(.island)
            }
        }
        .modifier(Morph(progress: chrome.reveal))
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.horizontal, chrome.topRadius)
        .clipShape(NotchShape(topRadius: chrome.topRadius, bottomRadius: chrome.bottomRadius))
        .background {
            // Shadow from the outline alone, not from everything inside it.
            NotchShape(topRadius: chrome.topRadius, bottomRadius: chrome.bottomRadius)
                .fill(.black)
                .shadow(color: .black.opacity(chrome.presentation == .panel ? 0.5 : 0), radius: 14, y: 6)
        }
        .offset(x: chrome.offsetX)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Compact

private struct CompactView: View {
    let controller: SessionController
    let state: SessionState
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            trailing.frame(maxWidth: .infinity)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .contextMenu { PillMenu(controller: controller, state: state) }
    }

    @ViewBuilder private var leading: some View {
        switch state {
        case .starting, .settingUp:
            ProgressView().controlSize(.small).scaleEffect(0.75)
        default:
            KnotMark(size: 15)
                .modifier(Breathing())
                .help("A page is open in a disposable VM")
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .starting:
            Text("Opening").foregroundStyle(.white.opacity(0.7))
        case .settingUp(let issue):
            Text(Self.setupWord(issue)).foregroundStyle(.white.opacity(0.7))
                .help("Setting up the browser VM. Hover to see progress.")
        default:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let text = Self.format(controller.countdown)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: text)
                    .help("Destroyed automatically when this reaches 0:00")
            }
        }
    }

    private static func setupWord(_ issue: SetupIssue) -> String {
        switch issue {
        case .imageMissing, .imageOutdated: "Building"
        case .imageStale, .cliOutdated: "Updating"
        case .cliMissing: "Installing"
        default: "Starting"
        }
    }

    private static func format(_ remaining: Duration?) -> String {
        guard let remaining else { return "" }
        let seconds = Int(remaining.components.seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Banner

private struct BannerView: View {
    let controller: SessionController
    let state: SessionState
    let notice: Notice?
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            ZStack {
                row.id(kind).transition(.swap)
            }
            .frame(maxWidth: .infinity)
            .frame(height: NotchChrome.bannerRowHeight - 4)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .contextMenu { PillMenu(controller: controller, state: state) }
    }

    private enum Kind: Hashable { case noWebLink, destroying, destroyed, ended, stuck, other }

    private var kind: Kind {
        if notice == .noWebLink, state == .idle { return .noWebLink }
        switch state {
        case .destroying: return .destroying
        case .destroyed: return .destroyed
        case .failed(.ended): return .ended
        case .failed(.destroyStuck): return .stuck
        default: return .other
        }
    }

    @ViewBuilder private var row: some View {
        HStack(spacing: 7) {
            switch kind {
            case .noWebLink:
                Image(systemName: "link").foregroundStyle(Palette.amber)
                Text("No web link found")
            case .destroying:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                Text("Destroying the VM…").foregroundStyle(.white.opacity(0.8))
            case .destroyed:
                BouncingSymbol(name: "checkmark.circle.fill", color: Palette.green)
                Text("VM destroyed")
            case .ended:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.red)
                Text("Session ended")
            case .stuck:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
                Text("VM may still be running")
                Button("Retry") { controller.retry() }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary, small: true))
                    .padding(.leading, 4)
            case .other:
                EmptyView()
            }
        }
    }
}

private struct PillMenu: View {
    let controller: SessionController
    let state: SessionState

    var body: some View {
        if case .live = state { Button("Destroy Now") { controller.destroy() } }
        Button("Quit Knotchy") { NSApp.terminate(nil) }
    }
}

private struct BouncingSymbol: View {
    let name: String
    let color: Color
    @State private var appeared = false

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(color)
            .symbolEffect(.bounce, value: appeared)
            .onAppear { appeared = true }
    }
}

// MARK: - Panel

private struct PanelView: View {
    let controller: SessionController
    let chrome: NotchChrome

    private var innerRadius: CGFloat { NotchChrome.bottomRadius(.panel) - NotchGeometry.margin }

    var body: some View {
        VStack(spacing: 0) {
            TopStrip(controller: controller, state: chrome.state, notchWidth: chrome.notchSize.width,
                     routeLabel: chrome.routeLabel)
                .frame(height: chrome.notchSize.height)
            Toolbar(controller: controller, state: chrome.state)
                .frame(height: NotchGeometry.toolbarHeight)
            ZStack(alignment: .bottom) {
                content
                    .id(ContentKind(chrome.state))
                    .transition(.swap)
                if let stale = controller.staleImage, case .live = chrome.state {
                    StaleBanner(controller: controller, stale: stale)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if case .live = chrome.state { ProgressLine(progress: controller.progress) }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: innerRadius,
                                              bottomTrailingRadius: innerRadius, topTrailingRadius: 8,
                                              style: .continuous))
            .padding([.horizontal, .bottom], NotchGeometry.margin)
        }
        .foregroundStyle(.white)
    }

    private enum ContentKind: Hashable {
        case starting, live, failed, setup, settingUp, other

        init(_ state: SessionState) {
            switch state {
            case .starting: self = .starting
            case .live: self = .live
            case .failed(.start): self = .failed
            case .setupRequired: self = .setup
            case .settingUp: self = .settingUp
            default: self = .other
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch chrome.state {
        case .live:
            VideoSurface(controller: controller)
        case .starting(let step, _):
            StartingView(step: step, host: controller.openedURL?.host())
        case .failed(.start(let message)):
            MessageCard(symbol: "exclamationmark.triangle.fill", tint: Palette.amber,
                        title: "Couldn't open the link", message: message) {
                Button("Dismiss") { controller.dismiss() }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary))
                Button("Try Again") { controller.retry() }
                    .buttonStyle(CapsuleButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        case .setupRequired(let issue, let error):
            MessageCard(symbol: Setup.symbol(issue), tint: error == nil ? .white : Palette.amber,
                        title: Setup.title(issue), message: error ?? Setup.text(issue)) {
                Button("Not Now") { controller.dismiss() }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary))
                if let action = Setup.action(issue) {
                    Button(action) { controller.performSetupAction() }
                        .buttonStyle(CapsuleButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .settingUp(let issue):
            MessageCard(symbol: Setup.symbol(issue), tint: .white, title: Setup.progressTitle(issue),
                        message: Self.lastLine(controller.setupLog) ?? "Working…", monospaced: true) {
                ProgressView().controlSize(.small)
                Button("Hide") { controller.foldSetup() }
                    .buttonStyle(CapsuleButtonStyle(kind: .secondary))
                    .help("Keep going in the background; hover over the notch to check on it")
            }
        default:
            Color.black
        }
    }

    private static func lastLine(_ log: String?) -> String? {
        log?.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}

private struct TopStrip: View {
    let controller: SessionController
    let state: SessionState
    let notchWidth: CGFloat
    let routeLabel: String?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                KnotMark(size: 13)
                Text("Isolated").foregroundStyle(.white.opacity(0.75))
                if let routeLabel {
                    Text("· via \(routeLabel)").foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .help("This page runs in a disposable Linux VM, cut off from your Mac and your network")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)

            Color.clear.frame(width: notchWidth)

            Group {
                if Self.canDestroy(state) {
                    Button { controller.destroy() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "power").font(.system(size: 9, weight: .bold))
                            Text("Destroy")
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .destructive, small: true))
                    .help("Destroy the VM and everything in it (⌘W)")
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
        }
    }

    static func canDestroy(_ state: SessionState) -> Bool {
        switch state {
        case .starting, .live: true
        default: false
        }
    }
}

private struct Toolbar: View {
    let controller: SessionController
    let state: SessionState

    private var isLive: Bool {
        if case .live = state { true } else { false }
    }

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", help: "Back (⌘[)") { controller.goBack() }
            IconButton(symbol: "chevron.right", help: "Forward (⌘])") { controller.goForward() }
            IconButton(symbol: "arrow.clockwise", help: "Reload (⌘R)") { controller.reload() }
            AddressField(url: controller.pageURL ?? controller.openedURL)
                .padding(.horizontal, 6)
            if state == .live(.expanded) {
                IconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Make smaller (⇧⌘E)") { controller.shrink() }
            } else {
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Make larger (⇧⌘E)") { controller.expand() }
            }
        }
        .disabled(!isLive)
        .padding(.horizontal, NotchGeometry.margin)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}

private struct AddressField: View {
    let url: URL?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text(Self.display(url))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
        .help(url?.absoluteString ?? "")
    }

    static func display(_ url: URL?) -> AttributedString {
        guard let url else { return AttributedString("") }
        var host = AttributedString(url.host() ?? url.absoluteString)
        host.foregroundColor = .white
        var rest = url.path()
        if let query = url.query() { rest += "?" + query }
        if rest == "/" { rest = "" }
        var tail = AttributedString(rest)
        tail.foregroundColor = .white.opacity(0.4)
        return host + tail
    }
}

private struct ProgressLine: View {
    let progress: Int?
    @State private var shown: Int = 0

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.7, blue: 1), Color(red: 0.2, green: 0.5, blue: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: max(4, proxy.size.width * CGFloat(shown) / 100), height: 3)
        }
        .frame(height: 3)
        .opacity(progress == nil || progress == 100 ? 0 : 1)
        .animation(.easeOut(duration: 0.35), value: progress == nil || progress == 100)
        .onChange(of: progress, initial: true) { _, value in
            guard let value else { return }
            withAnimation(value < shown ? nil : .easeOut(duration: 0.25)) { shown = value }
        }
    }
}

private struct StartingView: View {
    let step: StartStep
    let host: String?

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Palette.coral.opacity(0.14)).frame(width: 64, height: 64)
                KnotMark(size: 32)
                    .modifier(Breathing())
            }
            VStack(spacing: 4) {
                Text("Opening in a disposable VM").font(.system(size: 15, weight: .semibold))
                if let host {
                    Text(host).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                StepRow(title: "Starting the VM", done: step != .booting, active: step == .booting)
                StepRow(title: "Connecting to its browser", done: step == .loading, active: step == .connecting)
                StepRow(title: "Loading the page", done: false, active: step == .loading)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }
}

private struct StepRow: View {
    let title: String
    let done: Bool
    let active: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.green)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if active {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                        .transition(.opacity)
                } else {
                    Image(systemName: "circle").foregroundStyle(.white.opacity(0.22))
                }
            }
            .frame(width: 16, height: 16)
            Text(title)
                .foregroundStyle(.white.opacity(done || active ? 0.9 : 0.4))
        }
        .font(.system(size: 13))
        .animation(.spring(duration: 0.35, bounce: 0.4), value: done)
        .animation(.easeOut(duration: 0.2), value: active)
    }
}

private struct MessageCard<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var monospaced = false
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.14)).frame(width: 52, height: 52)
                Image(systemName: symbol).font(.system(size: 21, weight: .semibold)).foregroundStyle(tint)
            }
            VStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(maxWidth: 400)
            }
            HStack(spacing: 8) { actions }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }
}

private struct StaleBanner: View {
    let controller: SessionController
    let stale: StaleImage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
            Text(stale.builtDaysAgo.map { "The browser VM is \($0) days old." } ?? "The browser VM's age is unknown.")
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 8)
            Button("Later") { controller.dismissStaleImageWarning() }
                .buttonStyle(CapsuleButtonStyle(kind: .secondary, small: true))
            Button("Update Now") { controller.requestImageUpdate() }
                .buttonStyle(CapsuleButtonStyle(kind: .primary, small: true))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.1).opacity(0.94)))
        .padding(8)
    }
}

private enum Setup {
    static func symbol(_ issue: SetupIssue) -> String {
        switch issue {
        case .cliMissing, .cliOutdated: "shippingbox"
        case .serviceStopped, .kernelMissing: "power"
        case .imageMissing, .imageOutdated: "square.and.arrow.down"
        case .imageStale: "arrow.triangle.2.circlepath"
        case .lowDisk: "internaldrive"
        }
    }

    static func title(_ issue: SetupIssue) -> String {
        switch issue {
        case .cliMissing: "Knotchy needs Apple's container runtime"
        case .cliOutdated: "Knotchy needs a newer container runtime"
        case .serviceStopped, .kernelMissing: "The container service isn't running"
        case .imageMissing, .imageOutdated: "The browser VM image needs to be built"
        case .imageStale: "Updating the browser VM"
        case .lowDisk: "Not enough disk space"
        }
    }

    static func progressTitle(_ issue: SetupIssue) -> String {
        switch issue {
        case .cliMissing: "Installing the container runtime…"
        case .cliOutdated: "Updating the container runtime…"
        case .serviceStopped, .kernelMissing: "Starting the container runtime…"
        default: title(issue)
        }
    }

    static func text(_ issue: SetupIssue) -> String {
        switch issue {
        case .cliMissing: "Set it up in one step; the link opens when it's done."
        case .cliOutdated: "Update it in one step; the link opens when it's done."
        case .serviceStopped, .kernelMissing: "Start it to run the isolated browser."
        case .imageMissing, .imageOutdated: "This takes about 3 minutes and downloads about 225 MB."
        case .imageStale: "Rebuilding gets the latest WebKit security fixes."
        case .lowDisk(let free): "Only \(free / 1_000_000_000) GB free; a session needs about 2 GB."
        }
    }

    static func action(_ issue: SetupIssue) -> String? {
        switch issue {
        case .cliMissing, .cliOutdated: "Set Up…"
        case .serviceStopped, .kernelMissing: "Start Service"
        case .imageMissing, .imageOutdated: "Build Image"
        case .imageStale: "Update Now"
        case .lowDisk: nil
        }
    }
}
