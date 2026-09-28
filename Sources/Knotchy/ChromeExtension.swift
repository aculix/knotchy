import AppKit

enum ChromeExtension {
    /// Set once the Chrome Web Store assigns the item ID; until then the setup window hides the row.
    static let storeURL: URL? = nil

    struct Browser: Equatable {
        let name: String
        let app: URL
    }

    // Chromium browsers all install from the Chrome Web Store.
    private static let candidates = [("Chrome", "com.google.Chrome"), ("Edge", "com.microsoft.edgemac"),
                                     ("Brave", "com.brave.Browser"), ("Arc", "company.thebrowser.Browser")]

    static func installedBrowser() -> Browser? {
        guard storeURL != nil else { return nil }
        for (name, id) in candidates {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return Browser(name: name, app: app) }
        }
        return nil
    }

    static func open(in browser: Browser) {
        guard let storeURL else { return }
        NSWorkspace.shared.open([storeURL], withApplicationAt: browser.app, configuration: NSWorkspace.OpenConfiguration())
    }
}
