import SwiftUI

/// View-local state lives in small ObservableObjects: the macOS 26+ SDK implements `@State` as a
/// compiler macro whose plugin only ships with Xcode, and OrbShark builds with the Command Line Tools.
final class MainUIState: ObservableObject {
    @Published var selection: String?
}

struct MainView: View {
    @EnvironmentObject var store: MachineStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = MainUIState()
    private var selection: String? { ui.selection }

    var body: some View {
        NavigationSplitView {
            List(store.machines, selection: $ui.selection) { m in
                MachineRow(machine: m).tag(m.name)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            .overlay {
                if store.machines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "shippingbox").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("No machines yet").foregroundStyle(.secondary)
                        Button("New Machine…") { openWindow(id: "new-machine") }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { openWindow(id: "new-machine") } label: { Label("New Machine", systemImage: "plus") }
                        .help("Create a new Linux machine")
                }
            }
        } detail: {
            if let name = selection, let m = store.machines.first(where: { $0.name == name }) {
                MachineDetailView(machine: m)
            } else {
                VStack(spacing: 10) {
                    Image(nsImage: MenuBarIcon.image).resizable().frame(width: 54, height: 48).foregroundStyle(.secondary)
                    Text("Select a machine").foregroundStyle(.secondary)
                    if !store.cliInstalled {
                        Text("The `shark` CLI was not found at \(store.cliPath). Run `make install` in the OrbShark folder.")
                            .font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 40)
                    }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 480)
        .onAppear { pickDefault() }
        .onChange(of: store.machines) { _, new in
            if let s = ui.selection, !new.contains(where: { $0.name == s }) { ui.selection = nil }
            if ui.selection == nil { pickDefault() }
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private func pickDefault() {
        if ui.selection == nil {
            ui.selection = store.machines.first(where: { $0.isDefault })?.name ?? store.machines.first?.name
        }
    }
}

struct MachineRow: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(machine: machine)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name).fontWeight(.medium)
                Text(machine.distro).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if machine.isDefault {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).help("Default machine")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if machine.isRunning {
                Button("Open Terminal") { store.openTerminal(machine.name) }
                Button("Stop") { store.stop(machine.name) }
            } else {
                Button("Start") { store.start(machine.name) }
            }
            Divider()
            Button("Set as Default") { store.setDefault(machine.name) }.disabled(machine.isDefault)
            Button("Show in Finder") { store.revealInFinder(machine) }
        }
    }
}

struct StatusDot: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo
    var body: some View {
        if machine.isTransitioning || store.busy.contains(machine.name) {
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        } else {
            Circle().fill(machine.stateColor).frame(width: 9, height: 9)
        }
    }
}

final class DetailUIState: ObservableObject {
    @Published var confirmDelete = false
    @Published var consoleText = ""
}

struct MachineDetailView: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo
    @StateObject private var ui = DetailUIState()
    private var consoleText: String { ui.consoleText }
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var busy: Bool { store.busy.contains(machine.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                infoGrid
                if let task = store.latestTask(for: machine.name), !task.finished || Date().timeIntervalSince(task.started) < 120 {
                    TaskOutputView(task: task)
                }
                consoleSection
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadConsole)
        .onReceive(ticker) { _ in loadConsole() }
        .onChange(of: machine.name) { _, _ in loadConsole() }
        .alert("Delete \"\(machine.name)\"?", isPresented: $ui.confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(machine.name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the machine and its \(Fmt.bytes(machine.diskUsed)) disk. It cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(machine.name).font(.system(size: 26, weight: .bold))
            HStack(spacing: 6) {
                StatusDot(machine: machine)
                Text(busy && !machine.isTransitioning ? "working…" : machine.state).foregroundStyle(.secondary)
            }
            .font(.callout)
            Spacer()
            if machine.isDefault {
                Label("Default", systemImage: "star.fill").font(.caption).foregroundStyle(.yellow)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if machine.isRunning {
                Button { store.openTerminal(machine.name) } label: { Label("Open Terminal", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent)
                    .disabled(machine.state == "booting")
                Button { store.stop(machine.name) } label: { Label("Stop", systemImage: "stop.fill") }
                Button { store.restart(machine.name) } label: { Label("Restart", systemImage: "arrow.clockwise") }
            } else {
                Button { store.start(machine.name) } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Set as Default") { store.setDefault(machine.name) }.disabled(machine.isDefault)
                Button("Copy SSH Command") { store.copySSHCommand(machine.name) }
                Button("Set up Docker in this machine…") { store.installDocker(machine.name) }.disabled(!machine.isRunning)
                Button("Show in Finder") { store.revealInFinder(machine) }
                Divider()
                Button("Force Stop") { store.stop(machine.name, force: true) }.disabled(!machine.isRunning)
                Button("Delete Machine…", role: .destructive) { ui.confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .disabled(busy)
    }

    private var infoGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            row("Distro", machine.distro)
            row("IP address", machine.ip ?? (machine.isRunning ? "…" : "—"))
            row("SSH", "ssh \(machine.name).shark")
            row("CPUs", "\(machine.cpus)")
            row("Memory", Fmt.bytes(machine.memoryMB << 20))
            row("Disk", "\(Fmt.bytes(machine.diskBytes)) · \(Fmt.bytes(machine.diskUsed)) used")
            row("Rosetta (x86_64)", machine.rosetta ? "enabled" : "off")
            row("Mac home in Linux", "/mnt/mac  (also /Users/\(machine.user))")
            row("Created", Fmt.date.string(from: machine.created))
            row("Location", machine.dir.path)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v)
        }
    }

    private var consoleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Button("Open Log File") { NSWorkspace.shared.open(machine.consoleLog) }.controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(consoleText.isEmpty ? "(no console output yet)" : consoleText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(height: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: consoleText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func loadConsole() {
        let text = MachineStore.tailOfFile(machine.consoleLog, maxBytes: 24_000)
        if text != ui.consoleText { ui.consoleText = text }
    }
}

/// Live output of one CLI invocation.
struct TaskOutputView: View {
    @ObservedObject var task: CLITask
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if task.finished {
                    Image(systemName: task.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(task.succeeded ? .green : .red)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(task.title).font(.headline)
                Spacer()
            }
            if !task.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(task.lines.suffix(200).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .onChange(of: task.lines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}
