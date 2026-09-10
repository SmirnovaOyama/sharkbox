import Foundation

enum Images {
    static func cacheDir(_ d: Distro) -> URL { Paths.images.appendingPathComponent(d.cacheDirName) }

    /// Make sure the prepared image for `d` exists; returns its directory.
    static func prepare(_ d: Distro) throws -> URL {
        let dir = cacheDir(d)
        let ready = dir.appendingPathComponent(".ready")
        if fileExists(ready) { return dir }
        let fm = FileManager.default
        // A cache directory without `.ready` is debris from an interrupted attempt, and the
        // per-distro closures unpack as if into an empty directory — their `moveItem` onto an
        // existing rootfs.img fails. Left in place it wedges this distro for good, and every
        // retry strands another multi-GB copy. Start clean; the downloads live elsewhere and
        // are kept, so a retry does not re-fetch them.
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in d.files {
            try download(f.url, to: Paths.images.appendingPathComponent(f.name))
        }
        do {
            try d.prepare(dir)
            guard fileExists(dir.appendingPathComponent("rootfs.img")) else {
                throw SharkError("image preparation for \(d.id) produced no rootfs.img")
            }
        } catch {
            try? fm.removeItem(at: dir)   // leave nothing a retry would trip over
            throw error
        }
        writeString(ISO8601DateFormatter().string(from: Date()), to: ready)
        Log.ok("Image \(d.id) ready")
        return dir
    }

    static func download(_ url: String, to dest: URL) throws {
        if fileExists(dest) { return }
        Log.info("Downloading \(url)")
        let part = dest.path + ".part"
        let status = try shInteractive(["curl", "-L", "--fail", "--progress-bar", "-C", "-", "-o", part, url], check: false)
        guard status == 0 else { throw SharkError("download failed (curl exit \(status)): \(url)") }
        try FileManager.default.moveItem(atPath: part, toPath: dest.path)
    }

    /// Delete a prepared image and the downloads it came from.
    static func remove(_ d: Distro) throws {
        let dir = cacheDir(d)
        var freed: UInt64 = 0
        for url in [dir] + d.files.map({ Paths.images.appendingPathComponent($0.name) }) {
            guard fileExists(url) else { continue }
            freed += directorySize(url)
            try FileManager.default.removeItem(at: url)
        }
        Log.ok("Removed \(d.id) (\(formatBytes(freed)) freed)")
    }

    static func directorySize(_ url: URL) -> UInt64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        if st.st_mode & S_IFMT != S_IFDIR { return UInt64(st.st_blocks) * 512 }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return children.reduce(0) { $0 + directorySize($1) }
    }

    /// Bytes on disk for every prepared image plus its downloads.
    static func size(_ d: Distro) -> UInt64 {
        var total = directorySize(cacheDir(d))
        for f in d.files { total += directorySize(Paths.images.appendingPathComponent(f.name)) }
        return total
    }

    static func isPrepared(_ d: Distro) -> Bool {
        fileExists(cacheDir(d).appendingPathComponent(".ready"))
    }
}
