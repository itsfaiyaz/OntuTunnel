import AppKit
import SwiftUI

@main
struct OntuTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() { SelfTest.runIfRequested() }


    var body: some Scene {
        Window("OntuTunnel", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1040, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .onAppear { model.startIfNeeded() }
        } label: {
            Image(systemName: menuIcon)
        }
    }

    private var menuIcon: String {
        switch model.health {
        case .good: return "point.3.filled.connected.trianglepath.dotted"
        case .warning: return "exclamationmark.triangle"
        case .bad: return "xmark.circle"
        case .idle: return "point.3.connected.trianglepath.dotted"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    /// Closing the window keeps OntuTunnel running in the menu bar, so
    /// the proxy and services stay up.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}
