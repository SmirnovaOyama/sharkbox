import Foundation

enum Images {
    static func cacheDir(_ d: Distro) -> URL { Paths.images.appendingPathComponent(d.cacheDirName) }

    /// Make sure the prepared image for `d` exists; returns its directory.
    static func prepare(_ d: Distro) throws -> URL {
        let dir = cacheDir(d)
        let ready = dir.appendingPathComponent(".ready")
        if fileExists(ready) { return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in d.files {
            try download(f.url, to: Paths.images.appendingPathComponent(f.name))
        }
        try d.prepare(dir)
        guard fileExists(dir.appendingPathComponent("rootfs.img")) else {
            throw SharkError("image preparation for \(d.id) produced no rootfs.img")
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

    static func isPrepared(_ d: Distro) -> Bool {
        fileExists(cacheDir(d).appendingPathComponent(".ready"))
    }
}
