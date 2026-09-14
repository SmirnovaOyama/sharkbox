import SwiftUI
import Combine
import AppKit

/// View-local state lives in small ObservableObjects: the macOS 26+ SDK implements `@State` as a
/// compiler macro whose plugin only ships with Xcode, and Sharkbox builds with the Command Line Tools.
final class MainUIState: ObservableObject {
    @Published var selection: String?
    @Published var search = ""
}

struct MainView: View {
    @EnvironmentObject var store: MachineStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = MainUIState()

    private var filtered: [MachineInfo] {
        let q = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.machines }
        return store.machines.filter {
            $0.name.lowercased().contains(q) || $0.distro.lowercased().contains(q) || ($0.ip ?? "").contains(q)
        }
    }

    private var selected: MachineInfo? { store.machines.first { $0.name == ui.selection } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let m = selected {
                MachineDetailView(machine: m, requestDelete: { store.requestDelete(m.name) })
            } else {
                emptyDetail
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .searchable(text: $ui.search, placement: .sidebar, prompt: "Filter machines")
        .onAppear(perform: pickDefault)
        .onChange(of: store.machines) { _, new in
            if let s = ui.selection, !new.contains(where: { $0.name == s }) { ui.selection = nil }
            if ui.selection == nil { pickDefault() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMachine)) { note in
            if let name = note.object as? String { ui.selection = name }
        }
        .alert("Delete \"\(store.pendingDelete ?? "")\"?", isPresented: Binding(
            get: { store.pendingDelete != nil }, set: { if !$0 { store.pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let n = store.pendingDelete { store.delete(n) }
                store.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { store.pendingDelete = nil }
        } message: {
            let m = store.machines.first { $0.name == store.pendingDelete }
            Text("This removes the machine and its \(Fmt.bytes(m?.diskUsed ?? 0)) disk image. It cannot be undone.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $ui.selection) {
            let running = filtered.filter(\.isRunning)
            let stopped = filtered.filter { !$0.isRunning }
            if !running.isEmpty {
                Section("Running") { ForEach(running) { row($0) } }
            }
            if !stopped.isEmpty {
                Section(running.isEmpty ? "Machines" : "Stopped") { ForEach(stopped) { row($0) } }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        .overlay { if store.machines.isEmpty { emptySidebar } }
        .safeAreaInset(edge: .bottom) { sidebarFooter }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "new-machine")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Glyph(kind: .plus, size: 15)
                }
                .help("Create a new Linux machine (⌘N)")
            }
        }
    }

    private func row(_ m: MachineInfo) -> some View {
        MachineRow(machine: m, requestDelete: { store.requestDelete(m.name) }).tag(m.name)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Text("\(Fmt.bytes(store.stateSize)) used · \(Fmt.bytes(store.freeSpace)) free")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }

    private var emptySidebar: some View {
        VStack(spacing: 10) {
            AppMark(size: 56).opacity(0.85)
            Text("No machines yet").foregroundStyle(.secondary)
            Button("New Machine…") {
                openWindow(id: "new-machine")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding()
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            AppMark(size: 76).opacity(0.9)
            Text("Select a machine").font(.title3).foregroundStyle(.secondary)
            if !store.cliInstalled {
                Label {
                    Text("The shark command was not found at \(store.cliPath). Run `make install` in the Sharkbox folder.")
                } icon: {
                    Glyph(kind: .warning, size: 14, color: .orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }
        }
    }

    private func pickDefault() {
        if ui.selection == nil {
            ui.selection = store.machines.first(where: { $0.isDefault })?.name ?? store.machines.first?.name
        }
    }
}

// MARK: - Sidebar row

struct MachineRow: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo
    var requestDelete: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            DistroMark(distro: machine.distro, size: 17)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(machine.name).fontWeight(.medium).lineLimit(1)
                    if machine.isDefault {
                        Glyph(kind: .star, size: 8, color: .secondary)
                            .help("Default machine")
                    }
                }
                Text(machine.ip ?? machine.state)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusDot(machine: machine)
        }
        .padding(.vertical, 2)
        .contextMenu { MachineMenuItems(machine: machine, requestDelete: requestDelete) }
    }
}

/// The full action list for one machine, reused by the sidebar context menu, the detail "More" menu
/// and the menu bar. Nested submenus keep the destructive and rarely-used items one level down.
struct MachineMenuItems: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo
    var requestDelete: () -> Void

    var body: some View {
        if machine.isRunning {
            Button("Open Terminal") { store.openTerminal(machine.name) }
                .disabled(machine.state != "running")
            Button("Stop") { store.stop(machine.name) }
            Button("Restart") { store.restart(machine.name) }
        } else {
            Button("Start") { store.start(machine.name) }
        }

        Divider()

        Menu("Copy") {
            Button("SSH Command") { store.copyToPasteboard("ssh \(machine.name).shark") }
            Button("IP Address") { store.copyToPasteboard(machine.ip ?? "") }
                .disabled(machine.ip == nil)
            Button("Shell Command") { store.copyToPasteboard("shark shell \(machine.name)") }
            Button("Machine Folder Path") { store.copyToPasteboard(machine.dir.path) }
        }

        Menu("Maintenance") {
            Button("Set Up Docker…") { store.installDocker(machine.name) }
                .disabled(!machine.isRunning)
            Divider()
            Button("Check Filesystem") { store.fsck(machine.name, repair: false) }
                .disabled(machine.isRunning)
            Button("Repair Filesystem") { store.fsck(machine.name, repair: true) }
                .disabled(machine.isRunning)
            Divider()
            Button("Force Stop") { store.stop(machine.name, force: true) }
                .disabled(!machine.isRunning)
        }

        Button("Show in Finder") { store.revealInFinder(machine) }
        Button("Set as Default") { store.setDefault(machine.name) }
            .disabled(machine.isDefault)

        Divider()
        Button("Delete…", role: .destructive) { requestDelete() }
    }
}

