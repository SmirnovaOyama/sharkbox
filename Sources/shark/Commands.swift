import Foundation
import Virtualization

enum Commands {

    // MARK: - create

    static func create(distroName: String, name: String?, cpus: Int?, memory: UInt64?, disk: UInt64?,
                       rosetta: Bool, start: Bool) throws {
        guard let distro = Distro.find(distroName) else {
            throw SharkError("unknown distro \"\(distroName)\" — run `shark images` to see what's available")
        }
        let name = name ?? distro.family
        guard Machine.validName(name) else {
            throw SharkError("invalid machine name \"\(name)\" (lowercase letters, digits and dashes only)")
        }
        guard !Machine.exists(name) else {
            throw SharkError("machine \"\(name)\" already exists — choose a name: shark create \(distroName) <name>")
        }
        try Paths.ensure()
        let imageDir = try Images.prepare(distro)

        let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
        let hostMem = ProcessInfo.processInfo.physicalMemory
        let defaultMem = min(UInt64(4) << 30, max(UInt64(1) << 30, hostMem / 4))
        let cfg = MachineConfig(
            name: name,
            distro: distro.id,
            boot: distro.boot,
            cpus: cpus ?? min(4, hostCPUs),
            memoryMB: (memory ?? defaultMem) >> 20,
            diskBytes: disk ?? (UInt64(64) << 30),
            mac: VZMACAddress.randomLocallyAdministered().string,
            user: guestUserName(),
            uid: Int(getuid()),
            rosetta: rosetta && VZLinuxRosettaDirectoryShare.availability == .installed,
            created: Date(),
            kernelArgs: nil
        )
        if let free = freeSpace(Paths.root), cfg.diskBytes > free {
            Log.warn("this Mac has \(formatBytes(free)) free but the machine is configured for \(formatBytes(cfg.diskBytes)). " +
                     "The image only grows as it fills up, so this works — but if the Mac runs out of space the guest " +
                     "filesystem can be damaged. Consider --disk \(max(8, Int(free / (1 << 30)) / 2))g.")
        }
        let m = Machine(name: name, config: cfg)
        Log.info("Creating \(Log.bold(name)) — \(distro.title), \(cfg.cpus) CPU, \(formatBytes(cfg.memoryMB << 20)) RAM, \(formatBytes(cfg.diskBytes)) disk")
        try FileManager.default.createDirectory(at: m.dir, withIntermediateDirectories: true)
        do {
            // APFS clone: instant, copy-on-write.
            let rootfs = imageDir.appendingPathComponent("rootfs.img")
            try sh(["cp", "-c", rootfs.path, m.diskImage.path])
            let imageSize = (try? FileManager.default.attributesOfItem(atPath: rootfs.path)[.size] as? UInt64) ?? 0
            try grow(m.diskImage, to: cfg.diskBytes)
            if distro.boot == .kernel {
                try sh(["cp", "-c", imageDir.appendingPathComponent("kernel").path, m.kernel.path])
                try sh(["cp", "-c", imageDir.appendingPathComponent("initrd").path, m.initrd.path])
                if cfg.diskBytes > imageSize {
                    Log.info("Growing the root filesystem to \(formatBytes(cfg.diskBytes)) (offline, in a helper VM)…")
                    do {
                        try PrepVM.growRootFilesystem(kernel: m.kernel, initrd: m.initrd, helperRootfs: rootfs,
                                                      targetDisk: m.diskImage, partition: nil,
                                                      logFile: m.dir.appendingPathComponent("prep.log"))
                    } catch {
                        Log.warn("offline resize failed (\(error)); the guest will resize itself on first boot instead")
                    }
                }
                writeString("created", to: m.cleanFlag)
            }
            let pub = try SSHKeys.publicKey()
            try CloudInit.buildSeed(for: m, publicKey: pub)
            try m.save()
        } catch {
            try? FileManager.default.removeItem(at: m.dir)
            throw error
        }
        if readString(Paths.defaultMachine) == nil { writeString(name, to: Paths.defaultMachine) }
        if rosetta && !cfg.rosetta {
            Log.warn("Rosetta is not installed on this Mac, so x86_64 binaries won't run in the VM. Install it with `softwareupdate --install-rosetta`, then recreate the machine.")
        }
        Log.ok("Created \(name)")
        if start { try startMachine(m, wait: true) }
    }

