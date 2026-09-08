import Foundation

struct SharkError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum Log {
    static let color = isatty(2) != 0
    static func write(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
    static func paint(_ code: String, _ s: String) -> String {
        color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
    static func info(_ s: String) { write(paint("36", "»") + " " + s) }
    static func ok(_ s: String)   { write(paint("32", "✓") + " " + s) }
    static func warn(_ s: String) { write(paint("33", "!") + " " + s) }
    static func fail(_ s: String) { write(paint("31", "✗") + " " + s) }
    static func dim(_ s: String) -> String { paint("2", s) }
    static func bold(_ s: String) -> String { paint("1", s) }
}

func print(_ s: String, terminator: String = "\n") {
    FileHandle.standardOutput.write((s + terminator).data(using: .utf8)!)
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Run a command, capturing its output.
///
/// Output is drained with `poll` rather than `readDataToEndOfFile`, because a grandchild that
/// inherits the pipe keeps it open after the child exits: an `ssh` ProxyCommand outlives its `ssh`,
/// and waiting for end-of-file on its stderr hangs forever. Reading stops once the child has exited
/// and the pipes have been quiet for a moment, or when `timeout` expires.
@discardableResult
func sh(_ args: [String], input: String? = nil, cwd: URL? = nil, check: Bool = true, timeout: TimeInterval? = nil) throws -> CommandResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe

    try p.run()
    if let input {
        inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
    }
    // Drop our copies of the write ends, or the pipes can never report end-of-file.
    try? outPipe.fileHandleForWriting.close()
    try? errPipe.fileHandleForWriting.close()

    let outFD = outPipe.fileHandleForReading.fileDescriptor
    let errFD = errPipe.fileHandleForReading.fileDescriptor
    for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) }

    var outData = Data(), errData = Data()
    var open: Set<Int32> = [outFD, errFD]
    var buffer = [UInt8](repeating: 0, count: 65536)
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    var timedOut = false
    var exitedAt: Date?

    while !open.isEmpty {
        var fds = open.sorted().map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        let ready = poll(&fds, nfds_t(fds.count), 100)
        if ready > 0 {
            for entry in fds where entry.revents != 0 {
                while true {
                    let n = read(entry.fd, &buffer, buffer.count)
                    if n > 0 {
                        if entry.fd == outFD { outData.append(buffer, count: n) } else { errData.append(buffer, count: n) }
                        continue
                    }
                    if n == 0 { open.remove(entry.fd) }
                    else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { open.remove(entry.fd) }
                    break
                }
            }
        }
        if let deadline, Date() >= deadline {
            timedOut = true
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            break
        }
        if !p.isRunning {
            // The child is gone. Give anything it left behind a moment, then stop waiting for
            // descriptors that some surviving grandchild is still holding open.
            let since = exitedAt ?? Date()
            exitedAt = since
            if ready == 0 && Date().timeIntervalSince(since) > 0.3 { break }
        }
    }

    try? outPipe.fileHandleForReading.close()
    try? errPipe.fileHandleForReading.close()
    p.waitUntilExit()

    if timedOut {
        return CommandResult(status: 124, stdout: String(decoding: outData, as: UTF8.self),
                             stderr: "timed out after \(Int(timeout ?? 0))s")
    }
    let r = CommandResult(status: p.terminationStatus,
                          stdout: String(decoding: outData, as: UTF8.self),
                          stderr: String(decoding: errData, as: UTF8.self))
    if check && r.status != 0 {
        throw SharkError("`\(args.joined(separator: " "))` exited with \(r.status)\n\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return r
}

/// Run a command attached to the current terminal (inherits stdin/stdout/stderr).
@discardableResult
func shInteractive(_ args: [String], check: Bool = true) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    if check && p.terminationStatus != 0 {
        throw SharkError("`\(args.joined(separator: " "))` exited with \(p.terminationStatus)")
    }
    return p.terminationStatus
}

/// Replace the current process image (used for ssh so the TTY is handed over cleanly).
func execReplace(_ args: [String]) -> Never {
    fflush(stdout)
    var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    cargs.append(nil)
    execvp(args[0], cargs)
    perror("execvp \(args[0])")
    exit(127)
}

func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:+@%,"))
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func shellJoin(_ args: [String]) -> String { args.map(shellQuote).joined(separator: " ") }

/// Parse "4g", "4096m", "4096" (MB by default for memory, GB by default for disk).
func parseSize(_ s: String, defaultUnit: String) throws -> UInt64 {
    let lower = s.lowercased().trimmingCharacters(in: .whitespaces)
    var digits = lower, unit = defaultUnit
    if let last = lower.last, last.isLetter {
        unit = String(last)
        digits = String(lower.dropLast())
        if digits.hasSuffix("i") { digits = String(digits.dropLast()) }
    }
    guard let n = Double(digits), n > 0 else { throw SharkError("invalid size: \(s)") }
    let shift: Int
    switch unit {
    case "k": shift = 10
    case "m": shift = 20
    case "g": shift = 30
    case "t": shift = 40
    default: throw SharkError("invalid size unit in: \(s)")
    }
    return UInt64(n * Double(UInt64(1) << shift))
}

func formatBytes(_ b: UInt64) -> String {
    let gb = Double(b) / Double(1 << 30)
    if gb >= 1 { return gb == gb.rounded() ? "\(Int(gb))G" : String(format: "%.1fG", gb) }
    return "\(b / (1 << 20))M"
}

func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func readString(_ url: URL) -> String? {
    (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func writeString(_ s: String, to url: URL) {
    try? s.write(to: url, atomically: true, encoding: .utf8)
}

func tail(_ url: URL, lines: Int) -> String {
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    return s.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
}

func isTTY() -> Bool { isatty(0) != 0 && isatty(1) != 0 }

func confirm(_ prompt: String) -> Bool {
    guard isatty(0) != 0 else { return false }
    print("\(prompt) [y/N] ", terminator: "")
    guard let line = readLine() else { return false }
    return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
}
