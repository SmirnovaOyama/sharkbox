import SwiftUI

/// Manages the cached distribution images that machines are cloned from.
struct ImagesView: View {
    @EnvironmentObject var store: MachineStore
    @StateObject private var ui = ImagesUIState()

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.images) { img in
                    HStack(spacing: 10) {
                        DistroMark(distro: img.id, size: 22, color: img.downloaded ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(img.title).fontWeight(.medium)
                            Text(img.downloaded
                                 ? "\(Fmt.bytes(img.bytes)) on disk · \(img.boot) boot"
                                 : "not downloaded · \(img.boot) boot")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if img.inUse {
                            Text("in use").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        if img.downloaded {
                            Button { ui.confirmRemove = img.id } label: { Glyph(kind: .trash, size: 14) }
                                .buttonStyle(.borderless)
                                .help("Delete the cached image (existing machines keep working)")
                        } else {
                            Button { store.pullImage(img.id) } label: { Glyph(kind: .download, size: 14) }
                                .buttonStyle(.borderless)
                                .help("Download this image now")
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            if let task = store.tasks.first(where: { $0.title.hasPrefix("Download") || $0.title.hasPrefix("Remove image") }),
               !task.finished {
                Divider()
                TaskOutputView(task: task).padding(12)
            }
        }
        .alert("Delete the cached image?", isPresented: Binding(
            get: { ui.confirmRemove != nil }, set: { if !$0 { ui.confirmRemove = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = ui.confirmRemove { store.removeImage(id) }
                ui.confirmRemove = nil
            }
            Button("Cancel", role: .cancel) { ui.confirmRemove = nil }
        } message: {
            Text("Machines created from it keep working. Creating a new machine from this distro will download it again.")
        }
        .onAppear { store.refreshImages() }
    }
}

final class ImagesUIState: ObservableObject {
    @Published var confirmRemove: String?
}

/// The about box — same fin as the icon and the menu bar, drawn at 96 pt.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            AppMark(size: 96)
            VStack(spacing: 3) {
                Text("Sharkbox").font(.system(size: 26, weight: .semibold))
                Text("Version \(appVersion)").foregroundStyle(.secondary)
            }
            Text("Free Linux machines on macOS, built on Apple's Virtualization framework.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(width: 300)
            HStack(spacing: 18) {
                infoItem(.cpu, "Apple silicon")
                infoItem(.bolt, "No daemon")
                infoItem(.shield, "No telemetry")
            }
            .padding(.top, 2)
            Text(Paths.root.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(30)
        .frame(width: 420)
    }

    private func infoItem(_ glyph: Glyph.Kind, _ label: String) -> some View {
        VStack(spacing: 4) {
            Glyph(kind: glyph, size: 18, color: .secondary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }
}
