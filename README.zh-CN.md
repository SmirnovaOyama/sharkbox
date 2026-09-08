# Sharkbox

[English](README.md) · [中文](README.zh-CN.md)

Sharkbox 基于 Apple 的 Virtualization framework 在 macOS 上运行 Linux 虚拟机，提供命令行工具
`shark` 和一个原生 SwiftUI 应用。虚拟机数秒内完成启动，通过 virtiofs 共享 Mac 主目录，支持 SSH，
可经由 Rosetta 运行 x86_64 二进制，也可以在其中部署 Docker 引擎供 Mac 上的 `docker` 命令使用。

项目是单个 Swift 二进制，无第三方依赖，无授权费用，无需账号。

```
$ shark create ubuntu          # 下载、创建、启动并等待 SSH 就绪
$ shark                        # 进入默认机器的 shell，并停留在当前目录
$ shark ubuntu uname -a        # 在机器中执行命令
$ shark list
NAME      DISTRO        STATE    IP            CPU  MEM  DISK
ubuntu *  ubuntu:24.04  running  192.168.64.2  4    2G   64G (1.9G used)
```

## 环境要求与安装

Apple 芯片的 Mac，macOS 14 或更高版本，并安装 Xcode Command Line Tools
（`xcode-select --install`）。无需完整的 Xcode。

```bash
make install
```

该命令构建两个目标，以 ad-hoc 方式签名并附加 `com.apple.security.virtualization` entitlement，
随后将 `shark` 安装至 `/opt/homebrew/bin`，`Sharkbox.app` 安装至 `/Applications`。
`make build` 与 `make app` 仅构建、不安装。

## 命令

```
shark                          进入默认机器的 shell
shark <name> [cmd...]          进入指定机器的 shell，或在其中执行命令

shark create <distro> [name]   创建并启动机器
      --cpus 4  --memory 4g  --disk 64g  --no-rosetta  --no-start
shark list                     列出机器
shark start|stop|restart <name>
shark delete [-f] <name>       删除机器及其磁盘镜像
shark info <name>              配置、路径与地址
shark logs [-f] <name>         串口控制台日志
shark fsck [--repair] <name>   检查或修复已停止机器的根文件系统
shark set <name> --cpus 4 --memory 4g --disk 128g
                               修改已停止机器的资源配置，磁盘仅可扩大
shark default [name]           查看或设置默认机器

shark shell <name>             交互式登录 shell
shark run <name> <cmd...>      执行命令，stdin 与 stdout 连通
shark docker <name>            在机器中安装 Docker，并将 Mac 上的 CLI 指向该机器
shark ssh-config [--install]   生成 ~/.sharkbox/ssh_config，之后可直接 `ssh <name>.shark`

shark images | pull <distro> | image rm <distro>
```

可用发行版：`ubuntu`（24.04）、`ubuntu:22.04`、`debian`（13）、`debian:12`，均取自各项目的官方
cloud image。

## 机器内部环境

Mac 主目录挂载于 `/mnt/mac`，并将 `/Users/<用户名>` 软链接至该目录，因此 macOS 的绝对路径在 Linux
中同样有效。在主目录下的任意目录执行 `shark`，会在客户机中打开同一目录的 shell。客户机账号沿用
macOS 的用户名与 uid，共享目录的文件归属因此保持正确，并配置了免密 sudo。网络采用 NAT，每台机器在
192.168.64.0/24 上拥有独立地址。

## 应用程序

`make install` 会一并安装 `Sharkbox.app`。图标为代码绘制的矢量路径
（`Sources/SharkboxApp/Icons.swift`），未使用 SF Symbols。

- 菜单栏：显示各机器的状态与地址，提供启动、停止、终端按钮，以及包含复制与维护操作的子菜单。
- 主窗口：侧栏按运行状态分组，带搜索过滤与磁盘占用信息；详情分为概览、控制台与资源三个标签页，
  其中资源页可在机器停止时修改 CPU、内存与磁盘。