    static func guestUserName() -> String {
        let mapped = NSUserName().lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "-"
        }
        let u = String(mapped)
        if u.isEmpty || !(u.first!.isLetter) { return "shark" }
        return u
    }

    /// Space actually available to us on the volume holding `url`.
    static func freeSpace(_ url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (values?.volumeAvailableCapacityForImportantUsage).map { UInt64(max(0, $0)) }
    }

    static func grow(_ url: URL, to bytes: UInt64) throws {
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        let cur = try fh.seekToEnd()
        if cur < bytes { try fh.truncate(atOffset: bytes) }
    }

    // MARK: - start / stop / delete

    static func startMachine(_ m: Machine, wait: Bool) throws {
        if m.isRunning {
            Log.info("\(m.name) is already running")
            if wait { try waitReady(m); Log.ok("\(m.name) is up" + (m.ip.map { " at \($0)" } ?? "")) }
            return
        }
        checkAfterUncleanShutdown(m)
        try? FileManager.default.removeItem(at: m.stateFile)
        if !fileExists(m.runnerLog) { FileManager.default.createFile(atPath: m.runnerLog.path, contents: nil) }
        let logHandle = try FileHandle(forWritingTo: m.runnerLog)
        logHandle.seekToEndOfFile()

        let p = Process()
        p.executableURL = Paths.executable
        p.arguments = ["__runner", m.name]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()
        try? logHandle.close()

        Log.info("Starting \(m.name)…")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let st = readString(m.stateFile)
            if st == "running" { break }
            if st == "error" || (st != nil && !m.isRunning) {
                throw SharkError("\(m.name) failed to start:\n" + tail(m.runnerLog, lines: 12))
            }
            if readString(m.pidFile) == nil && Date().timeIntervalSince(deadline) > -27 {
                // the runner exited before it even claimed the machine (e.g. the lock was taken)
                throw SharkError("\(m.name) failed to start:\n" + tail(m.runnerLog, lines: 12))
            }
            usleep(150_000)
        }
        if wait {
            try waitReady(m)
            Log.ok("\(m.name) is up" + (m.ip.map { " at \($0)" } ?? ""))
        }
    }

    /// Block until the guest is reachable over SSH (via vsock); on first boot also wait for cloud-init.
    static func waitReady(_ m: Machine, timeout: TimeInterval = 300) throws {
        let start = Date()
        var announced = false
        while Date().timeIntervalSince(start) < timeout {
            guard m.isRunning else {
                throw SharkError("\(m.name) exited unexpectedly:\n" + tail(m.runnerLog, lines: 12)
                                 + "\n(console output: shark logs \(m.name))")
            }
            if fileExists(m.vsockSocket) {
                let r = try sh(SSHConfig.probeArgs(for: m) + ["true"], check: false, timeout: 15)
                if r.status == 0 {
                    if !fileExists(m.provisionedFlag) {
                        Log.info("First boot: waiting for cloud-init to finish provisioning…")
                        let r2 = try sh(SSHConfig.probeArgs(for: m) + ["sudo", "cloud-init", "status", "--wait"], check: false, timeout: 600)
                        if r2.status != 0 && r2.status != 2 {
                            Log.warn("cloud-init reported status \(r2.status); check `shark logs \(m.name)`")
                        }
                        writeString(ISO8601DateFormatter().string(from: Date()), to: m.provisionedFlag)
                    }
                    SSHConfig.update()
                    return
                }
            }
            if !announced && Date().timeIntervalSince(start) > 2 {
                Log.info("Waiting for \(m.name) to boot…")
                announced = true
            }
            usleep(700_000)
        }
        throw SharkError("timed out after \(Int(timeout))s waiting for \(m.name) — see `shark logs \(m.name)`")
    }

    /// Wait (briefly) for the runner to learn the guest's IP address.
    static func waitIP(_ m: Machine, timeout: TimeInterval = 30) throws -> String {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let ip = m.ip { return ip }
            guard m.isRunning else { throw SharkError("\(m.name) is not running") }
            usleep(300_000)
        }
        throw SharkError("no IP address known for \(m.name) yet — is the guest's network up? (shark logs \(m.name))")
    }

    static func stopMachine(_ m: Machine, force: Bool) throws {
        guard let pid = m.pid else { Log.info("\(m.name) is not running"); return }
        Log.info((force ? "Force stopping" : "Stopping") + " \(m.name)…")
        SSHConfig.closeMux(for: m)
        kill(pid, force ? SIGUSR1 : SIGTERM)
        if waitExit(m, seconds: force ? 20 : 60) { Log.ok("\(m.name) stopped"); return }
        if !force {
            Log.warn("guest did not shut down in time; forcing")
            kill(pid, SIGUSR1)
            if waitExit(m, seconds: 20) { Log.ok("\(m.name) stopped"); return }
        }
        kill(pid, SIGKILL)
        _ = waitExit(m, seconds: 5)
        try? FileManager.default.removeItem(at: m.pidFile)
        m.writeState("stopped")
        Log.ok("\(m.name) killed")
    }

    static func waitExit(_ m: Machine, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !m.isRunning { return true }
            usleep(200_000)
        }
        return !m.isRunning
    }

    static func deleteMachine(_ m: Machine, force: Bool) throws {
        if !force && isatty(0) != 0 {
            guard confirm("Delete machine \"\(m.name)\" and all its data?") else {
                Log.info("aborted"); return
            }
        }
        if m.isRunning { try stopMachine(m, force: true) }
        try FileManager.default.removeItem(at: m.dir)
        if readString(Paths.defaultMachine) == m.name {
            try? FileManager.default.removeItem(at: Paths.defaultMachine)
            if let first = Machine.all().first { writeString(first.name, to: Paths.defaultMachine) }
        }
        SSHConfig.update()
        Log.ok("Deleted \(m.name)")
    }

    // MARK: - shell / run

    /// Map the current Mac directory to the same place inside the guest (Mac home is /mnt/mac).
    static func guestCwd() -> String? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let home = Paths.home.standardizedFileURL.path
        if cwd == home { return "/mnt/mac" }
        if cwd.hasPrefix(home + "/") { return "/mnt/mac" + cwd.dropFirst(home.count) }
        return nil
    }

    static func shell(_ m: Machine, command: [String]) throws -> Never {
        if !m.isRunning { try startMachine(m, wait: false) }
        try waitReady(m)
        var args = SSHConfig.args(for: m)
        let cd = guestCwd().map { "cd \(shellQuote($0)) 2>/dev/null; " } ?? ""
        if command.isEmpty {
            args += ["-t", cd + "exec \"${SHELL:-/bin/bash}\" -l"]
        } else {
            if isTTY() { args.append("-t") }
            // A single argument is handed to the remote shell verbatim (like `ssh host 'cmd | cmd'`);
            // several arguments are quoted individually so they arrive as-is.
            let remote = command.count == 1 ? command[0] : shellJoin(command)
            args.append(cd + remote)
        }
        execReplace(args)
    }

    static func resolveDefault() throws -> Machine {
        if let n = readString(Paths.defaultMachine), Machine.exists(n) { return try Machine.load(n) }
        let all = Machine.all()
        guard let first = all.first else {
            throw SharkError("no machines yet — create one with: shark create ubuntu")
        }
        return first
    }

    // MARK: - list / info / logs / ip

    static func list() {
        let machines = Machine.all()
        if machines.isEmpty {
            print("No machines. Create one with: shark create ubuntu")
            return
        }
        let def = readString(Paths.defaultMachine)
        var rows: [[String]] = [["NAME", "DISTRO", "STATE", "IP", "CPU", "MEM", "DISK"]]
        for m in machines {
            let running = m.isRunning
            let name = m.name + (m.name == def ? " *" : "")
            let state = m.state
            let stateColored = state == "running" ? Log.paint("32", state) : (state == "stopped" ? Log.dim(state) : Log.paint("33", state))
            let ip = running ? (m.ip ?? "…") : "-"
            rows.append([name, m.config.distro, stateColored, ip, "\(m.config.cpus)",
                         formatBytes(m.config.memoryMB << 20),
                         "\(formatBytes(m.config.diskBytes)) (\(formatBytes(diskUsage(m.diskImage))) used)"])
        }
        printTable(rows)
    }

    static func diskUsage(_ url: URL) -> UInt64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return UInt64(st.st_blocks) * 512
    }

    static func visibleLength(_ s: String) -> Int {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }

    static func printTable(_ rows: [[String]]) {
        guard let cols = rows.first?.count else { return }
        var widths = [Int](repeating: 0, count: cols)
        for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], visibleLength(c)) } }
        for r in rows {
            var line = ""
            for (i, c) in r.enumerated() {
                line += c + String(repeating: " ", count: widths[i] - visibleLength(c) + 2)
            }
            print(line.trimmingCharacters(in: .whitespaces))
        }
    }

    static func info(_ m: Machine) {
        let c = m.config
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let rows: [(String, String)] = [
            ("Name", m.name + (m.isDefault ? " (default)" : "")),
            ("Distro", c.distro),
            ("State", m.state),
            ("IP", m.isRunning ? (m.ip ?? "(pending)") : (m.ip.map { "\($0) (last known)" } ?? "-")),
            ("SSH", "ssh \(m.name).shark   (after: shark ssh-config --install)"),
            ("CPUs", "\(c.cpus)"),
            ("Memory", formatBytes(c.memoryMB << 20)),
            ("Disk", "\(formatBytes(c.diskBytes)) configured, \(formatBytes(diskUsage(m.diskImage))) used"),
            ("Boot", c.boot.rawValue),
            ("Rosetta", c.rosetta ? "enabled" : "disabled"),
            ("User", "\(c.user) (uid \(c.uid))"),
            ("Mac home in guest", "/mnt/mac  (and /Users/\(c.user))"),
            ("MAC address", c.mac),
            ("Created", df.string(from: c.created)),
            ("Directory", m.dir.path),
            ("Console log", m.consoleLog.path),
        ]
        let w = rows.map { $0.0.count }.max() ?? 0
        for (k, v) in rows { print(k.padding(toLength: w + 2, withPad: " ", startingAt: 0) + v) }
    }

    static func logs(_ m: Machine, follow: Bool, lines: Int) -> Never {
        guard fileExists(m.consoleLog) else { Log.fail("no console log yet for \(m.name)"); exit(1) }
        var args = ["tail", "-n", "\(lines)"]
        if follow { args.append("-f") }
        args.append(m.consoleLog.path)
        execReplace(args)
    }

    // MARK: - offline maintenance (helper VM)

    /// A kernel-bootable image whose userland has e2fsprogs, used to work on a machine's disk offline.
    /// Kernel-boot machines can use their own kernel; EFI machines borrow the cached Ubuntu image.
    static func helperImages(for m: Machine) throws -> (kernel: URL, initrd: URL, rootfs: URL) {
        if m.config.boot == .kernel, let d = Distro.find(m.config.distro), Images.isPrepared(d) {
            let rootfs = Images.cacheDir(d).appendingPathComponent("rootfs.img")
            if fileExists(m.kernel), fileExists(m.initrd), fileExists(rootfs) {
                return (m.kernel, m.initrd, rootfs)
            }
        }
        guard let ubuntu = Distro.find("ubuntu"), Images.isPrepared(ubuntu) else {
            throw SharkError("this needs the Ubuntu helper image — download it once with: shark pull ubuntu")
        }
        let dir = Images.cacheDir(ubuntu)
        return (dir.appendingPathComponent("kernel"), dir.appendingPathComponent("initrd"),
                dir.appendingPathComponent("rootfs.img"))
    }

    /// Partition holding the root filesystem, or nil when the image has no partition table.
    static func rootPartition(_ m: Machine) -> Int? { m.config.boot == .efi ? 1 : nil }

    /// Check (and by default safely repair) a stopped machine's root filesystem with e2fsck in a helper VM.
    /// `dryRun` maps to `e2fsck -n`, which cannot replay the journal — on a machine that was not shut down
    /// cleanly that always reports leftovers, so it is not the default.
    @discardableResult
    static func fsck(_ m: Machine, repair: Bool, dryRun: Bool = false, quiet: Bool = false) throws -> Int {
        guard !m.isRunning else { throw SharkError("\(m.name) is running — stop it first: shark stop \(m.name)") }
        let lock = try MachineLock.acquire(m)
        defer { _ = lock }
        let helper = try helperImages(for: m)
        let logFile = m.dir.appendingPathComponent("fsck.log")
        let mode: PrepVM.FsckMode = dryRun ? .dryRun : (repair ? .repair : .preen)
        if !quiet {
            Log.info((repair ? "Repairing" : "Checking") + " the root filesystem of \(m.name) (e2fsck in a helper VM)…")
        }
        let rc = try PrepVM.checkFilesystem(kernel: helper.kernel, initrd: helper.initrd, helperRootfs: helper.rootfs,
                                            targetDisk: m.diskImage, partition: rootPartition(m), mode: mode, logFile: logFile)
        if !quiet { printHelperOutput(logFile) }
        switch rc {
        case 0:
            if !quiet { Log.ok("\(m.name): filesystem is clean") }
        case 1, 2:
            Log.ok("\(m.name): filesystem errors were corrected")
        case 4:
            throw SharkError("\(m.name): the filesystem still has errors" +
                             (repair ? " that e2fsck could not fix automatically" : " — run: shark fsck --repair \(m.name)"))
        default:
            throw SharkError("e2fsck failed (exit \(rc)); see \(logFile.path)")
        }
        return rc
    }

    /// Print just the helper script's own output from a helper-VM log (skipping the kernel/initramfs noise).
    static func printHelperOutput(_ logFile: URL) {
        let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let from = lines.lastIndex(where: { $0.contains("init-bottom") }).map { $0 + 1 } ?? max(0, lines.count - 40)
        for line in lines[from...] where !line.contains("SHARKBOX_") && !line.hasPrefix("mount:") && !line.isEmpty {
            print(line)
        }
    }

    /// After an unclean shutdown, replay the journal and fix what e2fsck can fix safely — exactly what a
    /// physical machine does on boot. Without this, ext4 damage compounds across force stops.
    static func checkAfterUncleanShutdown(_ m: Machine) {
        guard fileExists(m.provisionedFlag), !fileExists(m.cleanFlag) else { return }
        Log.warn("\(m.name) was not shut down cleanly last time; checking its filesystem first")
        do {
            _ = try fsck(m, repair: false, quiet: true)
        } catch {
            // Preen mode refuses anything that needs a decision. Make that decision rather than
            // booting a guest whose root filesystem will remount read-only a second later.
            Log.warn("the quick check could not fix everything; running a full repair")
            do {
                _ = try fsck(m, repair: true, quiet: true)
            } catch {
                Log.warn("repair failed: \(error)")
                Log.warn("inspect it yourself with: shark fsck --dry-run \(m.name)")
            }
        }
    }

    // MARK: - reconfigure

    static func set(_ m: Machine, cpus: Int?, memory: UInt64?, disk: UInt64?) throws {
        guard !m.isRunning else { throw SharkError("\(m.name) is running — stop it first: shark stop \(m.name)") }
        var c = m.config
        var changes: [String] = []
        if let cpus {
            guard cpus >= 1, cpus <= ProcessInfo.processInfo.activeProcessorCount else {
                throw SharkError("--cpus must be between 1 and \(ProcessInfo.processInfo.activeProcessorCount)")
            }
            changes.append("CPUs \(c.cpus) → \(cpus)")
            c.cpus = cpus
        }
        if let memory {
            let mb = memory >> 20
            guard mb >= 512 else { throw SharkError("--memory must be at least 512m") }
            changes.append("memory \(formatBytes(c.memoryMB << 20)) → \(formatBytes(mb << 20))")
            c.memoryMB = mb
        }
        if let disk {
            guard disk > c.diskBytes else {
                throw SharkError("a disk can only grow (currently \(formatBytes(c.diskBytes)))")
            }
            let lock = try MachineLock.acquire(m)
            defer { _ = lock }
            let helper = try helperImages(for: m)
            Log.info("Growing the disk of \(m.name) to \(formatBytes(disk)) (offline, in a helper VM)…")
            try grow(m.diskImage, to: disk)
            do {
                try PrepVM.growRootFilesystem(kernel: helper.kernel, initrd: helper.initrd, helperRootfs: helper.rootfs,
                                              targetDisk: m.diskImage, partition: rootPartition(m),
                                              logFile: m.dir.appendingPathComponent("prep.log"))
            } catch {
                // The image file is already bigger; record that so `shark list` does not lie, but say what failed.
                c.diskBytes = disk
                m.config = c
                try? m.save()
                throw SharkError("the disk image was enlarged but the filesystem could not be resized: \(error)")
            }
            changes.append("disk \(formatBytes(c.diskBytes)) → \(formatBytes(disk))")
            c.diskBytes = disk
        }
        guard !changes.isEmpty else {
            throw SharkError("nothing to change — pass --cpus, --memory or --disk")
        }
        m.config = c
        try m.save()
        Log.ok("\(m.name): " + changes.joined(separator: ", "))
    }

    // MARK: - images

    static func images() {
        var rows: [[String]] = [["DISTRO", "ALIASES", "BOOT", "STATUS"]]
        for d in Distro.all {
            rows.append([d.id, d.aliases.filter { $0 != d.id }.joined(separator: ", "), d.boot.rawValue,
                         Images.isPrepared(d) ? Log.paint("32", "downloaded") : Log.dim("not downloaded")])
        }
        printTable(rows)
        print("\nCreate a machine:  shark create <distro> [name]")
    }

    // MARK: - docker

    static func docker(_ m: Machine) throws {
        if !m.isRunning { try startMachine(m, wait: false) }
        try waitReady(m)
        Log.info("Installing Docker Engine inside \(m.name) (this can take a minute)…")
        let script = """
        set -e
        if ! command -v docker >/dev/null 2>&1; then
          curl -fsSL https://get.docker.com | sudo sh
        fi
        sudo usermod -aG docker "$USER"
        sudo systemctl enable --now docker >/dev/null
        docker --version
        """
        let status = try shInteractive(SSHConfig.args(for: m) + ["-t", "bash -c \(shellQuote(script))"], check: false)
        guard status == 0 else { throw SharkError("Docker installation inside \(m.name) failed (exit \(status))") }
        Log.ok("Docker Engine is running inside \(m.name)")

        SSHConfig.update()
        if try SSHConfig.install() {
            Log.ok("Added `\(SSHConfig.includeLine)` to ~/.ssh/config (backup: ~/.ssh/config.sharkbox-backup)")
        }
        let host = "ssh://\(m.name).shark"
        let dockerCLI = try sh(["sh", "-c", "command -v docker"], check: false)
        if dockerCLI.status != 0 {
            Log.warn("No `docker` CLI on this Mac. Install the free CLI with:  brew install docker")
            print("Then point it at this machine:\n  docker context create \(m.name) --docker host=\(host)\n  docker context use \(m.name)")
            return
        }
        let exists = try sh(["docker", "context", "inspect", m.name], check: false).status == 0
        if exists {
            try sh(["docker", "context", "update", m.name, "--docker", "host=\(host)"])
        } else {
            try sh(["docker", "context", "create", m.name, "--description", "Sharkbox machine \(m.name)", "--docker", "host=\(host)"])
        }
        let test = try sh(["docker", "--context", m.name, "version", "--format", "{{.Server.Version}}"], check: false, timeout: 60)
        if test.status == 0 {
            Log.ok("docker context \"\(m.name)\" works (server \(test.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) inside \(m.name))")
        } else {
            Log.warn("docker context \"\(m.name)\" was created but `docker --context \(m.name) version` failed:\n\(test.stderr)")
        }
        let current = (try? sh(["docker", "context", "show"], check: false).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "default"
        print("\nUse it for one command:   docker --context \(m.name) run --rm hello-world")
        print("Make it the default:      docker context use \(m.name)      (currently: \(current))")
    }
}
