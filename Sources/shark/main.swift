import Foundation

let version = "1.0.0"

let usageText = """
Sharkbox \(version) — free Linux machines on macOS, built on Apple Virtualization.framework

USAGE
  shark                          shell into the default machine
  shark <name> [cmd...]          shell into / run a command in <name>
  shark -m <name> [cmd...]       same thing, flag form

MACHINES
  shark create <distro> [name]   create (and start) a machine    e.g. shark create ubuntu
        --cpus N  --memory 4g  --disk 64g  --no-rosetta  --no-start
  shark list                     list machines (alias: ls)
  shark start|stop|restart <name>
  shark stop -f <name>           force stop
  shark delete [-f] <name>       delete a machine and its disk
  shark info <name>              show configuration, paths, IP
  shark ip <name>                print the machine's IP
  shark logs [-f] <name>         show the serial console log
  shark fsck [--repair] <name>   check a stopped machine's root filesystem (replays the journal;
                                 --repair fixes everything, --dry-run only reports)
  shark set <name> [--cpus N] [--memory 4g] [--disk 128g]
                                 change a stopped machine's resources (a disk can only grow)
  shark default [name]           show / set the default machine

USING MACHINES
  shark shell <name>             interactive login shell (alias: ssh)
  shark run <name> <cmd...>      run a command (stdin/stdout are piped)
  shark docker <name>            install Docker inside <name> and point the Mac `docker` CLI at it
  shark ssh-config [--install]   write ~/.sharkbox/ssh_config so `ssh <name>.shark` works

IMAGES
  shark images                   list available distros
  shark pull <distro>            download an image ahead of time
  shark image rm <distro>        delete a cached image (machines already created keep working)

Inside a machine your Mac home directory is mounted at /mnt/mac (and /Users/<you>).
`shark` run from a folder under your home drops you into the same folder in Linux.
Data lives in ~/.sharkbox.
"""

struct Parsed {
    var positional: [String] = []
    var flags: [String: String] = [:]
    func has(_ k: String) -> Bool { flags[k] != nil }
    func value(_ k: String) -> String? { flags[k] }
}

func parseArgs(_ args: [String], valueFlags: Set<String> = [], boolFlags: Set<String> = [],
               shortMap: [String: String] = [:], stopAtFirstPositional: Bool = false) throws -> Parsed {
    var out = Parsed()
    var i = 0
    while i < args.count {
        var a = args[i]
        if a == "--" { out.positional += args[(i + 1)...]; break }
        if a.hasPrefix("-") && a.count > 1 {
            var inlineValue: String?
            if a.hasPrefix("--") {
                a = String(a.dropFirst(2))
                if let eq = a.firstIndex(of: "=") { inlineValue = String(a[a.index(after: eq)...]); a = String(a[..<eq]) }
            } else {
                a = shortMap[String(a.dropFirst())] ?? String(a.dropFirst())
            }
            if boolFlags.contains(a) {
                out.flags[a] = "true"
            } else if valueFlags.contains(a) {
                if let v = inlineValue { out.flags[a] = v }
                else { i += 1; guard i < args.count else { throw SharkError("--\(a) needs a value") }; out.flags[a] = args[i] }
            } else {
                throw SharkError("unknown option --\(a)")
            }
        } else {
            out.positional.append(a)
            if stopAtFirstPositional { out.positional += args[(i + 1)...]; break }
        }
        i += 1
    }
    return out
}

