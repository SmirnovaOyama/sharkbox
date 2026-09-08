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
        var script = "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t tmpfs tmp /tmp; mount -t tmpfs run /run; "
        let dev: String
        if let partition {
            script += "growpart /dev/vdb \(partition); "
            dev = "/dev/vdb\(partition)"
        } else {
            dev = "/dev/vdb"
        }
        // The host watches the console for the marker and then stops the VM itself, so nothing here
        // depends on poweroff working inside a bare init; the trailing sleep keeps PID 1 alive meanwhile.
        script += "e2fsck -f -p \(dev); if resize2fs -f \(dev); then sync; echo SHARKBOX_PREP_OK; else echo SHARKBOX_PREP_FAIL; fi; sleep 600"
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
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: helperRootfs, readOnly: true)),
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: targetDisk, readOnly: false)),
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
        try? logHandle.close()
        if let failure = prep.failure { throw SharkError("helper VM failed: \(failure)") }
        switch outcome {
        case "ok": return
        case "fail": throw SharkError("resize2fs failed inside the helper VM (see \(logFile.path))")
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
