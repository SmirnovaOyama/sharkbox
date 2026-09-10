import Foundation
import SwiftUI
import AppKit
import Combine

/// A snapshot of one machine, read from ~/.sharkbox/machines/<name>/.
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
    let cleanShutdown: Bool

    var distroTitle: String { Distro.find(distro)?.title ?? distro }

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
    @Published var images: [ImageInfo] = []
    let settings = AppSettings()
    /// Requests raised from the menu bar / app menu, which may fire while the main window is closed.
    /// They live here rather than in a NotificationCenter message so the state survives until the
    /// window actually mounts and can act on it.
    @Published var pendingDelete: String?
    @Published var pendingNewMachineDistro: String?
    @Published var tasks: [CLITask] = []
    @Published var busy: Set<String> = []
    @Published var lastError: String?
    let cliPath: String
    private var timer: Timer?
    /// `settings` is a nested ObservableObject: without this, changing a preference publishes on
    /// `settings` only and no view observing the store is ever invalidated.
    private var settingsSink: AnyCancellable?

    init() {
        cliPath = MachineStore.findCLI()
        settingsSink = settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        try? Paths.ensure()
        refresh()
        refreshImages()
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = max(1, settings.refreshSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
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
                dir: m.dir, consoleLog: m.consoleLog,
                cleanShutdown: fileExists(m.cleanFlag))
        }
        if list != machines {
            machines = list
            refreshImages()
        }
    }

    /// Free space on the volume holding the Sharkbox state directory.
    var freeSpace: UInt64 {
        let v = try? Paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, v?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    var stateSize: UInt64 {
        Images.directorySize(Paths.machines) + Images.directorySize(Paths.images)
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

    /// Honours the "Ask before deleting" preference, which nothing used to consult.
    func requestDelete(_ name: String) {
        if settings.confirmDestructive { pendingDelete = name } else { delete(name) }
    }
    func setDefault(_ name: String) { run(["default", name], title: "Set default \(name)", machine: nil) }
    func installDocker(_ name: String) { run(["docker", name], title: "Set up Docker in \(name)", machine: name) }

    func create(distro: String, name: String, cpus: Int, memoryGB: Int, diskGB: Int, rosetta: Bool) -> CLITask {
        var args = ["create", distro, name, "--cpus", "\(cpus)", "--memory", "\(memoryGB)g", "--disk", "\(diskGB)g"]
        if !rosetta { args.append("--no-rosetta") }
        return run(args, title: "Create \(name)", machine: name)
    }

    var running: [MachineInfo] { machines.filter(\.isRunning) }
    var stopped: [MachineInfo] { machines.filter { !$0.isRunning } }

    /// Open a Terminal window running `shark shell <name>` (via a .command file — no Automation permission needed).
    func openTerminal(_ name: String) {
        let dir = Paths.root.appendingPathComponent("terminal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).command")
        let script = "#!/bin/sh\nclear\nexec \(shellQuote(cliPath)) shell \(shellQuote(name))\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let terminal = settings.terminalApp
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

    // MARK: - Images

    func refreshImages() {
        let list = Distro.all.map { d in
            ImageInfo(id: d.id, title: d.title, aliases: d.aliases.filter { $0 != d.id },
                      boot: d.boot.rawValue, downloaded: Images.isPrepared(d),
                      bytes: Images.isPrepared(d) ? Images.size(d) : 0,
                      inUse: machines.contains { $0.distro == d.id })
        }
        if list != images { images = list }
    }

    func pullImage(_ id: String) {
        run(["pull", id], title: "Download \(id)", machine: nil) { [weak self] _ in self?.refreshImages() }
    }

    func removeImage(_ id: String) {
        run(["image", "rm", id], title: "Remove image \(id)", machine: nil) { [weak self] _ in self?.refreshImages() }
    }

    // MARK: - Maintenance

    func fsck(_ name: String, repair: Bool) {
        run(repair ? ["fsck", "--repair", name] : ["fsck", name],
            title: (repair ? "Repair filesystem of " : "Check filesystem of ") + name, machine: name)
    }

    func setResources(_ name: String, cpus: Int?, memoryGB: Int?, diskGB: Int?) {
        var args = ["set", name]
        if let cpus { args += ["--cpus", "\(cpus)"] }
        if let memoryGB { args += ["--memory", "\(memoryGB)g"] }
        if let diskGB { args += ["--disk", "\(diskGB)g"] }
        run(args, title: "Reconfigure \(name)", machine: name)
    }

    func installSSHConfig() {
        run(["ssh-config", "--install"], title: "Install ssh config", machine: nil)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        if start > 0 {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
            // A cut through an escape sequence strands its tail, e.g. a bare "0;1;39m".
            s = s.replacingOccurrences(of: "^[0-9;]*m", with: "", options: .regularExpression)
        }
        return normalizeConsole(s)
    }

    /// The console tail with systemd's own ANSI colours turned into real styling. Stripping them
    /// left a flat grey wall of text with every unit printed twice and nothing to tell the two
    /// apart; the colours are most of what makes a boot log readable.
    static func consoleTail(_ url: URL, maxBytes: Int) -> AttributedString {
        ansiAttributed(tailOfFile(url, maxBytes: maxBytes))
    }

    /// Black and white map to the theme's own colours so the log stays readable in both.
    private static let ansiPalette: [Color] = [
        .secondary, .red, .green, .yellow, .blue, .purple, .teal, .primary,
    ]

    static func ansiAttributed(_ s: String) -> AttributedString {
        let mono = Font.system(size: 12, design: .monospaced)
        var out = AttributedString()
        var chunk = ""
        var color: Color?
        var bold = false

        func flush() {
            guard !chunk.isEmpty else { return }
            var piece = AttributedString(chunk)
            piece.font = bold ? mono.weight(.semibold) : mono
            if let color { piece.foregroundColor = color }
            out += piece
            chunk = ""
        }
        func select(_ params: String) {
            let codes = params.split(separator: ";").compactMap { Int($0) }
            guard !codes.isEmpty else { color = nil; bold = false; return }   // bare ESC[m resets
            for c in codes {
                switch c {
                case 0:        color = nil; bold = false
                case 1:        bold = true
                case 22:       bold = false
                case 30...37:  color = ansiPalette[c - 30]
                case 90...97:  color = ansiPalette[c - 90]
                case 39:       color = nil
                default:       break
                }
            }
        }

        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            guard c == "\u{1B}", next < s.endIndex, s[next] == "[" else {
                chunk.append(c)
                i = next
                continue
            }
            var j = s.index(after: next)
            var params = ""
            while j < s.endIndex, !("@"..."~").contains(s[j]) {
                params.append(s[j])
                j = s.index(after: j)
            }
            flush()
            if j < s.endIndex {
                if s[j] == "m" { select(params) }      // every other CSI verb is just dropped
                i = s.index(after: j)
            } else {
                i = s.endIndex
            }
        }
        flush()
        return out
    }

    /// The serial console is a terminal stream, not a text file: lines arrive CRLF-terminated and
    /// systemd rewrites a line in place with a bare CR ("Starting foo…\r[  OK  ] Started foo.").
    /// Rendered verbatim every CR became another line break, so the log came out double-spaced
    /// with each status line shown twice. Keep what a terminal would still be displaying.
    static func normalizeConsole(_ s: String) -> String {
        guard s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard line.contains("\r") else { return line }
                let segs = line.split(separator: "\r", omittingEmptySubsequences: false)
                return segs.last(where: { !$0.isEmpty }) ?? ""
            }
            .joined(separator: "\n")
    }
}


