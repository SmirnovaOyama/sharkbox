import SwiftUI
import AppKit
import ServiceManagement

@main
struct OrbSharkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = MachineStore.shared

    var body: some Scene {
        Window("OrbShark", id: "main") {
            MainView().environmentObject(store)
        }
        .defaultSize(width: 900, height: 600)

        Window("New Machine", id: "new-machine") {
            NewMachineView().environmentObject(store)
        }
        .windowResizability(.contentSize)

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
        if ProcessInfo.processInfo.environment["ORBSHARK_DEBUG_WINDOWS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for w in NSApp.windows {
                    NSLog("window: %@ frame=%@ visible=%d title=%@", String(describing: type(of: w)),
                          NSStringFromRect(w.frame), w.isVisible ? 1 : 0, w.title)
                }
            }
        }
    }
}

enum MenuBarIcon {
    /// A small shark fin, drawn as a template image so it follows the menu bar appearance.
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let fin = NSBezierPath()
            fin.move(to: NSPoint(x: 2.5, y: 4))
            fin.curve(to: NSPoint(x: 11.5, y: 15), controlPoint1: NSPoint(x: 6, y: 6), controlPoint2: NSPoint(x: 9.5, y: 10.5))
            fin.curve(to: NSPoint(x: 15.5, y: 4), controlPoint1: NSPoint(x: 12.5, y: 9.5), controlPoint2: NSPoint(x: 14, y: 6))
            fin.close()
            NSColor.black.setFill()
            fin.fill()
            let water = NSBezierPath()
            water.move(to: NSPoint(x: 1, y: 2))
            water.curve(to: NSPoint(x: 9, y: 2), controlPoint1: NSPoint(x: 3, y: 3.5), controlPoint2: NSPoint(x: 7, y: 0.5))
            water.curve(to: NSPoint(x: 17, y: 2), controlPoint1: NSPoint(x: 11, y: 3.5), controlPoint2: NSPoint(x: 15, y: 0.5))
            water.lineWidth = 1.4
            NSColor.black.setStroke()
            water.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }()
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
