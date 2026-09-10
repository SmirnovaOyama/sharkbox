import SwiftUI

final class NewMachineForm: ObservableObject {
    static let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
    static let hostMemGB = max(2, Int(ProcessInfo.processInfo.physicalMemory >> 30))
    @Published var distroID = "ubuntu:24.04"
    @Published var name = "ubuntu"
    @Published var cpus = min(4, hostCPUs)
    @Published var memoryGB = min(4, max(1, hostMemGB / 4))
    @Published var diskGB = 64
    @Published var rosetta = true
    @Published var task: CLITask?

    /// Apply the Settings ▸ New Machines defaults. These used to be written to UserDefaults and read
    /// by nothing, so the whole preference pane was inert.
    func seed(from s: AppSettings) {
        cpus = min(max(1, s.defaultCPUs), NewMachineForm.hostCPUs)
        memoryGB = min(max(1, s.defaultMemoryGB), NewMachineForm.hostMemGB)
        diskGB = max(8, s.defaultDiskGB)
        rosetta = s.defaultRosetta
    }
}

struct NewMachineView: View {
    @EnvironmentObject var store: MachineStore
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var f = NewMachineForm()

    private var nameValid: Bool { Machine.validName(f.name) }
    private var nameTaken: Bool { Machine.exists(f.name) }
    private var canCreate: Bool { nameValid && !nameTaken && (activeTask == nil || activeTask!.finished) }

    /// The create this panel should still be reporting on. A finished create stops counting once
    /// its machine is gone: this is a persistent Window scene, so otherwise "Machine created" sits
    /// there advertising a machine the user has since deleted.
    private var activeTask: CLITask? {
        guard let t = f.task else { return nil }
        if t.finished, let name = t.machine, !store.machines.contains(where: { $0.name == name }) {
            return nil
        }
        return t
    }

    /// `shark create` writes the machine's config.json early, so `nameTaken` flips true partway
    /// through a create and the form would tell you the machine you are creating already exists.
    /// Only validate the name while the form is actually editable again.
    private var editing: Bool {
        guard let t = activeTask else { return true }
        return t.finished && !t.succeeded
    }

    /// Drop a completed create so the form goes back to being a blank one.
    private func clearFinishedTask() {
        if let t = f.task, t.finished { f.task = nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Distribution", selection: $f.distroID) {
                        ForEach(Distro.all, id: \.id) { d in
                            Text(d.title + (Images.isPrepared(d) ? "" : "  (downloads ~600 MB)")).tag(d.id)
                        }
                    }
                    TextField("Name", text: $f.name)
                    if editing && !f.name.isEmpty && !nameValid {
                        Text("Lowercase letters, digits and dashes only.").font(.caption).foregroundStyle(.red)
                    } else if editing && nameTaken {
                        Text("A machine named \"\(f.name)\" already exists.").font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Resources") {
                    Stepper("CPUs: \(f.cpus)", value: $f.cpus, in: 1...NewMachineForm.hostCPUs)
                    Stepper("Memory: \(f.memoryGB) GB", value: $f.memoryGB, in: 1...NewMachineForm.hostMemGB)
                    Stepper("Disk: \(f.diskGB) GB (grows on demand)", value: $f.diskGB, in: 8...2048, step: 8)
                    Toggle("Rosetta — run x86_64 Linux binaries", isOn: $f.rosetta)
                }
            }
            .formStyle(.grouped)
            // A grouped Form is a scroll view and will happily expand, leaving a band of dead
            // space above the buttons. Report the ideal height instead so the window hugs it.
            .fixedSize(horizontal: false, vertical: true)

            if let task = activeTask {
                TaskOutputView(task: task).padding([.horizontal, .bottom], 16)
            }

            Divider()
            HStack {
                if let task = activeTask, task.succeeded {
                    Label("Machine created", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button(activeTask?.succeeded == true ? "Close" : "Cancel") {
                    // Reset here rather than on appear, so ⌘N next time opens a blank form.
                    clearFinishedTask()
                    dismissWindow(id: "new-machine")
                }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
            .padding(14)
        }
        // One width for the whole window, not just the form: `.windowResizability(.contentSize)`
        // then sizes the window to it, so the buttons stay with the content they belong to.
        .frame(width: 480)
        .onAppear {
            // Deliberately no clearFinishedTask() here: onAppear fires again whenever the window
            // re-mounts (switching Spaces is enough), and it would erase the result of a create
            // the user just watched succeed.
            // Don't stomp a create that is still streaming its output.
            if f.task == nil { f.seed(from: store.settings) }
            if let id = store.pendingNewMachineDistro {
                store.pendingNewMachineDistro = nil
                if let d = Distro.find(id) { f.distroID = d.id; f.name = d.family }
            }
        }
        .onChange(of: f.name) { _, _ in clearFinishedTask() }
        .onChange(of: f.distroID) { old, new in
            clearFinishedTask()
            // Follow the distro with the default name unless the user typed their own.
            if f.name.isEmpty || f.name == Distro.find(old)?.family, let d = Distro.find(new) {
                f.name = d.family
            }
        }
    }

    private func create() {
        f.task = store.create(distro: f.distroID, name: f.name, cpus: f.cpus, memoryGB: f.memoryGB, diskGB: f.diskGB, rosetta: f.rosetta)
    }
}
