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
}

struct NewMachineView: View {
    @EnvironmentObject var store: MachineStore
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var f = NewMachineForm()

    private var nameValid: Bool { Machine.validName(f.name) }
    private var nameTaken: Bool { Machine.exists(f.name) }
    private var canCreate: Bool { nameValid && !nameTaken && (f.task == nil || f.task!.finished) }

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
                    if !f.name.isEmpty && !nameValid {
                        Text("Lowercase letters, digits and dashes only.").font(.caption).foregroundStyle(.red)
                    } else if nameTaken {
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
            .frame(width: 480)

            if let task = f.task {
                TaskOutputView(task: task).padding([.horizontal, .bottom], 16).frame(width: 480)
            }

            Divider()
            HStack {
                if let task = f.task, task.finished, task.succeeded {
                    Label("Machine created", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button(f.task?.succeeded == true ? "Close" : "Cancel") { dismissWindow(id: "new-machine") }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
            .padding(14)
        }
        .onChange(of: f.distroID) { old, new in
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
