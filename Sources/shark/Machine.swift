import Foundation

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
        return kill(p, 0) == 0 ? p : nil
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
