# Sharkbox

[English](README.md) · [中文](README.zh-CN.md)

Sharkbox runs Linux virtual machines on macOS through Apple's Virtualization framework, as a
command-line tool (`shark`) and a native SwiftUI application. Machines boot in a few seconds, share
the Mac home directory over virtiofs, accept SSH, run x86_64 binaries through Rosetta, and can host
a Docker engine for the Mac's `docker` CLI.

It is a single Swift binary with no third-party dependencies, no licence and no account.

```
$ shark create ubuntu          # download, create, boot, wait for SSH
$ shark                        # shell into the default machine, in the current directory
$ shark ubuntu uname -a        # run a command inside a machine
$ shark list
NAME      DISTRO        STATE    IP            CPU  MEM  DISK
ubuntu *  ubuntu:24.04  running  192.168.64.2  4    2G   64G (1.9G used)
```

## Requirements and installation

An Apple silicon Mac running macOS 14 or later, plus the Xcode Command Line Tools
(`xcode-select --install`). Xcode itself is not required.

```bash
make install
```

This builds both targets, applies an ad-hoc signature carrying the
`com.apple.security.virtualization` entitlement, and installs `shark` into `/opt/homebrew/bin` and
`Sharkbox.app` into `/Applications`. `make build` and `make app` build without installing.

## Commands

```
shark                          shell into the default machine
shark <name> [cmd...]          shell into a machine, or run a command in it

shark create <distro> [name]   create and start a machine
      --cpus 4  --memory 4g  --disk 64g  --no-rosetta  --no-start
shark list                     list machines
shark start|stop|restart <name>
shark delete [-f] <name>       delete a machine and its disk image
shark info <name>              configuration, paths and address
shark logs [-f] <name>         serial console log
shark fsck [--repair] <name>   check or repair a stopped machine's root filesystem
shark set <name> --cpus 4 --memory 4g --disk 128g
                               change a stopped machine's resources; a disk can only grow
shark default [name]           show or set the default machine

shark shell <name>             interactive login shell
shark run <name> <cmd...>      run a command with stdin and stdout connected
shark docker <name>            install Docker in a machine and point the Mac CLI at it
shark ssh-config [--install]   write ~/.sharkbox/ssh_config so `ssh <name>.shark` works

shark images | pull <distro> | image rm <distro>
```

Distributions: `ubuntu` (24.04), `ubuntu:22.04`, `debian` (13) and `debian:12`, from each project's
official cloud images.

## Inside a machine

The Mac home directory is mounted at `/mnt/mac`, with `/Users/<you>` symlinked to it so absolute
macOS paths also resolve in Linux. Running `shark` from a directory under your home opens a shell in
the same directory in the guest. The guest account reuses your macOS user name and uid, so ownership
on the shared directory is correct, and has passwordless sudo. Networking is NAT, with an address
on 192.168.64.0/24 per machine.

## Application

`make install` also installs `Sharkbox.app`. Interface icons are SF Symbols; the distro marks are the
official Ubuntu and Debian logos, bundled as SVG from `Resources/`.

- Menu bar: state and address per machine, start, stop and terminal buttons, and a submenu with the
  copy and maintenance actions.
- Main window: sidebar grouped by state with a search filter and a disk usage footer; overview,
  console and resources tabs, the last of which edits CPU, memory and disk on a stopped machine.
- Application menus: each action under `Machine` is a submenu listing the machines it applies to.
- Settings: terminal application, refresh interval, console buffer, defaults for new machines,
  image management and storage usage.

The application is a front end for the command-line tool: every action invokes `shark`, and state is
read from `~/.sharkbox`.

## Design notes

- A running machine is a detached `shark __runner <name>` process; its state lives in
  `~/.sharkbox/machines/<name>/`. Ubuntu uses direct kernel boot, Debian boots the official raw
  image over UEFI, and cloud-init configures the first boot from a NoCloud seed image.
- SSH travels over virtio-vsock rather than TCP. A guest agent exposes sshd on a vsock port, the
  runner republishes it as a Unix socket, and `ssh` reaches it through
  `ProxyCommand=shark __proxy <name>`. Machines therefore stay reachable on Macs where a TUN-mode
  VPN intercepts all TCP traffic.
- Root filesystems are grown offline in a helper virtual machine: Ubuntu 24.04's 6.8 kernel corrupts
  ext4 when resizing a mounted 2 GB image to 64 GB. `shark fsck` and `shark set --disk` reuse that
  helper.
- Machines shut down through the guest agent (`systemctl poweroff`). A virtual power-button request
  is easy for a busy guest to ignore, and the forced power cut after the timeout was the main source
  of filesystem damage. The console is watched so a guest that has finished powering off, or that
  cannot execute its shutdown binary because its root filesystem went read-only, is stopped at once.
- Every process opens a disk image with the same policy — uncached, fully synchronized, with
  `F_FULLFSYNC` when the image passes between processes. Mixing policies let the runner read stale
  blocks written by a helper, which ext4 reported as checksum failures. An exclusive `flock` keeps
  two virtual machines from ever writing to one image.
- Clean shutdowns are recorded; after an unclean one `e2fsck` runs before the guest boots,
  escalating to a full repair when preen mode declines to fix something.

## Compared with OrbStack

| | OrbStack | Sharkbox |
|---|---|---|
| Price | Free for personal use, 96 USD/year commercial | Free |
| Linux machines, file sharing, Rosetta | Yes | Yes |
| Docker | Built-in engine | `shark docker` installs an engine in a machine; the Mac CLI (`brew install docker`) connects over an SSH context |
| Graphical application | Yes | Yes |
| Filesystem check and repair | — | `shark fsck`, automatic after an unclean shutdown |
| Kubernetes, memory ballooning, `*.orb.local` names | Yes | No |

## Limitations

- Disk images are sparse, so `--disk 64g` reserves nothing up front; but if the Mac fills up the
  guest filesystem can be damaged, so `shark create` warns when free space is below the configured
  size.
- Reaching a service on a machine's address from the Mac uses ordinary TCP, which a TUN-mode VPN
  will intercept unless `192.168.64.0/24` is in its bypass list. The `shark` shell, `run` and
  `docker` paths use vsock and are unaffected.
- Apple silicon only. The Ubuntu kernel is supplied by the host, as under OrbStack, so upgrading it
  inside a machine has no effect.
- A heavy write workload followed by a clean shutdown can still leave ext4 metadata that `e2fsck -p`
  declines to repair. `shark fsck --repair` fixes it, and the automatic check on the next start does
  so on its own.

## Uninstallation

```bash
shark stop --all
make uninstall            # removes /opt/homebrew/bin/shark and /Applications/Sharkbox.app
rm -rf ~/.sharkbox        # removes all machines and cached images
```
