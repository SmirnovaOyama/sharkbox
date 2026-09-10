import Foundation
import Virtualization

/// Runs inside the runner process. Listens on a Unix socket next to the machine and bridges each
/// client to a virtio-vsock port in the guest. Protocol: client sends "<port>\n", then raw bytes flow.
final class VsockProxy {
    let vm: VZVirtualMachine
    let queue: DispatchQueue
    let path: String
    let log: (String) -> Void
    private var listenFD: Int32 = -1

    init(vm: VZVirtualMachine, queue: DispatchQueue, path: String, log: @escaping (String) -> Void) {
        self.vm = vm; self.queue = queue; self.path = path; self.log = log
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SharkError("socket() failed: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { throw SharkError("socket path too long: \(path)") }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
                path.withCString { src in _ = strncpy(dst, src, maxLen) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { throw SharkError("bind(\(path)) failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { throw SharkError("listen failed: \(String(cString: strerror(errno)))") }
        listenFD = fd
        Thread(block: { self.acceptLoop() }).start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                log("accept failed: \(String(cString: strerror(errno)))")
                return
            }
            Thread(block: { self.handle(client) }).start()
        }
    }

    private func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var ch: UInt8 = 0
        while bytes.count < 16 {
            let n = read(fd, &ch, 1)
            if n <= 0 { return nil }
            if ch == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(ch)
        }
        return nil
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        guard let line = readLine(client), let port = UInt32(line.trimmingCharacters(in: .whitespaces)) else {
            return
        }
        guard let conn = connectGuest(port: port) else {
            let msg = "ERR no vsock connection to guest port \(port)\n"
            _ = msg.withCString { write(client, $0, msg.utf8.count) }
            return
        }
        let vfd = conn.fileDescriptor
        let group = DispatchGroup()
        group.enter()
        Thread(block: {
            VsockProxy.pump(from: client, to: vfd)
            shutdown(vfd, SHUT_WR)
            group.leave()
        }).start()
        group.enter()
        Thread(block: {
            VsockProxy.pump(from: vfd, to: client)
            shutdown(client, SHUT_WR)
            group.leave()
        }).start()
        group.wait()
        conn.close()
    }

    /// Open a vsock connection to `port` in the guest (blocks the calling thread, not the VM queue).
    func connectGuest(port: UInt32, timeout: TimeInterval = 5) -> VZVirtioSocketConnection? {
        let sem = DispatchSemaphore(value: 0)
        var result: VZVirtioSocketConnection?
        queue.async {
            guard self.vm.state == .running,
                  let dev = self.vm.socketDevices.first as? VZVirtioSocketDevice else { sem.signal(); return }
            dev.connect(toPort: port) { r in
                if case .success(let c) = r { result = c }
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return result
    }

    /// Ask the guest agent (vsock port 2223) for its addresses.
    func guestInfo() -> [String: Any]? {
        guard let conn = connectGuest(port: 2223, timeout: 3) else { return nil }
        defer { conn.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn.fileDescriptor, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.count > 65536 { break }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Bound a blocking read. `connectGuest` only bounds the *connect*, so without this a guest that
    /// accepts the connection and then never answers blocks the caller forever.
    private func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Push the host's wall clock to the guest agent (vsock port 2224). Returns true if the guest acknowledged.
    @discardableResult
    func pushClock() -> Bool {
        guard let conn = connectGuest(port: 2224, timeout: 3) else { return false }
        defer { conn.close() }
        let msg = String(format: "%.3f\n", Date().timeIntervalSince1970)
        _ = msg.withCString { write(conn.fileDescriptor, $0, msg.utf8.count) }
        setReadTimeout(conn.fileDescriptor, seconds: 3)
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(conn.fileDescriptor, &buf, buf.count)
        return n > 0 && buf[0] == UInt8(ascii: "o")
    }

    /// Ask the guest agent to shut the machine down cleanly (vsock port 2225).
    /// Returns true when the agent acknowledged. Must NOT be called on the VM queue.
    func powerOff() -> Bool {
        guard let conn = connectGuest(port: 2225, timeout: 5) else { return false }
        defer { conn.close() }
        let msg = "poweroff\n"
        _ = msg.withCString { write(conn.fileDescriptor, $0, msg.utf8.count) }
        setReadTimeout(conn.fileDescriptor, seconds: 5)
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(conn.fileDescriptor, &buf, buf.count)
        return n > 0 && buf[0] == UInt8(ascii: "o")
    }

    static func pump(from src: Int32, to dst: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(src, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue }; return }
            if n == 0 { return }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(dst, $0.baseAddress! + off, n - off) }
                if w < 0 { if errno == EINTR { continue }; return }
                off += w
            }
        }
    }
}

/// Client side (`shark __proxy <name>`): used as an ssh ProxyCommand. stdin/stdout ⇄ runner's Unix socket ⇄ guest vsock.
enum VsockClient {
    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
                path.withCString { src in _ = strncpy(dst, src, maxLen) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    /// Relay stdin/stdout to guest vsock `port`. Exits the process when done.
    static func proxy(machine: Machine, port: UInt32) -> Never {
        let path = machine.dir.appendingPathComponent("vsock.sock").path
        guard machine.isRunning, let fd = connect(path: path) else {
            FileHandle.standardError.write("shark: machine \(machine.name) is not running\n".data(using: .utf8)!)
            exit(1)
        }
        let hello = "\(port)\n"
        _ = hello.withCString { write(fd, $0, hello.utf8.count) }
        signal(SIGPIPE, SIG_IGN)
        Thread(block: {
            VsockProxy.pump(from: 0, to: fd)
            shutdown(fd, SHUT_WR)
        }).start()
        VsockProxy.pump(from: fd, to: 1)
        exit(0)
    }
}
