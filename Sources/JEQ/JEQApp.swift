import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.bootstrap()
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.engine.stop()
    }
}

struct JEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    private var menuBarIcon: Image {
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return Image(nsImage: img)
        }
        return Image(systemName: state.engine.isRunning ? "waveform.path" : "waveform.path.ecg")
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(state: state)
        } label: {
            menuBarIcon
        }
        .menuBarExtraStyle(.window)
    }
}
