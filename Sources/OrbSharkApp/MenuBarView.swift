import SwiftUI
import AppKit

final class MenuUIState: ObservableObject {
    @Published var loginItem = LoginItem.enabled
}

struct MenuBarView: View {
    @EnvironmentObject var store: MachineStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = MenuUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(nsImage: MenuBarIcon.image)
                Text("OrbShark").font(.headline)
                Spacer()
                Button { openMain() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).help("Open the OrbShark window")
            }
            .padding(.bottom, 4)
            Divider()

            if store.machines.isEmpty {
                Text("No machines yet").foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(store.machines) { m in
                MenuMachineRow(machine: m)
            }

            Divider()
            Button {
                openWindow(id: "new-machine")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("New Machine…", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Toggle("Start OrbShark at login", isOn: $ui.loginItem)
                .toggleStyle(.checkbox)
                .onChange(of: ui.loginItem) { _, on in
                    if on != LoginItem.enabled { LoginItem.set(on); ui.loginItem = LoginItem.enabled }
                }
                .padding(.top, 2)

            Divider()
            Button("Quit OrbShark") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 320)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuMachineRow: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(machine: machine)
            VStack(alignment: .leading, spacing: 0) {
                Text(machine.name).fontWeight(.medium)
                Text(machine.ip ?? (machine.isRunning ? "booting…" : machine.state))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if machine.isRunning {
                Button { store.openTerminal(machine.name) } label: { Image(systemName: "terminal") }
                    .buttonStyle(.borderless).help("Open Terminal")
                    .disabled(machine.state == "booting")
                Button { store.stop(machine.name) } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).help("Stop")
            } else {
                Button { store.start(machine.name) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).help("Start")
            }
        }
        .disabled(store.busy.contains(machine.name))
        .padding(.vertical, 3)
    }
}
