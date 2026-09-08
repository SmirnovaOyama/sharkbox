import SwiftUI
import AppKit
import ServiceManagement

@main
struct SharkboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = MachineStore.shared

    var body: some Scene {
        Window("Sharkbox", id: "main") {
            MainView().environmentObject(store)
        }
        .defaultSize(width: 980, height: 660)
        .commands { SharkboxCommands(store: store) }

        Window("New Machine", id: "new-machine") {
            NewMachineView().environmentObject(store)
        }
        .windowResizability(.contentSize)

        Window("About Sharkbox", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView().environmentObject(store)
        }

        MenuBarExtra {
            MenuBarView().environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["SHARKBOX_DEBUG_WINDOWS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for w in NSApp.windows {
                    NSLog("window: %@ frame=%@ visible=%d title=%@", String(describing: type(of: w)),
                          NSStringFromRect(w.frame), w.isVisible ? 1 : 0, w.title)
                }
            }
        }
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login item: \(error)")
        }
    }
}

// MARK: - Shared formatting helpers

enum Fmt {
    static func bytes(_ b: UInt64) -> String { formatBytes(b) }
    static let date: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}