func requireName(_ p: Parsed, _ hint: String) throws -> Machine {
    guard let n = p.positional.first else { throw SharkError("usage: shark \(hint)") }
    return try Machine.load(n)
}

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    try Paths.ensure()

    guard let cmd = args.first else {
        try Commands.shell(try Commands.resolveDefault(), command: [])
    }
    args.removeFirst()

    switch cmd {
    case "__runner":
        guard let n = args.first else { throw SharkError("__runner needs a machine name") }
        VMRunner(machine: try Machine.load(n)).run()

    case "__proxy":
        guard let n = args.first else { throw SharkError("__proxy needs a machine name") }
        let port = UInt32(args.count > 1 ? args[1] : "2222") ?? 2222
        VsockClient.proxy(machine: try Machine.load(n), port: port)

    case "-m", "--machine":
        guard let n = args.first else { throw SharkError("usage: shark -m <name> [cmd...]") }
        try Commands.shell(try Machine.load(n), command: Array(args.dropFirst()))

    case "create", "new":
        let p = try parseArgs(args, valueFlags: ["cpus", "memory", "disk"],
                              boolFlags: ["no-rosetta", "rosetta", "no-start"],
                              shortMap: ["c": "cpus", "d": "disk"])
        guard let distro = p.positional.first else {
            throw SharkError("usage: shark create <distro> [name] [--cpus N] [--memory 4g] [--disk 64g]\n" +
                             "distros: " + Distro.all.map { $0.id }.joined(separator: ", "))
        }
        try Commands.create(
            distroName: distro,
            name: p.positional.count > 1 ? p.positional[1] : nil,
            cpus: try p.value("cpus").map { guard let n = Int($0), n > 0 else { throw SharkError("bad --cpus") }; return n },
            memory: try p.value("memory").map { try parseSize($0, defaultUnit: "m") },
            disk: try p.value("disk").map { try parseSize($0, defaultUnit: "g") },
            rosetta: !p.has("no-rosetta"),
            start: !p.has("no-start"))

    case "start", "up":
        let p = try parseArgs(args, boolFlags: ["no-wait"])
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        try Commands.startMachine(m, wait: !p.has("no-wait"))

    case "stop", "down":
        let p = try parseArgs(args, boolFlags: ["force", "all"], shortMap: ["f": "force", "a": "all"])
        if p.has("all") {
            for m in Machine.all() where m.isRunning { try Commands.stopMachine(m, force: p.has("force")) }
        } else {
            let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
            try Commands.stopMachine(m, force: p.has("force"))
        }

    case "restart":
        let p = try parseArgs(args)
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        try Commands.stopMachine(m, force: false)
        try Commands.startMachine(m, wait: true)

    case "delete", "rm", "destroy":
        let p = try parseArgs(args, boolFlags: ["force"], shortMap: ["f": "force"])
        guard !p.positional.isEmpty else { throw SharkError("usage: shark delete [-f] <name>") }
        for n in p.positional { try Commands.deleteMachine(try Machine.load(n), force: p.has("force")) }

    case "list", "ls", "ps":
        Commands.list()

    case "shell", "sh", "ssh":
        let p = try parseArgs(args, stopAtFirstPositional: true)
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        try Commands.shell(m, command: Array(p.positional.dropFirst()))

    case "run", "exec":
        let p = try parseArgs(args, stopAtFirstPositional: true)
        let m = try requireName(p, "run <name> <cmd...>")
        let command = Array(p.positional.dropFirst())
        guard !command.isEmpty else { throw SharkError("usage: shark run <name> <cmd...>") }
        try Commands.shell(m, command: command)

    case "ip":
        let p = try parseArgs(args)
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        guard m.isRunning else { throw SharkError("\(m.name) is not running") }
        print(try Commands.waitIP(m))

    case "logs", "log":
        let p = try parseArgs(args, valueFlags: ["lines"], boolFlags: ["follow"], shortMap: ["f": "follow", "n": "lines"])
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        Commands.logs(m, follow: p.has("follow"), lines: Int(p.value("lines") ?? "") ?? 80)

    case "info", "inspect", "show":
        let p = try parseArgs(args)
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        Commands.info(m)

    case "default":
        if let n = args.first {
            guard Machine.exists(n) else { throw SharkError("no machine named \"\(n)\"") }
            writeString(n, to: Paths.defaultMachine)
            Log.ok("default machine is now \(n)")
        } else {
            print(try Commands.resolveDefault().name)
        }

    case "fsck", "repair":
        let p = try parseArgs(args, boolFlags: ["repair", "yes", "dry-run"], shortMap: ["y": "repair", "n": "dry-run"])
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        try Commands.fsck(m, repair: p.has("repair") || p.has("yes") || cmd == "repair", dryRun: p.has("dry-run"))

    case "set", "config":
        let p = try parseArgs(args, valueFlags: ["cpus", "memory", "disk"], shortMap: ["c": "cpus", "d": "disk"])
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        try Commands.set(m,
            cpus: try p.value("cpus").map { guard let n = Int($0), n > 0 else { throw SharkError("bad --cpus") }; return n },
            memory: try p.value("memory").map { try parseSize($0, defaultUnit: "m") },
            disk: try p.value("disk").map { try parseSize($0, defaultUnit: "g") })

    case "image", "img":
        let p = try parseArgs(args)
        switch p.positional.first {
        case "rm", "remove", "delete":
            guard p.positional.count > 1 else { throw SharkError("usage: shark image rm <distro>") }
            for name in p.positional.dropFirst() {
                guard let d = Distro.find(name) else { throw SharkError("unknown distro \"\(name)\"") }
                try Images.remove(d)
            }
        case "ls", "list", nil:
            Commands.images()
        default:
            throw SharkError("usage: shark image ls | shark image rm <distro>")
        }

    case "images", "distros":
        Commands.images()

    case "pull":
        guard let d = args.first.flatMap({ Distro.find($0) }) else {
            throw SharkError("usage: shark pull <distro>   (see `shark images`)")
        }
        _ = try Images.prepare(d)

    case "docker":
        let p = try parseArgs(args)
        let m = try p.positional.first.map { try Machine.load($0) } ?? Commands.resolveDefault()
        try Commands.docker(m)

    case "ssh-config":
        let p = try parseArgs(args, boolFlags: ["install"])
        SSHConfig.update()
        if p.has("install") {
            if try SSHConfig.install() { Log.ok("added `\(SSHConfig.includeLine)` to ~/.ssh/config") }
            else { Log.info("~/.ssh/config already includes \(Paths.sshConfig.path)") }
        }
        print(readString(Paths.sshConfig) ?? "")

    case "help", "-h", "--help":
        print(usageText)

    case "version", "-v", "--version":
        print("Sharkbox \(version)")

    default:
        if Machine.exists(cmd) {
            try Commands.shell(try Machine.load(cmd), command: args)
        }
        throw SharkError("unknown command \"\(cmd)\" (and no machine with that name). Try `shark help`.")
    }
}

do {
    try main()
} catch {
    Log.fail("\(error)")
    exit(1)
}
