import Foundation
import Virtualization

/// The long-lived background process that owns one virtual machine.
/// Spawned by `shark start` as `shark __runner <name>`.
final class VMRunner: NSObject, VZVirtualMachineDelegate {
    let machine: Machine
    let queue = DispatchQueue(label: "com.orbshark.vm")
    var vm: VZVirtualMachine!
    var stopRequested = false
    var signalSources: [DispatchSourceSignal] = []
    var ipTimer: DispatchSourceTimer?
    var consoleHandle: FileHandle?
    var proxy: VsockProxy?

    init(machine: Machine) {
        self.machine = machine
        super.init()
    }

    func log(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
    }

    func run() -> Never {
        // Detach from the terminal session that started us.
        setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        writeString("\(getpid())", to: machine.pidFile)
        machine.writeState("starting")
        try? FileManager.default.removeItem(at: machine.ipFile)

        do {
            let config = try buildConfiguration()
            vm = VZVirtualMachine(configuration: config, queue: queue)
            vm.delegate = self
        } catch {
            log("configuration error: \(error)")
            machine.writeState("error")
            cleanupAndExit(1)
        }

        installSignalHandlers()
        queue.async {
            self.log("starting VM (\(self.machine.config.cpus) cpu, \(self.machine.config.memoryMB) MB, boot=\(self.machine.config.boot.rawValue))")
            self.vm.start { result in
                switch result {
                case .success:
                    self.log("VM running")
                    self.startProxy()
                    self.machine.writeState("running")
                    self.startIPWatcher()
                case .failure(let error):
                    self.log("VM failed to start: \(error)")
                    self.machine.writeState("error")
                    self.cleanupAndExit(1)
                }
            }
        }
        dispatchMain()
    }

    // MARK: Configuration

    func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        let c = machine.config
        let cfg = VZVirtualMachineConfiguration()

        cfg.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                           min(c.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        cfg.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                             min(c.memoryMB * 1024 * 1024, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        // Platform with a stable machine identifier.
        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: machine.machineIDFile),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = id
        } else {
            try platform.machineIdentifier.dataRepresentation.write(to: machine.machineIDFile)
        }
        cfg.platform = platform

