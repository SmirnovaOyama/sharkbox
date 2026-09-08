import Foundation
import SwiftUI
import AppKit

/// A snapshot of one machine, read from ~/.orbshark/machines/<name>/.
struct MachineInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let distro: String
    let state: String          // running / booting / stopped / starting / stopping / error
    let ip: String?
    let cpus: Int
    let memoryMB: UInt64
    let diskBytes: UInt64
    let diskUsed: UInt64
    let rosetta: Bool
    let user: String
    let isDefault: Bool
    let created: Date
    let dir: URL
    let consoleLog: URL

    var isRunning: Bool { state == "running" || state == "booting" }
    var isTransitioning: Bool { state == "starting" || state == "stopping" || state == "booting" }

    var stateColor: Color {
        switch state {
        case "running": return .green
        case "booting", "starting", "stopping": return .orange
        case "error": return .red
        default: return .gray
        }
    }
}

/// One invocation of the `shark` CLI, with its captured output.
final class CLITask: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let machine: String?
    let started = Date()
    @Published var lines: [String] = []
    @Published var finished = false
    @Published var exitCode: Int32?

    init(title: String, machine: String?) {
        self.title = title
        self.machine = machine
    }
    var succeeded: Bool { finished && exitCode == 0 }
}

/// Splits a byte stream into lines, thread-safe.
private final class LineBuffer {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        var out: [String] = []
        while let nl = data.firstIndex(of: 0x0a) {
            out.append(String(decoding: data[data.startIndex..<nl], as: UTF8.self))
            data.removeSubrange(data.startIndex...nl)
        }
        return out
    }
    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return [] }
        let s = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return [s]
    }
}

final class MachineStore: ObservableObject {
    static let shared = MachineStore()

    @Published var machines: [MachineInfo] = []
    @Published var tasks: [CLITask] = []
    @Published var busy: Set<String> = []
    @Published var lastError: String?
    let cliPath: String
    private var timer: Timer?

    init() {
        cliPath = MachineStore.findCLI()
        try? Paths.ensure()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Prefer the installed CLI (so ssh_config / ProxyCommand paths stay consistent), else the bundled copy.
    static func findCLI() -> String {
        let candidates = [
            "/opt/homebrew/bin/shark",
            "/usr/local/bin/shark",
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/shark").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    var cliInstalled: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    // MARK: - State

    func refresh() {
        let def = readString(Paths.defaultMachine)
        let list = Machine.all().map { m -> MachineInfo in
            var state = m.state
            if state == "running" && m.ip == nil { state = "booting" }
            return MachineInfo(
                name: m.name, distro: m.config.distro, state: state,
                ip: m.isRunning ? m.ip : nil,
                cpus: m.config.cpus, memoryMB: m.config.memoryMB, diskBytes: m.config.diskBytes,
                diskUsed: MachineStore.diskUsage(m.diskImage),
                rosetta: m.config.rosetta, user: m.config.user,
                isDefault: m.name == def, created: m.config.created,
                dir: m.dir, consoleLog: m.consoleLog)
        }
        if list != machines { machines = list }
    }

    static func diskUsage(_ url: URL) -> UInt64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return UInt64(st.st_blocks) * 512
    }

    func latestTask(for machine: String) -> CLITask? {
        tasks.first { $0.machine == machine }
    }

    // MARK: - Running the CLI

    @discardableResult
    func run(_ args: [String], title: String, machine: String?, completion: ((Int32) -> Void)? = nil) -> CLITask {
        let task = CLITask(title: title, machine: machine)
        tasks.insert(task, at: 0)
        if tasks.count > 30 { tasks.removeLast(tasks.count - 30) }
        if let machine { busy.insert(machine) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty else { return }
            let lines = buffer.append(d)
            if !lines.isEmpty { DispatchQueue.main.async { task.lines.append(contentsOf: lines) } }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = buffer.append(pipe.fileHandleForReading.readDataToEndOfFile()) + buffer.flush()
            DispatchQueue.main.async {
                task.lines.append(contentsOf: rest.filter { !$0.isEmpty })
                task.finished = true
                task.exitCode = proc.terminationStatus
                if let machine { self?.busy.remove(machine) }
                self?.refresh()
                if proc.terminationStatus != 0 {
                    self?.lastError = "\(title) failed: " + (task.lines.last(where: { $0.contains("✗") }) ?? task.lines.last ?? "exit \(proc.terminationStatus)")
                        .replacingOccurrences(of: "✗ ", with: "")
                }
                completion?(proc.terminationStatus)
            }
        }
        do {
            try p.run()
        } catch {
            task.lines.append("cannot run \(cliPath): \(error)")
            task.finished = true
            task.exitCode = 127
            if let machine { busy.remove(machine) }
            lastError = "Cannot run the shark CLI at \(cliPath)"
        }
        return task
    }

    // MARK: - Actions

    func start(_ name: String)   { run(["start", name], title: "Start \(name)", machine: name) }
    func stop(_ name: String, force: Bool = false) {
        run(force ? ["stop", "-f", name] : ["stop", name], title: (force ? "Force stop " : "Stop ") + name, machine: name)
    }
    func restart(_ name: String) { run(["restart", name], title: "Restart \(name)", machine: name) }
    func delete(_ name: String)  { run(["delete", "-f", name], title: "Delete \(name)", machine: name) }
    func setDefault(_ name: String) { run(["default", name], title: "Set default \(name)", machine: nil) }
    func installDocker(_ name: String) { run(["docker", name], title: "Set up Docker in \(name)", machine: name) }

    func create(distro: String, name: String, cpus: Int, memoryGB: Int, diskGB: Int, rosetta: Bool) -> CLITask {
        var args = ["create", distro, name, "--cpus", "\(cpus)", "--memory", "\(memoryGB)g", "--disk", "\(diskGB)g"]
        if !rosetta { args.append("--no-rosetta") }
        return run(args, title: "Create \(name)", machine: name)
    }

    /// Open a Terminal window running `shark shell <name>` (via a .command file — no Automation permission needed).
    func openTerminal(_ name: String) {
        let dir = Paths.root.appendingPathComponent("terminal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).command")
        let script = "#!/bin/sh\nclear\nexec \(shellQuote(cliPath)) shell \(shellQuote(name))\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let terminal = UserDefaults.standard.string(forKey: "terminalApp") ?? "Terminal"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", terminal, file.path]
        try? p.run()
    }

    func copySSHCommand(_ name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ssh \(name).shark", forType: .string)
    }

    func revealInFinder(_ m: MachineInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([m.dir])
    }

    /// Last ~64 KB of a console log, for the detail view.
    static func tailOfFile(_ url: URL, maxBytes: Int = 65536) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        let data = fh.readDataToEndOfFile()
        var s = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        // strip ANSI colour codes systemd prints on the console
        return s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}
