import Foundation
import Virtualization

struct MachineConfig: Codable {
    var name: String
    var distro: String
    var boot: BootMode
    var cpus: Int
    var memoryMB: UInt64
    var diskBytes: UInt64
    var mac: String
    var user: String
    var uid: Int
    var rosetta: Bool
    var created: Date
    var kernelArgs: String?
}

final class Machine {
    let name: String
    let dir: URL
    var config: MachineConfig

    init(name: String, config: MachineConfig) {
        self.name = name
        self.dir = Paths.machines.appendingPathComponent(name)
        self.config = config
    }

    // Files
    var configFile: URL { dir.appendingPathComponent("config.json") }
    var diskImage: URL { dir.appendingPathComponent("disk.img") }
    var seedISO: URL { dir.appendingPathComponent("seed.iso") }
    var kernel: URL { dir.appendingPathComponent("kernel") }
    var initrd: URL { dir.appendingPathComponent("initrd") }
    var efiVars: URL { dir.appendingPathComponent("efivars") }
    var machineIDFile: URL { dir.appendingPathComponent("machine-id.bin") }
    var pidFile: URL { dir.appendingPathComponent("runner.pid") }
    var stateFile: URL { dir.appendingPathComponent("state") }
    var ipFile: URL { dir.appendingPathComponent("ip") }
    var consoleLog: URL { dir.appendingPathComponent("console.log") }
    var runnerLog: URL { dir.appendingPathComponent("runner.log") }
    var provisionedFlag: URL { dir.appendingPathComponent(".provisioned") }
    var vsockSocket: URL { dir.appendingPathComponent("vsock.sock") }
    var lockFile: URL { dir.appendingPathComponent("lock") }
    /// Present when the guest powered itself off; absent after a force stop or a crash.
    var cleanFlag: URL { dir.appendingPathComponent(".clean-shutdown") }

    static func validName(_ n: String) -> Bool {
        let ok = n.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil
        return ok && !n.hasPrefix("__")
    }

    static func exists(_ name: String) -> Bool {
        fileExists(Paths.machines.appendingPathComponent(name).appendingPathComponent("config.json"))
    }

    static func load(_ name: String) throws -> Machine {
        let file = Paths.machines.appendingPathComponent(name).appendingPathComponent("config.json")
        guard fileExists(file) else {
            throw SharkError("no machine named \"\(name)\" (see `shark list`)")
        }
        let data = try Data(contentsOf: file)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return Machine(name: name, config: try dec.decode(MachineConfig.self, from: data))
    }

    static func all() -> [Machine] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.machines.path)) ?? []
        return names.sorted().compactMap { try? load($0) }
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try enc.encode(config).write(to: configFile)
    }

    // Runtime state

    var pid: pid_t? {
        guard let s = readString(pidFile), let p = Int32(s), p > 0 else { return nil }
        guard kill(p, 0) == 0, Machine.isRunnerProcess(p) else { return nil }
        return p
    }

    /// A recorded pid is only a *number*. A runner that dies without running its cleanup — `kill -9`,
    /// a crash, a host reboot — leaves runner.pid behind, and after a reboot low pids are handed out
    /// again almost immediately. `stopMachine` escalates SIGTERM → SIGUSR1 → SIGKILL, so trusting a
    /// bare `kill(p, 0)` means shark can kill an unrelated process of the user's. Confirm the pid
    /// really is a shark binary first.
    static func isRunnerProcess(_ p: pid_t) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(p, &buf, UInt32(buf.count)) > 0 else { return false }
        return String(cString: buf).hasSuffix("/shark")
    }

    var isRunning: Bool { pid != nil }

    var state: String {
        guard pid != nil else { return "stopped" }
        return readString(stateFile) ?? "running"
    }

    /// IP address from the runner (only meaningful while running; kept as "last known" otherwise).
    var ip: String? { readString(ipFile).flatMap { $0.isEmpty ? nil : $0 } }

    func writeState(_ s: String) { writeString(s, to: stateFile) }

    var isDefault: Bool { readString(Paths.defaultMachine) == name }
}

enum DiskAttachment {
    /// Every process that opens a machine's disk image must use the SAME caching policy. The default
    /// (`.automatic`) let the runner and the helper VMs disagree: the helper wrote through one path
    /// while the next runner read through another, so a boot right after an offline resize or fsck
    /// could read pre-write blocks and ext4 would reject them ("checksum invalid"). Uncached reads and
    /// writes plus full synchronization give one coherent view of the file across processes.
    static func readWrite(_ url: URL) throws -> VZDiskImageStorageDeviceAttachment {
        try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false,
                                               cachingMode: .uncached, synchronizationMode: .full)
    }

    static func readOnly(_ url: URL) throws -> VZDiskImageStorageDeviceAttachment {
        try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true,
                                               cachingMode: .uncached, synchronizationMode: .full)
    }

    /// Push everything this process wrote to the file all the way to the medium. APFS needs
    /// F_FULLFSYNC for that; a plain fsync() only reaches the drive's write cache.
    static func flush(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
    }
}

/// Exclusive per-machine lock. Guarantees that only one process ever has a machine's disk image
/// open for writing — two VMs on one raw ext4 image destroy the filesystem within seconds.
/// The lock is released when the instance is deallocated or the holding process exits.
final class MachineLock {
    private let fd: Int32
    let machine: String

    init?(_ m: Machine) {
        machine = m.name
        try? FileManager.default.createDirectory(at: m.dir, withIntermediateDirectories: true)
        fd = open(m.lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
    }

    deinit { close(fd) }   // closing the descriptor releases the flock

    /// Take the lock or explain who holds it.
    static func acquire(_ m: Machine) throws -> MachineLock {
        if let lock = MachineLock(m) { return lock }
        if let pid = m.pid {
            throw SharkError("\(m.name) is in use by another Sharkbox process (pid \(pid)) — stop it first: shark stop \(m.name)")
        }
        throw SharkError("\(m.name) is locked by another Sharkbox process")
    }
}
