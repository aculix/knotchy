import KnotchyCore
import SwiftUI

@main
struct KnotchyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(app.isSupportedMac)) {
            KnotchyMenu(app: app, settings: app.settings)
        } label: {
            Image(nsImage: KnotGlyph.menuBarImage)
        }
    }
}
