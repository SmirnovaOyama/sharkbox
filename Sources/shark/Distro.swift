import Foundation

enum BootMode: String, Codable {
    case kernel   // direct kernel boot (kernel + initrd + raw root filesystem)
    case efi      // UEFI boot of a raw whole-disk image
}

struct RemoteFile {
    let name: String   // file name inside ~/.orbshark/images
    let url: String
}

struct Distro {
    let id: String          // e.g. "ubuntu:24.04"
    let family: String      // e.g. "ubuntu" (used as default machine name)
    let aliases: [String]
    let title: String
    let boot: BootMode
    let files: [RemoteFile]
    /// Turn downloaded files into <cacheDir>/rootfs.img (+ kernel, initrd for kernel boot).
    let prepare: (_ cacheDir: URL) throws -> Void

    var cacheDirName: String { id.replacingOccurrences(of: ":", with: "-") }

    static func find(_ s: String) -> Distro? {
        let q = s.lowercased()
        return all.first { $0.id == q || $0.aliases.contains(q) }
    }

    static let all: [Distro] = [
        ubuntu(version: "24.04", codename: "noble", aliases: ["ubuntu", "noble", "ubuntu:noble"]),
        ubuntu(version: "22.04", codename: "jammy", aliases: ["jammy", "ubuntu:jammy"]),
        debian(version: "13", codename: "trixie", aliases: ["debian", "trixie", "debian:trixie"]),
        debian(version: "12", codename: "bookworm", aliases: ["bookworm", "debian:bookworm"]),
    ]

    // MARK: - Ubuntu (direct kernel boot; Ubuntu only ships qcow2 whole-disk images)

    static func ubuntu(version: String, codename: String, aliases: [String]) -> Distro {
        let base = "https://cloud-images.ubuntu.com/releases/\(codename)/release"
        let stem = "ubuntu-\(version)-server-cloudimg-arm64"
        let tarball = RemoteFile(name: "\(stem).tar.gz", url: "\(base)/\(stem).tar.gz")
        let kernel = RemoteFile(name: "\(stem)-vmlinuz-generic", url: "\(base)/unpacked/\(stem)-vmlinuz-generic")
        let initrd = RemoteFile(name: "\(stem)-initrd-generic", url: "\(base)/unpacked/\(stem)-initrd-generic")
        return Distro(
            id: "ubuntu:\(version)", family: "ubuntu", aliases: aliases,
            title: "Ubuntu \(version) LTS (\(codename))", boot: .kernel,
            files: [tarball, kernel, initrd]
        ) { dir in
            let fm = FileManager.default
            Log.info("Extracting \(tarball.name)")
            try sh(["tar", "-xzf", Paths.images.appendingPathComponent(tarball.name).path, "-C", dir.path])
            let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            guard let img = entries.first(where: { $0.pathExtension == "img" }) else {
                throw SharkError("no .img found inside \(tarball.name)")
            }
            try fm.moveItem(at: img, to: dir.appendingPathComponent("rootfs.img"))
            // Prefer kernel/initrd packed in the tarball (guaranteed to match the rootfs modules).
            let packedKernel = entries.first { $0.lastPathComponent.contains("vmlinuz") }
            let packedInitrd = entries.first { $0.lastPathComponent.contains("initrd") }
            try installKernel(from: packedKernel ?? Paths.images.appendingPathComponent(kernel.name),
                              to: dir.appendingPathComponent("kernel"))
            try fm.copyItem(at: packedInitrd ?? Paths.images.appendingPathComponent(initrd.name),
                            to: dir.appendingPathComponent("initrd"))
            for e in entries where fm.fileExists(atPath: e.path) && e.lastPathComponent != "rootfs.img" {
                try? fm.removeItem(at: e)
            }
        }
    }

    // MARK: - Debian (UEFI boot of the official raw whole-disk image)

    static func debian(version: String, codename: String, aliases: [String]) -> Distro {
        let tarball = RemoteFile(
            name: "debian-\(version)-generic-arm64.tar.xz",
            url: "https://cloud.debian.org/images/cloud/\(codename)/latest/debian-\(version)-generic-arm64.tar.xz")
        return Distro(
            id: "debian:\(version)", family: "debian", aliases: aliases,
            title: "Debian \(version) (\(codename))", boot: .efi,
            files: [tarball]
        ) { dir in
            Log.info("Extracting \(tarball.name)")
            try sh(["tar", "-xJf", Paths.images.appendingPathComponent(tarball.name).path, "-C", dir.path])
            let fm = FileManager.default
            let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            guard let raw = entries.first(where: { $0.pathExtension == "raw" }) else {
                throw SharkError("no disk.raw found inside \(tarball.name)")
            }
            try fm.moveItem(at: raw, to: dir.appendingPathComponent("rootfs.img"))
        }
    }

    /// Virtualization.framework needs an uncompressed arm64 Image; distros usually ship Image.gz.
    static func installKernel(from src: URL, to dst: URL) throws {
        let fh = try FileHandle(forReadingFrom: src)
        let magic = fh.readData(ofLength: 2)
        try fh.close()
        if magic == Data([0x1f, 0x8b]) {
            Log.info("Decompressing kernel")
            let r = try sh(["sh", "-c", "gzip -dc \(shellQuote(src.path)) > \(shellQuote(dst.path))"])
            _ = r
        } else {
            if fileExists(dst) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: src, to: dst)
        }
    }
}