- 应用主菜单：`Machine` 下的每项操作均为子菜单，直接列出适用的机器。
- 设置：终端应用、刷新间隔、控制台缓冲、新建机器的默认值、镜像管理与存储用量。

应用是命令行工具的前端：所有操作均调用 `shark`，状态直接读取 `~/.sharkbox`。

## 设计说明

- 每台运行中的机器对应一个后台的 `shark __runner <name>` 进程，状态位于
  `~/.sharkbox/machines/<name>/`。Ubuntu 采用内核直接引导，Debian 以 UEFI 引导官方 raw 镜像，
  首次启动由 NoCloud seed 镜像中的 cloud-init 完成配置。
- SSH 走 virtio-vsock 而非 TCP：客户机内的 agent 将 sshd 暴露在 vsock 端口上，runner 进程将其转为
  Unix socket，`ssh` 通过 `ProxyCommand=shark __proxy <name>` 接入。因此在启用 TUN 模式 VPN、
  主机 TCP 被全面拦截的 Mac 上，机器依然可达。
- 根文件系统的扩容在辅助虚拟机中离线完成：Ubuntu 24.04 的 6.8 内核在线将已挂载的 2 GB 镜像扩至
  64 GB 会破坏 ext4。`shark fsck` 与 `shark set --disk` 复用同一套辅助虚拟机。
- 关机通过客户机 agent 执行 `systemctl poweroff`。虚拟电源键请求容易被繁忙的客户机完全忽略，
  超时后的强制断电正是文件系统损坏的主要来源。同时监控串口输出，若客户机已完成关机、
  或因根分区转为只读而无法执行 shutdown 程序，则立即结束虚拟机。
- 所有进程以相同策略打开磁盘镜像：uncached、完全同步，并在镜像于进程间交接时执行 `F_FULLFSYNC`。
  策略不一致会导致 runner 读到辅助虚拟机写入前的旧数据块，ext4 将其报告为校验和失败。
  排他 `flock` 确保任何时刻只有一个虚拟机写入同一镜像。
- 干净关机会被记录；若上次为非正常关机，则在客户机启动前运行 `e2fsck`，
  当 preen 模式拒绝自动修复时升级为完整修复。

## 与 OrbStack 的比较

| | OrbStack | Sharkbox |
|---|---|---|
| 价格 | 个人免费，商用 96 美元/年 | 免费 |
| Linux 机器、文件共享、Rosetta | 是 | 是 |
| Docker | 内置引擎 | `shark docker` 在机器中安装引擎，Mac 上的 CLI（`brew install docker`）经 SSH context 连接 |
| 图形界面 | 是 | 是 |
| 文件系统检查与修复 | — | `shark fsck`，非正常关机后自动执行 |
| Kubernetes、内存动态回收、`*.orb.local` 域名 | 是 | 否 |

## 已知限制

- 磁盘镜像为稀疏文件，`--disk 64g` 不会预先占用空间；但 Mac 磁盘写满时客户机文件系统可能损坏，
  因此 `shark create` 会在剩余空间低于配置容量时给出提示。
- 从 Mac 直接访问机器地址上的服务走普通 TCP，若存在 TUN 模式的 VPN，需将 `192.168.64.0/24`
  加入其绕过列表。`shark` 的 shell、`run` 与 `docker` 走 vsock，不受影响。
- 仅支持 Apple 芯片。Ubuntu 的内核由宿主提供（与 OrbStack 相同），在机器内升级内核不会生效。
- 大量写入后即使执行干净关机，仍可能残留 `e2fsck -p` 拒绝自动修复的 ext4 元数据问题。
  `shark fsck --repair` 可修复，下次启动时的自动检查也会自行处理。

## 卸载

```bash
shark stop --all
make uninstall            # 移除 /opt/homebrew/bin/shark 与 /Applications/Sharkbox.app
rm -rf ~/.sharkbox        # 移除所有机器与镜像缓存
```
