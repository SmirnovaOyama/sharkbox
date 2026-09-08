import Foundation

enum CloudInit {
    /// Build the NoCloud seed ISO (label "cidata") for a machine.
    static func buildSeed(for m: Machine, publicKey: String) throws {
        let seedDir = m.dir.appendingPathComponent("seed")
        let fm = FileManager.default
        try? fm.removeItem(at: seedDir)
        try fm.createDirectory(at: seedDir, withIntermediateDirectories: true)

        try userData(for: m, publicKey: publicKey)
            .write(to: seedDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try metaData(for: m)
            .write(to: seedDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: m.seedISO)
        try sh(["hdiutil", "makehybrid", "-quiet", "-iso", "-joliet",
                "-default-volume-name", "cidata",
                "-o", m.seedISO.path, seedDir.path])
        try? fm.removeItem(at: seedDir)
    }

    static func metaData(for m: Machine) -> String {
        """
        instance-id: \(m.name)-\(UUID().uuidString.lowercased().prefix(8))
        local-hostname: \(m.name)

        """
    }

    static func userData(for m: Machine, publicKey: String) -> String {
        let c = m.config
        var files: [(path: String, perms: String, content: String)] = []
        var runcmd: [String] = [
            "systemctl daemon-reload",
            "systemctl enable --now mnt-mac.mount || true",
            "systemctl enable --now sharkbox-agent.service || true",
            "mkdir -p /Users && ln -sfn /mnt/mac /Users/\(c.user)",
        ]

        files.append((path: "/etc/systemd/system/mnt-mac.mount", perms: "0644", content: """
        [Unit]
        Description=macOS home directory (Sharkbox)

        [Mount]
        What=mac
        Where=/mnt/mac
        Type=virtiofs
        Options=defaults

        [Install]
        WantedBy=multi-user.target
        """))

        if c.rosetta {
            files.append((path: "/etc/systemd/system/mnt-rosetta.mount", perms: "0644", content: """
            [Unit]
            Description=Rosetta x86_64 translator share (Sharkbox)

            [Mount]
            What=rosetta
            Where=/mnt/rosetta
            Type=virtiofs
            Options=ro

            [Install]
            WantedBy=multi-user.target
            """))
            files.append((path: "/usr/local/lib/sharkbox/rosetta-binfmt.sh", perms: "0755", content: """
            #!/bin/sh
            # Register Rosetta as the x86_64 ELF interpreter (retries: the share can be slow to settle at boot).
            magic=':rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/mnt/rosetta/rosetta:OCF'
            [ -x /mnt/rosetta/rosetta ] || { echo "rosetta share not mounted"; exit 0; }
            i=0
            while [ $i -lt 15 ]; do
              [ -e /proc/sys/fs/binfmt_misc/rosetta ] && exit 0
              [ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
              printf %s "$magic" > /proc/sys/fs/binfmt_misc/register 2>/dev/null && exit 0
              i=$((i+1)); sleep 1
            done
            echo "failed to register rosetta with binfmt_misc" >&2
            exit 1
            """))
            files.append((path: "/etc/systemd/system/rosetta-binfmt.service", perms: "0644", content: """
            [Unit]
            Description=Register Rosetta as the x86_64 ELF interpreter (Sharkbox)
            Requires=mnt-rosetta.mount
            After=mnt-rosetta.mount proc-sys-fs-binfmt_misc.automount

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/local/lib/sharkbox/rosetta-binfmt.sh

            [Install]
            WantedBy=multi-user.target
            """))
            runcmd.append("systemctl enable --now mnt-rosetta.mount rosetta-binfmt.service || true")
        }

        files.append((path: "/usr/local/lib/sharkbox/agent.py", perms: "0755", content: guestAgentScript))
        files.append((path: "/etc/systemd/system/sharkbox-agent.service", perms: "0644", content: """
        [Unit]
        Description=Sharkbox guest agent (ssh, info, clock and power control over virtio-vsock)
        After=network.target ssh.service sshd.service

        [Service]
        ExecStartPre=-/sbin/modprobe vmw_vsock_virtio_transport
        ExecStart=/usr/bin/python3 /usr/local/lib/sharkbox/agent.py
        Restart=always
        RestartSec=1

        [Install]
        WantedBy=multi-user.target
        """))

        files.append((path: "/etc/motd", perms: "0644", content: """
        Sharkbox machine "\(m.name)" (\(c.distro))
          Your Mac home directory is at /mnt/mac (also /Users/\(c.user))

        """))

        var y = "#cloud-config\n"
        y += "hostname: \(m.name)\n"
        y += "manage_etc_hosts: true\n"
        y += "ssh_pwauth: false\n"
        y += "package_update: false\n"
        y += "package_upgrade: false\n"
        y += "growpart:\n  mode: auto\n  devices: ['/']\n"
        y += "resize_rootfs: true\n"
        y += "users:\n"
        y += "  - name: \(c.user)\n"
        y += "    uid: \(c.uid)\n"
        y += "    gecos: \(c.user)\n"
        y += "    shell: /bin/bash\n"
        y += "    lock_passwd: true\n"
        y += "    sudo: ['ALL=(ALL) NOPASSWD:ALL']\n"
        y += "    groups: [adm, sudo, users]\n"
        y += "    ssh_authorized_keys:\n"
        y += "      - \(publicKey)\n"
        y += "write_files:\n"
        for f in files {
            y += "  - path: \(f.path)\n"
            y += "    permissions: '\(f.perms)'\n"
            y += "    content: |\n"
            for line in f.content.split(separator: "\n", omittingEmptySubsequences: false) {
                y += "      \(line)\n"
            }
        }
        y += "runcmd:\n"
        for cmd in runcmd { y += "  - \(shellQuote(cmd) == cmd ? cmd : "\"" + cmd.replacingOccurrences(of: "\"", with: "\\\"") + "\"")\n" }
        y += "final_message: \"Sharkbox: cloud-init finished after $UPTIME seconds\"\n"
        return y
    }
}


extension CloudInit {
    /// Runs inside the guest. Exposes sshd on vsock port 2222 and basic machine info on vsock port 2223,
    /// so the host can reach the machine even when a VPN/proxy on the Mac captures TCP traffic.
    static let guestAgentScript = """
    #!/usr/bin/env python3
    # Sharkbox guest agent - do not edit (managed by cloud-init)
    import json, socket, subprocess, sys, threading, time

    SSH_PORT, INFO_PORT, CLOCK_PORT, CTRL_PORT = 2222, 2223, 2224, 2225

    def pump(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def handle_ssh(conn):
        try:
            tcp = socket.create_connection(("127.0.0.1", 22), timeout=10)
            tcp.settimeout(None)
        except OSError:
            conn.close()
            return
        t = threading.Thread(target=pump, args=(conn, tcp), daemon=True)
        t.start()
        pump(tcp, conn)
        t.join(timeout=5)
        for s in (conn, tcp):
            try:
                s.close()
            except OSError:
                pass

    def info():
        try:
            ips = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5).stdout.split()
        except Exception:
            ips = []
        ip4 = [i for i in ips if "." in i and not i.startswith("127.")]
        return json.dumps({"ip": ip4[0] if ip4 else None, "ips": ips, "hostname": socket.gethostname()}).encode()

    def handle_info(conn):
        try:
            conn.sendall(info())
        except OSError:
            pass
        finally:
            conn.close()

    def handle_clock(conn):
        # Host pushes its wall clock ("<unix seconds>\\n"); step ours if we drifted more than a second.
        try:
            data = b""
            while not data.endswith(b"\\n") and len(data) < 64:
                chunk = conn.recv(64)
                if not chunk:
                    break
                data += chunk
            host = float(data.strip())
            if abs(time.time() - host) > 1.0:
                time.clock_settime(time.CLOCK_REALTIME, host)
            conn.sendall(b"ok\\n")
        except Exception as e:
            print("clock sync error:", repr(e), file=sys.stderr, flush=True)
        finally:
            conn.close()

    def handle_ctrl(conn):
        # The host asks us to shut down here instead of relying on the virtual power button,
        # which some guests never act on.
        try:
            cmd = conn.recv(64).strip()
            if cmd in (b"poweroff", b"reboot"):
                conn.sendall(b"ok\\n")
                conn.close()
                subprocess.Popen(["systemctl", "--no-block", cmd.decode()])
                return
            conn.sendall(b"err\\n")
        except Exception as e:
            print("ctrl error:", repr(e), file=sys.stderr, flush=True)
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def serve(port, handler):
        while True:
            try:
                s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                s.bind((socket.VMADDR_CID_ANY, port))
                s.listen(64)
                break
            except OSError:
                time.sleep(1)
        while True:
            conn, _ = s.accept()
            threading.Thread(target=handler, args=(conn,), daemon=True).start()

    threading.Thread(target=serve, args=(INFO_PORT, handle_info), daemon=True).start()
    threading.Thread(target=serve, args=(CLOCK_PORT, handle_clock), daemon=True).start()
    threading.Thread(target=serve, args=(CTRL_PORT, handle_ctrl), daemon=True).start()
    serve(SSH_PORT, handle_ssh)
    """
}
