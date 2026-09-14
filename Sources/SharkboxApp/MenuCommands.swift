import SwiftUI
import AppKit

/// The application menu bar. Machine actions are organised as submenus so every machine is reachable
/// from the keyboard without selecting it first: Machine ▸ Start ▸ ubuntu, Machine ▸ Maintenance ▸ Repair ▸ ubuntu.
struct SharkboxCommands: Commands {
    @ObservedObject var store: MachineStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Sharkbox") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Machine…") { open("new-machine") }
                .keyboardShortcut("n")
            Button("Sharkbox Window") { open("main") }
                .keyboardShortcut("0", modifiers: [.command])
        }

        CommandMenu("Machine") {
            machineSubmenu("Start", glyphless: store.stopped) { store.start($0.name) }
            machineSubmenu("Stop", glyphless: store.running) { store.stop($0.name) }
            machineSubmenu("Restart", glyphless: store.running) { store.restart($0.name) }

            Divider()

            machineSubmenu("Open Terminal", glyphless: store.running.filter { $0.state == "running" }) {
                store.openTerminal($0.name)
            }
            machineSubmenu("Copy SSH Command", glyphless: store.machines) {
                store.copyToPasteboard("ssh \($0.name).shark")
            }
            machineSubmenu("Set Up Docker", glyphless: store.running) { store.installDocker($0.name) }

            Divider()

            Menu("Maintenance") {
                machineSubmenu("Check Filesystem", glyphless: store.stopped) { store.fsck($0.name, repair: false) }
                machineSubmenu("Repair Filesystem", glyphless: store.stopped) { store.fsck($0.name, repair: true) }
                Divider()
                machineSubmenu("Force Stop", glyphless: store.running) { store.stop($0.name, force: true) }
                machineSubmenu("Reveal in Finder", glyphless: store.machines) { store.revealInFinder($0) }
                Divider()
                Button("Install ~/.ssh/config Entry") { store.installSSHConfig() }
            }

            Menu("Default Machine") {
                if store.machines.isEmpty {
                    Text("No machines")
                } else {
                    ForEach(store.machines) { m in
                        Button {
                            store.setDefault(m.name)
                        } label: {
                            Text(m.isDefault ? "\(m.name)  ✓" : m.name)
                        }
                        .disabled(m.isDefault)
                    }
                }
            }

            Divider()

            Menu("Delete") {
                if store.machines.isEmpty {
                    Text("No machines")
                } else {
                    ForEach(store.machines) { m in
                        Button("\(m.name)…", role: .destructive) {
                            store.requestDelete(m.name)
                            open("main")
                        }
                    }
                }
            }
        }

        CommandMenu("Images") {
            ForEach(store.images) { img in
                Menu(img.title) {
                    if img.downloaded {
                        Text("\(Fmt.bytes(img.bytes)) on disk")
                        Divider()
                        Button("Create a Machine…") {
                            // Set this *before* opening: the window may not exist yet, so a
                            // notification posted here would land with nobody listening.
                            store.pendingNewMachineDistro = img.id
                            open("new-machine")
                        }
                        Button("Delete Cached Image", role: .destructive) { store.removeImage(img.id) }
                    } else {
                        Text("Not downloaded")
                        Divider()
                        Button("Download Now") { store.pullImage(img.id) }
                    }
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Sharkbox Help") {
                store.copyToPasteboard("shark help")
                NSWorkspace.shared.open(Paths.root)
            }
            Divider()
            Button("Open State Folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }
        }
    }

    /// A submenu listing machines; disabled with an explanatory item when there is nothing to act on.
    @ViewBuilder
    private func machineSubmenu(_ title: String, glyphless machines: [MachineInfo],
                                action: @escaping (MachineInfo) -> Void) -> some View {
        Menu(title) {
            if machines.isEmpty {
                Text("Nothing to \(title.lowercased())")
            } else {
                ForEach(machines) { m in
                    Button(m.name) { action(m) }
                        .disabled(store.busy.contains(m.name))
                }
            }
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let selectMachine = Notification.Name("sharkbox.selectMachine")
}