struct StatusDot: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo

    var body: some View {
        if machine.isTransitioning || store.busy.contains(machine.name) {
            RingSpinner(size: 14, lineWidth: 2, color: .secondary)
        } else if machine.isRunning || machine.state == "error" {
            Circle().fill(machine.stateColor).frame(width: 7, height: 7).frame(width: 14, height: 14)
        }
        // Nothing for a stopped machine: the sidebar is already split into Running / Stopped and
        // every row spells out its state, so a grey haloed dot per row was pure noise.
    }
}

// MARK: - Detail

final class DetailUIState: ObservableObject {
    enum Tab: String, CaseIterable { case overview = "Overview", console = "Console", resources = "Resources" }
    @Published var tab: Tab = .overview
    @Published var consoleText = ""            // plain, for Copy and change detection
    @Published var consoleStyled = AttributedString()
    @Published var follow = true
    @Published var machineName = ""
    @Published var cpus = 1
    @Published var memoryGB = 1
    @Published var diskGB = 8
}

struct MachineDetailView: View {
    @EnvironmentObject var store: MachineStore
    let machine: MachineInfo
    var requestDelete: () -> Void
    @StateObject private var ui = DetailUIState()
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var busy: Bool { store.busy.contains(machine.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("", selection: $ui.tab) {
                ForEach(DetailUIState.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            // Console scrolls itself and wants the whole pane. Nesting it in the tab ScrollView
            // put two scrollers inside each other and let its toolbar scroll out of reach.
            switch ui.tab {
            case .console:
                consoleTab
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .overview, .resources:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if ui.tab == .overview { overview } else { resourcesTab }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { reload(force: true) }
        .onReceive(ticker) { _ in reload(force: false) }
        .onChange(of: machine.name) { _, _ in reload(force: true) }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            DistroMark(distro: machine.distro, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(machine.name).font(.system(size: 22, weight: .semibold))
                    if machine.isDefault {
                        Glyph(kind: .star, size: 10, color: .secondary).help("Default machine")
                    }
                }
                HStack(spacing: 6) {
                    StatusDot(machine: machine)
                    Text(statusText).foregroundStyle(.secondary).font(.callout)
                }
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusText: String {
        if busy && !machine.isTransitioning { return "working…" }
        switch machine.state {
        case "booting": return "booting…"
        case "running": return machine.ip.map { "running · \($0)" } ?? "running"
        default: return machine.state
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if machine.isRunning {
                Button { store.openTerminal(machine.name) } label: {
                    Label { Text("Terminal") } icon: { Glyph(kind: .terminal, size: 14) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(machine.state != "running")
                Button { store.stop(machine.name) } label: {
                    Label { Text("Stop") } icon: { Glyph(kind: .stop, size: 12) }
                }
                Button { store.restart(machine.name) } label: { Glyph(kind: .restart, size: 14) }
                    .help("Restart")
            } else {
                Button { store.start(machine.name) } label: {
                    Label { Text("Start") } icon: { Glyph(kind: .play, size: 12) }
                }
                .buttonStyle(.borderedProminent)
            }
            Menu {
                MachineMenuItems(machine: machine, requestDelete: requestDelete)
            } label: {
                Glyph(kind: .ellipsis, size: 15)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .disabled(busy)
    }

    // MARK: overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                statCard(.cpu, "\(machine.cpus)", machine.cpus == 1 ? "CPU" : "CPUs")
                statCard(.memory, Fmt.bytes(machine.memoryMB << 20), "memory")
                statCard(.disk, Fmt.bytes(machine.diskUsed), "of \(Fmt.bytes(machine.diskBytes))")
                statCard(.network, machine.ip ?? "—", "address")
            }
            if !machine.cleanShutdown && !machine.isRunning {
                Label {
                    Text("This machine was not shut down cleanly. Its filesystem will be checked automatically on the next start.")
                } icon: {
                    Glyph(kind: .warning, size: 14, color: .orange)
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            infoGrid
            if let task = store.latestTask(for: machine.name), !task.finished || Date().timeIntervalSince(task.started) < 90 {
                TaskOutputView(task: task)
            }
        }
    }

    private func statCard(_ glyph: Glyph.Kind, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                Glyph(kind: glyph, size: 11, color: .secondary)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: Self.tile)
        .overlay(Self.tile.strokeBorder(.quaternary, lineWidth: 0.5))
    }

    /// One shape for every panel in the detail view, so the corner radius stops drifting (it was
    /// 7, 8 and 9 in three adjacent places).
    static let tile = RoundedRectangle(cornerRadius: 8, style: .continuous)

    private var infoGrid: some View {
        VStack(spacing: 0) {
            infoRow("Distribution", machine.distroTitle)
            Divider()
            infoRow("SSH", "ssh \(machine.name).shark", mono: true)
            Divider()
            infoRow("Rosetta", machine.rosetta ? "enabled — x86_64 binaries run" : "off")
            Divider()
            infoRow("Mac home in Linux", "/mnt/mac", mono: true)
            Divider()
            infoRow("Created", Fmt.date.string(from: machine.created))
            Divider()
            infoRow("Location", machine.dir.path, mono: true)
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.22), in: Self.tile)
        .overlay(Self.tile.strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func infoRow(_ k: String, _ v: String, mono: Bool = false) -> some View {
        // Deliberately not LabeledContent: outside a Form it lays the label out in a centred
        // column, which left the text huddled in the middle of a full-width card with a dead
        // gutter down each side. Pin the label to the leading edge and the value to the trailing.
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(k).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text(v)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
                .help(v)
        }
        .padding(.vertical, 8)
    }

    // MARK: console

    private var consoleTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Follow", isOn: $ui.follow).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Button { store.copyToPasteboard(ui.consoleText) } label: {
                    Label { Text("Copy") } icon: { Glyph(kind: .copy, size: 12) }
                }
                .controlSize(.small)
                Button { NSWorkspace.shared.open(machine.consoleLog) } label: {
                    Label { Text("Open Log") } icon: { Glyph(kind: .folder, size: 12) }
                }
                .controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if ui.consoleText.isEmpty {
                            Text("(no console output yet)").foregroundStyle(.secondary)
                        } else {
                            Text(ui.consoleStyled)
                        }
                    }
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(Self.tile)
                .overlay(Self.tile.strokeBorder(.quaternary, lineWidth: 0.5))
                .onChange(of: ui.consoleText) { _, _ in
                    if ui.follow { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    // MARK: resources

    private var resourcesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if machine.isRunning {
                Label {
                    Text("Stop \(machine.name) to change its resources.")
                } icon: {
                    Glyph(kind: .info, size: 14, color: .secondary)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Stepper("CPUs: \(ui.cpus)", value: $ui.cpus, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                Stepper("Memory: \(ui.memoryGB) GB", value: $ui.memoryGB,
                        in: 1...max(2, Int(ProcessInfo.processInfo.physicalMemory >> 30)))
                // The CLI puts no ceiling on --disk, so `shark set --disk 3t` used to make this
                // range's lowerBound exceed its upperBound and trap the whole app on this tab.
                Stepper("Disk: \(ui.diskGB) GB", value: $ui.diskGB,
                        in: diskFloor...max(diskFloor, 2048), step: 8)
                Text("A disk can only grow. Growing it resizes the guest filesystem offline, which takes a few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            // Fill the pane like the Overview tab does. Capping this at 420 left a narrow column
            // hugging the left edge of a wide window with a dead expanse beside it.
            .fixedSize(horizontal: false, vertical: true)
            .disabled(machine.isRunning || busy)

            HStack {
                Button("Revert") { loadResourceFields() }
                    .disabled(!resourcesChanged)
                Button("Apply Changes") {
                    store.setResources(machine.name,
                                       cpus: ui.cpus != machine.cpus ? ui.cpus : nil,
                                       memoryGB: ui.memoryGB != machineMemoryGB ? ui.memoryGB : nil,
                                       diskGB: ui.diskGB != diskFloor ? ui.diskGB : nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(machine.isRunning || busy || !resourcesChanged)
            }
        }
    }

    /// Compared at the same whole-GB granularity the steppers edit at. Comparing the reconstructed
    /// byte counts instead left Apply permanently enabled for any machine whose memory or disk was
    /// not an exact multiple of 1 GiB — and applying it silently rounded the machine down.
    private var resourcesChanged: Bool {
        ui.cpus != machine.cpus || ui.memoryGB != machineMemoryGB || ui.diskGB != diskFloor
    }

    private var machineMemoryGB: Int { max(1, Int(machine.memoryMB / 1024)) }
    private var diskFloor: Int { max(1, Int(machine.diskBytes >> 30)) }

    // MARK: loading

    private func reload(force: Bool) {
        let lines = Int(store.settings.consoleLines)
        let styled = MachineStore.consoleTail(machine.consoleLog, maxBytes: max(8_000, lines * 90))
        let text = String(styled.characters)
        if text != ui.consoleText {
            ui.consoleText = text
            ui.consoleStyled = styled
        }
        if force || ui.machineName != machine.name {
            ui.machineName = machine.name
            loadResourceFields()
        }
    }

    private func loadResourceFields() {
        ui.cpus = machine.cpus
        ui.memoryGB = machineMemoryGB
        ui.diskGB = diskFloor
    }
}

/// Live output of one CLI invocation.
struct TaskOutputView: View {
    @ObservedObject var task: CLITask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if task.finished {
                    Glyph(kind: task.succeeded ? .check : .xmark, size: 14,
                          color: task.succeeded ? .green : .red)
                        .frame(width: 20, height: 20)
                } else {
                    RingSpinner(size: 20, lineWidth: 2.5)
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
                    .frame(maxHeight: 170)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.3)))
                    .onChange(of: task.lines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}