        // Boot loader
        switch c.boot {
        case .kernel:
            let bl = VZLinuxBootLoader(kernelURL: machine.kernel)
            bl.initialRamdiskURL = machine.initrd
            bl.commandLine = c.kernelArgs ?? "console=hvc0 root=/dev/vda rw"
            cfg.bootLoader = bl
        case .efi:
            let bl = VZEFIBootLoader()
            if fileExists(machine.efiVars) {
                bl.variableStore = VZEFIVariableStore(url: machine.efiVars)
            } else {
                bl.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: machine.efiVars)
            }
            cfg.bootLoader = bl
        }

        // Storage: root disk + cloud-init seed
        let disk = try VZDiskImageStorageDeviceAttachment(url: machine.diskImage, readOnly: false)
        let seed = try VZDiskImageStorageDeviceAttachment(url: machine.seedISO, readOnly: true)
        cfg.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: disk),
            VZVirtioBlockDeviceConfiguration(attachment: seed),
        ]

        // Network: NAT via vmnet (guest gets a 192.168.64.x address reachable from the host)
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        guard let mac = VZMACAddress(string: c.mac) else { throw SharkError("bad MAC address \(c.mac)") }
        net.macAddress = mac
        cfg.networkDevices = [net]

        // Serial console → console.log
        let nullIn = FileHandle(forReadingAtPath: "/dev/null")
        if !fileExists(machine.consoleLog) { FileManager.default.createFile(atPath: machine.consoleLog.path, contents: nil) }
        let logOut = try FileHandle(forWritingTo: machine.consoleLog)
        logOut.seekToEndOfFile()
        consoleHandle = logOut
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nullIn, fileHandleForWriting: logOut)
        cfg.serialPorts = [serial]

        // Misc devices
        cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        cfg.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        cfg.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Shared directories: Mac home → tag "mac"; Rosetta → tag "rosetta"
        var shares: [VZDirectorySharingDeviceConfiguration] = []
        let macShare = VZVirtioFileSystemDeviceConfiguration(tag: "mac")
        macShare.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: Paths.home, readOnly: false))
        shares.append(macShare)
        if c.rosetta {
            if VZLinuxRosettaDirectoryShare.availability == .installed {
                let r = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                r.share = try VZLinuxRosettaDirectoryShare()
                shares.append(r)
            } else {
                log("Rosetta requested but not installed on this Mac (softwareupdate --install-rosetta); skipping")
            }
        }
        cfg.directorySharingDevices = shares

        try cfg.validate()
        return cfg
    }

    // MARK: Signals / shutdown

    func installSignalHandlers() {
        for (sig, force) in [(SIGTERM, false), (SIGINT, false), (SIGUSR1, true)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { [unowned self] in self.requestShutdown(force: force) }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Runs on `queue`.
    func requestShutdown(force: Bool) {
        if vm.state == .stopped { cleanupAndExit(0) }
        if force || stopRequested || !vm.canRequestStop {
            forceStop()
            return
        }
        stopRequested = true
        machine.writeState("stopping")
        do {
            try vm.requestStop()
            log("asked the guest to shut down")
        } catch {
            log("requestStop failed (\(error)); forcing")
            forceStop()
            return
        }
        queue.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.vm.state != .stopped else { return }
            self.log("guest did not stop within 45s; forcing")
            self.forceStop()
        }
    }

    func forceStop() {
        guard vm.canStop else { cleanupAndExit(0) }
        log("force stopping VM")
        machine.writeState("stopping")
        vm.stop { [unowned self] error in
            if let error { self.log("stop error: \(error)") }
            self.cleanupAndExit(0)
        }
    }

    func cleanupAndExit(_ code: Int32) -> Never {
        machine.writeState("stopped")
        try? FileManager.default.removeItem(at: machine.pidFile)
        try? consoleHandle?.close()
        log("runner exiting (\(code))")
        exit(code)
    }

    // MARK: VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log("guest powered off")
        cleanupAndExit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        log("VM stopped with error: \(error)")
        cleanupAndExit(1)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        log("network disconnected: \(error)")
    }

    // MARK: vsock proxy + IP discovery

    func startProxy() {
        let p = VsockProxy(vm: vm, queue: queue, path: machine.vsockSocket.path, log: { [weak self] in self?.log($0) })
        do {
            try p.start()
            proxy = p
        } catch {
            log("vsock proxy failed to start: \(error)")
        }
    }

    func startIPWatcher() {
        // Poll off the VM queue: the vsock query blocks while waiting for the guest.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.orbshark.ipwatch"))
        t.schedule(deadline: .now() + 1, repeating: 2)
        var stableRounds = 0
        var clockSynced = false
        var lastClockPush = Date.distantPast
        t.setEventHandler { [unowned self] in
            // Keep the guest clock right: VZ guests have no reliable RTC, and a wrong clock breaks TLS/apt.
            if !clockSynced || Date().timeIntervalSince(lastClockPush) > 30 {
                if self.proxy?.pushClock() == true {
                    if !clockSynced { self.log("guest clock synced") }
                    clockSynced = true
                    lastClockPush = Date()
                }
            }
            var ip: String?
            if let info = self.proxy?.guestInfo(), let v = info["ip"] as? String, !v.isEmpty { ip = v }
            if ip == nil {
                ip = IPDiscovery.find(mac: self.machine.config.mac, name: self.machine.name, consoleLog: self.machine.consoleLog)
            }
            guard let ip else { return }
            if self.machine.ip != ip {
                self.log("guest IP: \(ip)")
                writeString(ip, to: self.machine.ipFile)
                stableRounds = 0
            } else {
                stableRounds += 1
                if stableRounds == 5 && clockSynced { t.schedule(deadline: .now() + 15, repeating: 15) }   // settle down
            }
        }
        t.resume()
        ipTimer = t
    }
}

enum IPDiscovery {
    /// Normalise "5E:0A:..." / "5e:a:..." to lowercase without leading zeros, for comparing with dhcpd_leases.
    static func normalize(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { part -> String in
            let s = part.drop { $0 == "0" }
            return s.isEmpty ? "0" : String(s)
        }.joined(separator: ":")
    }

    static func find(mac: String, name: String, consoleLog: URL) -> String? {
        fromLeases(mac: mac, name: name) ?? fromConsole(consoleLog)
    }

    /// macOS's vmnet DHCP server records leases in /var/db/dhcpd_leases.
    static func fromLeases(mac: String, name: String) -> String? {
        guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        let want = normalize(mac)
        var byMac: String?, byName: String?
        for block in text.components(separatedBy: "}") {
            var ip: String?, hw: String?, leaseName: String?
            for line in block.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ip_address=") { ip = String(t.dropFirst("ip_address=".count)) }
                if t.hasPrefix("name=") { leaseName = String(t.dropFirst("name=".count)) }
                if t.hasPrefix("hw_address=") {
                    // "1,aa:bb:..." (type,MAC) — or a DUID when the client identifies itself differently.
                    let v = String(t.dropFirst("hw_address=".count))
                    hw = normalize(v.split(separator: ",").last.map(String.init) ?? v)
                }
            }
            guard let ip else { continue }
            if hw == want { byMac = ip }              // last match wins (newest lease)
            if leaseName == name { byName = ip }
        }
        return byMac ?? byName
    }

    /// Fallback: cloud-init prints the address table on the console.
    static func fromConsole(_ url: URL) -> String? {
        let text = tail(url, lines: 400)
        let re = try! NSRegularExpression(pattern: #"ci-info: \|\s*\S+\s*\|\s*True\s*\|\s*(\d+\.\d+\.\d+\.\d+)\s*\|"#)
        let ns = text as NSString
        var last: String?
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let ip = ns.substring(with: m.range(at: 1))
            if !ip.hasPrefix("127.") { last = ip }
        }
        return last
    }
}
