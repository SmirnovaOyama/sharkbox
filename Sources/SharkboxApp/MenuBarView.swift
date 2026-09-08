import SwiftUI
import AppKit

final class MenuUIState: ObservableObject {
    @Published var loginItem = LoginItem.enabled
    @Published var expanded: String?
}

/// The menu bar popover: every machine with its state, an inline primary action, and a submenu
/// carrying the full action list.
struct MenuBarView: View {
    @EnvironmentObject var store: MachineStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = MenuUIState()

    private var listed: [MachineInfo] {
        store.settings.menuBarShowsStopped ? store.machines : store.running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            Divider()

            if listed.isEmpty {
                Text(store.machines.isEmpty ? "No machines yet" : "No machines running")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(listed) { MenuMachineRow(machine: $0) }

            Divider()
            Button {
                open("new-machine")
            } label: {
                Label { Text("New Machine…") } icon: { Glyph(kind: .plus, size: 13) }
            }
            .buttonStyle(.borderless)

            Menu {
                Button("Sharkbox Window") { open("main") }
                Button("Settings…") { openSettings() }
                Divider()
                Button("Show State Folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }
                Button("Copy CLI Path") { store.copyToPasteboard(store.cliPath) }
                Divider()
                Menu("Images") {
                    ForEach(store.images) { img in
                        Menu(img.title) {
                            if img.downloaded {
                                Text("\(Fmt.bytes(img.bytes)) on disk")
                                Button("Delete Cached Image", role: .destructive) { store.removeImage(img.id) }
                            } else {
                                Button("Download Now") { store.pullImage(img.id) }
                            }
                        }
                    }
                }
                Toggle("Start Sharkbox at login", isOn: $ui.loginItem)
                    .onChange(of: ui.loginItem) { _, on in
                        if on != LoginItem.enabled { LoginItem.set(on); ui.loginItem = LoginItem.enabled }
                    }
                Divider()
                Button("About Sharkbox") { open("about") }
            } label: {
                Label { Text("Sharkbox") } icon: { Glyph(kind: .gear, size: 13) }
            }
            .menuStyle(.borderlessButton)

            Divider()
            HStack {
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
                Spacer()
                Text("\(Fmt.bytes(store.freeSpace)) free")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppMark(size: 20)
            Text("Sharkbox").font(.headline)
            Spacer()
            if !store.running.isEmpty {
                Text("\(store.running.count) running")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button { open("main") } label: { Glyph(kind: .window, size: 14) }
                .buttonStyle(.borderless)
                .help("Open the Sharkbox window")
        }
        .padding(.bottom, 2)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

struct MenuMachineRow: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo

    var body: some View {
        HStack(spacing: 8) {
            DistroMark(distro: machine.distro, size: 15, color: machine.isRunning ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(machine.name).fontWeight(.medium)
                    if machine.isDefault { Glyph(kind: .star, size: 9, color: .yellow) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if machine.isRunning {
                Button { store.openTerminal(machine.name) } label: { Glyph(kind: .terminal, size: 14) }
                    .buttonStyle(.borderless).help("Open Terminal")
                    .disabled(machine.state != "running")
                Button { store.stop(machine.name) } label: { Glyph(kind: .stop, size: 12) }
                    .buttonStyle(.borderless).help("Stop")
            } else {
                Button { store.start(machine.name) } label: { Glyph(kind: .play, size: 12) }
                    .buttonStyle(.borderless).help("Start")
            }
            Menu {
                MachineMenuItems(machine: machine, requestDelete: {
                    NotificationCenter.default.post(name: .requestDeleteMachine, object: machine.name)
                    NSApp.activate(ignoringOtherApps: true)
                })
            } label: {
                Glyph(kind: .chevronRight, size: 11, color: .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
        }
        .disabled(store.busy.contains(machine.name))
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if store.busy.contains(machine.name) { return "working…" }
        if machine.state == "booting" { return "booting…" }
        if machine.isRunning { return machine.ip ?? "running" }
        return machine.cleanShutdown ? machine.state : "\(machine.state) · needs a check"
    }
}
