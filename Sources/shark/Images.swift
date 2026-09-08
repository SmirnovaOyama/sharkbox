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
        guard let remote = URL(string: url) else { throw SharkError("bad image URL: \(url)") }
        Log.info("Downloading \(dest.lastPathComponent)")
        let part = URL(fileURLWithPath: dest.path + ".part")
        try Downloader(url: remote, destination: part, label: dest.lastPathComponent).run()
        try FileManager.default.moveItem(at: part, to: dest)
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


/// Downloads one file with resume support, reporting progress in a form suited to the caller:
/// a redrawing bar on a terminal, and `@@progress` lines that the app parses into a progress view
/// when standard error is a pipe. Replaces shelling out to curl, whose progress meter turns into
/// unreadable `#=#=#` noise as soon as it is not writing to a terminal.
final class Downloader: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let destination: URL
    private let label: String
    private var handle: FileHandle?
    private var writtenNow: UInt64 = 0
    private var resumedFrom: UInt64 = 0
    private var total: UInt64 = 0
    private var failure: Error?
    private var lastReport = Date.distantPast
    private var lastReportedBytes: UInt64 = 0
    private var speed: Double = 0
    private let finished = DispatchSemaphore(value: 0)
    private var session: URLSession!

    init(url: URL, destination: URL, label: String) {
        self.url = url
        self.destination = destination
        self.label = label
    }

    func run() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        resumedFrom = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? UInt64) .flatMap { $0 } ?? 0
        handle = try FileHandle(forWritingTo: destination)
        try handle?.seekToEnd()

        var request = URLRequest(url: url, timeoutInterval: 60)
        if resumedFrom > 0 { request.setValue("bytes=\(resumedFrom)-", forHTTPHeaderField: "Range") }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
        finished.wait()
        try? handle?.close()
        session.finishTasksAndInvalidate()

        if let failure {
            throw SharkError("could not download \(url.lastPathComponent): \(failure.localizedDescription)")
        }
        report(force: true, done: true)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        switch http.statusCode {
        case 206:
            break                                   // server honoured the range: keep appending
        case 200:
            // No resume: start the file over.
            resumedFrom = 0
            try? handle?.truncate(atOffset: 0)
        default:
            failure = SharkError("server replied \(http.statusCode)")
            completionHandler(.cancel)
            finished.signal()
            return
        }
        let length = http.expectedContentLength
        total = length > 0 ? resumedFrom + UInt64(length) : 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            writtenNow += UInt64(data.count)
            report(force: false, done: false)
        } catch {
            failure = error
            dataTask.cancel()
            finished.signal()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil, (error as NSError).code != NSURLErrorCancelled {
            failure = error
        }
        finished.signal()
    }

    // MARK: Progress

    private func report(force: Bool, done: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.25 else { return }
        let elapsed = now.timeIntervalSince(lastReport)
        let current = resumedFrom + writtenNow
        if elapsed > 0, lastReportedBytes > 0 {
            let sample = Double(current - lastReportedBytes) / elapsed
            speed = speed == 0 ? sample : speed * 0.7 + sample * 0.3
        }
        lastReport = now
        lastReportedBytes = current
        let fraction = total > 0 ? min(1, Double(current) / Double(total)) : 0

        if Log.color {
            let width = 28
            let filled = Int(fraction * Double(width))
            let bar = String(repeating: "━", count: filled) + String(repeating: "─", count: width - filled)
            var line = "\r  \(bar) \(Int(fraction * 100))%  \(formatBytes(current))"
            if total > 0 { line += " / \(formatBytes(total))" }
            if speed > 0 && !done { line += String(format: "  %.1f MB/s", speed / 1_048_576) }
            line += done ? "\n" : "   "
            FileHandle.standardError.write(line.data(using: .utf8)!)
        } else {
            // Machine readable, one line per update; the app turns these into a progress bar.
            let line = "@@progress \(String(format: "%.4f", fraction)) \(current) \(total) \(label)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
    }
}
