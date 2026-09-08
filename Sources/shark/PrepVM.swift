import Foundation
import Virtualization

/// A throwaway helper VM that grows a machine's root filesystem *offline* (e2fsck + resize2fs from the
/// distro's own userland) before the machine ever boots. Avoids the guest kernel's online-resize path,
/// which corrupts ext4 on some kernels (Ubuntu 24.04's 6.8 when growing 2G → 64G).
final class PrepVM: NSObject, VZVirtualMachineDelegate {
    let queue = DispatchQueue(label: "com.sharkbox.prep")
    let done = DispatchSemaphore(value: 0)
    var vm: VZVirtualMachine!
    var failure: Error?

    /// - Parameters:
    ///   - kernel/initrd/helperRootfs: a kernel-bootable image whose userland has e2fsprogs (+ growpart for partitions)
    ///   - targetDisk: the (already enlarged) disk image to fix up; it appears as /dev/vdb in the helper
    ///   - partition: nil for a partitionless filesystem, else the partition number holding the root fs
    static func growRootFilesystem(kernel: URL, initrd: URL, helperRootfs: URL, targetDisk: URL,
                                   partition: Int?, logFile: URL, timeout: TimeInterval = 120) throws {
        let dev = partition.map { "/dev/vdb\($0)" } ?? "/dev/vdb"
        var script = ""
        if let partition { script += "growpart /dev/vdb \(partition); " }
        script += "e2fsck -f -p \(dev); if resize2fs -f \(dev); then sync; echo SHARKBOX_PREP_OK; else echo SHARKBOX_PREP_FAIL; fi"
        try run(kernel: kernel, initrd: initrd, helperRootfs: helperRootfs, targetDisk: targetDisk,
                script: script, logFile: logFile, timeout: timeout)
    }

    enum FsckMode {
        case preen    // -p: replay the journal, fix only unambiguous problems (what a real boot does)
        case repair   // -y: answer yes to everything
        case dryRun   // -n: touch nothing — cannot replay the journal, so it over-reports after a crash

        var flags: String {
            switch self {
            case .preen: return "-f -p"
            case .repair: return "-f -y"
            case .dryRun: return "-f -n"
            }
        }
    }

    /// Run e2fsck on a machine's (stopped) root filesystem. Returns e2fsck's exit code
    /// (0 clean, 1 errors fixed, 2 fixed + reboot advised, 4 errors left, 8 operational error).
    static func checkFilesystem(kernel: URL, initrd: URL, helperRootfs: URL, targetDisk: URL,
                                partition: Int?, mode fsckMode: FsckMode, logFile: URL, timeout: TimeInterval = 600) throws -> Int {
        let dev = partition.map { "/dev/vdb\($0)" } ?? "/dev/vdb"
        let mode = fsckMode.flags
        let script = "e2fsck \(mode) \(dev); rc=$?; sync; echo SHARKBOX_FSCK_RC=$rc; echo SHARKBOX_PREP_OK"
        try run(kernel: kernel, initrd: initrd, helperRootfs: helperRootfs, targetDisk: targetDisk,
                script: script, logFile: logFile, timeout: timeout)
        let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        guard let m = log.range(of: #"SHARKBOX_FSCK_RC=(\d+)"#, options: .regularExpression),
              let rc = Int(log[m].split(separator: "=")[1]) else {
            throw SharkError("e2fsck did not report a result (see \(logFile.path))")
        }
        return rc
    }

    /// Boot the helper with `targetDisk` as /dev/vdb and run `script` as PID 1 (via bash). The script must
    /// print SHARKBOX_PREP_OK or SHARKBOX_PREP_FAIL; the host watches the console and stops the VM itself.
    static func run(kernel: URL, initrd: URL, helperRootfs: URL, targetDisk: URL,
                    script body: String, logFile: URL, timeout: TimeInterval) throws {
        let script = "mount -t proc proc /proc; mount -t sysfs sys /sys 2>/dev/null; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run; "
            + body + "; sleep 600"
        let cmdline = "console=hvc0 root=/dev/vda ro rootwait init=/bin/bash -- -c \"\(script)\""

        let cfg = VZVirtualMachineConfiguration()
        cfg.cpuCount = 2
        cfg.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, 1024 << 20)
        cfg.platform = VZGenericPlatformConfiguration()
        let bl = VZLinuxBootLoader(kernelURL: kernel)
        bl.initialRamdiskURL = initrd
        bl.commandLine = cmdline
        cfg.bootLoader = bl
        cfg.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try DiskAttachment.readOnly(helperRootfs)),
            VZVirtioBlockDeviceConfiguration(attachment: try DiskAttachment.readWrite(targetDisk)),
        ]
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logFile)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: FileHandle(forReadingAtPath: "/dev/null"),
                                                             fileHandleForWriting: logHandle)
        cfg.serialPorts = [serial]
        cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try cfg.validate()

        let prep = PrepVM()
        prep.vm = VZVirtualMachine(configuration: cfg, queue: prep.queue)
        prep.vm.delegate = prep
        prep.queue.async {
            prep.vm.start { result in
                if case .failure(let e) = result { prep.failure = e; prep.done.signal() }
            }
        }
        // Poll the console log for the outcome marker.
        let deadline = Date().addingTimeInterval(timeout)
        var outcome: String?
        while Date() < deadline {
            if prep.done.wait(timeout: .now() + 0.3) == .success { break }   // VM stopped/failed early
            let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            if log.contains("SHARKBOX_PREP_OK") { outcome = "ok"; break }
            if log.contains("SHARKBOX_PREP_FAIL") { outcome = "fail"; break }
            if log.contains("Kernel panic") { outcome = "panic"; break }
        }
        // Stop the helper (it never powers itself off).
        let stopped = DispatchSemaphore(value: 0)
        prep.queue.async {
            if prep.vm.canStop { prep.vm.stop { _ in stopped.signal() } } else { stopped.signal() }
        }
        _ = stopped.wait(timeout: .now() + 15)
        // The next process to open this image must see everything the helper wrote.
        DiskAttachment.flush(targetDisk)
        try? logHandle.close()
        if let failure = prep.failure { throw SharkError("helper VM failed: \(failure)") }
        switch outcome {
        case "ok": return
        case "fail": throw SharkError("the helper script reported failure (see \(logFile.path))")
        case "panic": throw SharkError("helper VM kernel panicked (see \(logFile.path))")
        default: throw SharkError("helper VM did not finish within \(Int(timeout))s (see \(logFile.path))")
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { done.signal() }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        failure = error
        done.signal()
    }
}
