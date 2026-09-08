import Foundation

enum Paths {
    static let home = URL(fileURLWithPath: NSHomeDirectory())
    static let root = home.appendingPathComponent(".sharkbox")
    static let machines = root.appendingPathComponent("machines")
    static let images = root.appendingPathComponent("images")
    static let sshKey = root.appendingPathComponent("id_ed25519")
    static let sshPub = root.appendingPathComponent("id_ed25519.pub")
    static let sshConfig = root.appendingPathComponent("ssh_config")
    static let knownHosts = root.appendingPathComponent("known_hosts")
    static let defaultMachine = root.appendingPathComponent("default")

    static func ensure() throws {
        for d in [root, machines, images] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    static var executable: URL {
        if let u = Bundle.main.executableURL { return u }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }
}