// MARK: - Images

struct ImageInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let aliases: [String]
    let boot: String
    let downloaded: Bool
    let bytes: UInt64
    let inUse: Bool
}

// MARK: - Settings

/// User preferences, stored in the standard defaults database so the CLI-free parts of the app
/// and a future `shark` flag can read the same values.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var terminalApp: String { didSet { d.set(terminalApp, forKey: "terminalApp") } }
    @Published var refreshSeconds: Double { didSet { d.set(refreshSeconds, forKey: "refreshSeconds") } }
    @Published var confirmDestructive: Bool { didSet { d.set(confirmDestructive, forKey: "confirmDestructive") } }
    @Published var menuBarShowsStopped: Bool { didSet { d.set(menuBarShowsStopped, forKey: "menuBarShowsStopped") } }
    @Published var consoleLines: Double { didSet { d.set(consoleLines, forKey: "consoleLines") } }
    @Published var defaultCPUs: Int { didSet { d.set(defaultCPUs, forKey: "defaultCPUs") } }
    @Published var defaultMemoryGB: Int { didSet { d.set(defaultMemoryGB, forKey: "defaultMemoryGB") } }
    @Published var defaultDiskGB: Int { didSet { d.set(defaultDiskGB, forKey: "defaultDiskGB") } }
    @Published var defaultRosetta: Bool { didSet { d.set(defaultRosetta, forKey: "defaultRosetta") } }

    static let knownTerminals = ["Terminal", "iTerm", "Ghostty", "WezTerm", "Alacritty", "kitty", "Warp"]

    init() {
        d.register(defaults: [
            "terminalApp": "Terminal",
            "refreshSeconds": 2.0,
            "confirmDestructive": true,
            "menuBarShowsStopped": true,
            "consoleLines": 400.0,
            "defaultCPUs": min(4, ProcessInfo.processInfo.activeProcessorCount),
            "defaultMemoryGB": min(4, max(1, Int(ProcessInfo.processInfo.physicalMemory >> 30) / 4)),
            "defaultDiskGB": 64,
            "defaultRosetta": true,
        ])
        terminalApp = d.string(forKey: "terminalApp") ?? "Terminal"
        refreshSeconds = d.double(forKey: "refreshSeconds")
        confirmDestructive = d.bool(forKey: "confirmDestructive")
        menuBarShowsStopped = d.bool(forKey: "menuBarShowsStopped")
        consoleLines = d.double(forKey: "consoleLines")
        defaultCPUs = d.integer(forKey: "defaultCPUs")
        defaultMemoryGB = d.integer(forKey: "defaultMemoryGB")
        defaultDiskGB = d.integer(forKey: "defaultDiskGB")
        defaultRosetta = d.bool(forKey: "defaultRosetta")
    }

    /// Terminal apps that are actually installed, for the picker.
    var availableTerminals: [String] {
        let found = AppSettings.knownTerminals.filter { name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "") != nil ? true : true
        }.filter { name in
            FileManager.default.fileExists(atPath: "/Applications/\(name).app")
                || FileManager.default.fileExists(atPath: "/System/Applications/Utilities/\(name).app")
                || FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/Applications/\(name).app")
        }
        return found.contains(terminalApp) ? found : found + [terminalApp]
    }
}
