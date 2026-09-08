import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: MachineStore

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label { Text("General") } icon: { Glyph(kind: .sliders) } }
            DefaultsSettings().tabItem { Label { Text("New Machines") } icon: { Glyph(kind: .plus) } }
            ImagesView().tabItem { Label { Text("Images") } icon: { Glyph(kind: .image) } }
            StorageSettings().tabItem { Label { Text("Storage") } icon: { Glyph(kind: .disk) } }
        }
        .frame(width: 560, height: 400)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: MachineStore
    @StateObject private var ui = GeneralSettingsState()

    var body: some View {
        Form {
            Section {
                Picker("Open terminals with", selection: Binding(
                    get: { store.settings.terminalApp },
                    set: { store.settings.terminalApp = $0 })) {
                    ForEach(store.settings.availableTerminals, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Ask before deleting a machine", isOn: Binding(
                    get: { store.settings.confirmDestructive },
                    set: { store.settings.confirmDestructive = $0 }))
                Toggle("Show stopped machines in the menu bar", isOn: Binding(
                    get: { store.settings.menuBarShowsStopped },
                    set: { store.settings.menuBarShowsStopped = $0 }))
                Toggle("Start Sharkbox at login", isOn: $ui.loginItem)
                    .onChange(of: ui.loginItem) { _, on in
                        if on != LoginItem.enabled { LoginItem.set(on); ui.loginItem = LoginItem.enabled }
                    }
            }
            Section("Refresh") {
                let binding = Binding(get: { store.settings.refreshSeconds },
                                      set: { store.settings.refreshSeconds = $0; store.restartTimer() })
                Slider(value: binding, in: 1...10, step: 1) {
                    Text("Poll machines every \(Int(store.settings.refreshSeconds))s")
                }
                Slider(value: Binding(get: { store.settings.consoleLines },
                                      set: { store.settings.consoleLines = $0 }), in: 100...2000, step: 100) {
                    Text("Console buffer: \(Int(store.settings.consoleLines)) lines")
                }
            }
            Section("Command line") {
                LabeledContent("shark") {
                    HStack(spacing: 6) {
                        Text(store.cliPath).font(.system(size: 11, design: .monospaced))
                        if store.cliInstalled {
                            Glyph(kind: .check, size: 12, color: .green)
                        } else {
                            Glyph(kind: .warning, size: 12, color: .orange)
                        }
                    }
                }
                HStack {
                    Button("Install ~/.ssh/config entry") { store.installSSHConfig() }
                    Text("lets you run `ssh <machine>.shark` from anywhere")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

final class GeneralSettingsState: ObservableObject {
    @Published var loginItem = LoginItem.enabled
}

struct DefaultsSettings: View {
    @EnvironmentObject var store: MachineStore
    private var hostCPUs: Int { ProcessInfo.processInfo.activeProcessorCount }
    private var hostMemGB: Int { max(2, Int(ProcessInfo.processInfo.physicalMemory >> 30)) }

    var body: some View {
        Form {
            Section {
                Text("Values pre-filled in the New Machine window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Stepper("CPUs: \(store.settings.defaultCPUs)", value: Binding(
                    get: { store.settings.defaultCPUs }, set: { store.settings.defaultCPUs = $0 }), in: 1...hostCPUs)
                Stepper("Memory: \(store.settings.defaultMemoryGB) GB", value: Binding(
                    get: { store.settings.defaultMemoryGB }, set: { store.settings.defaultMemoryGB = $0 }), in: 1...hostMemGB)
                Stepper("Disk: \(store.settings.defaultDiskGB) GB", value: Binding(
                    get: { store.settings.defaultDiskGB }, set: { store.settings.defaultDiskGB = $0 }), in: 8...2048, step: 8)
                Toggle("Enable Rosetta (run x86_64 Linux binaries)", isOn: Binding(
                    get: { store.settings.defaultRosetta }, set: { store.settings.defaultRosetta = $0 }))
            }
            Section {
                LabeledContent("This Mac") {
                    Text("\(hostCPUs) CPUs · \(hostMemGB) GB RAM · \(Fmt.bytes(store.freeSpace)) free")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct StorageSettings: View {
    @EnvironmentObject var store: MachineStore

    var body: some View {
        Form {
            Section("Disk usage") {
                LabeledContent("Machines") { Text(Fmt.bytes(Images.directorySize(Paths.machines))) }
                LabeledContent("Images") { Text(Fmt.bytes(Images.directorySize(Paths.images))) }
                LabeledContent("Free on this Mac") { Text(Fmt.bytes(store.freeSpace)) }
            }
            Section("Machines") {
                ForEach(store.machines) { m in
                    LabeledContent {
                        Text("\(Fmt.bytes(m.diskUsed)) of \(Fmt.bytes(m.diskBytes))")
                            .foregroundStyle(.secondary)
                    } label: {
                        HStack(spacing: 6) {
                            DistroMark(distro: m.distro, size: 14, color: .secondary)
                            Text(m.name)
                        }
                    }
                }
                if store.machines.isEmpty {
                    Text("No machines").foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Location") {
                    HStack(spacing: 6) {
                        Text(Paths.root.path).font(.system(size: 11, design: .monospaced))
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([Paths.root])
                        } label: { Glyph(kind: .folder, size: 13) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
