# Sharkbox 🦈

**免费、开源的 OrbStack 平替（Linux 机器部分）。** 用 Apple 自带的 Virtualization.framework 在 macOS 上秒开 Linux 虚拟机，
Mac 主目录自动共享进去，SSH 直连，能跑 x86 程序（Rosetta），能装 Docker 给 Mac 上的 `docker` 命令用。

单个 Swift 二进制，没有任何第三方依赖，不收费、不登录、不联网上报。

```
$ shark create ubuntu        # 下载镜像 + 创建 + 启动 + 等到能 ssh，冷启动约 14 秒（镜像缓存后）
$ shark                      # 进默认机器的 shell，自动 cd 到你当前的 Mac 目录
$ shark ubuntu uname -a      # 在机器里跑命令
$ shark list
NAME      DISTRO        STATE    IP            CPU  MEM  DISK
ubuntu *  ubuntu:24.04  running  192.168.64.2  4    2G   64G (1.9G used)
```

## GUI

`make install` 同时会把 **Sharkbox.app** 装到 `/Applications`。它是原生 SwiftUI 应用：

- 菜单栏图标：一眼看到每台机器的状态和 IP，一键启动/停止、打开终端、新建机器，可设置开机自启。
- 主窗口：左侧机器列表，右侧详情（资源、IP、SSH 地址、目录）、操作按钮（启动/停止/重启/打开终端/装 Docker/设为默认/删除）、实时控制台日志。
- 新建机器窗口：选发行版、名字、CPU/内存/磁盘、Rosetta 开关，创建过程的输出实时显示。

GUI 只是 `shark` 命令的前端：所有操作都是调用 `/opt/homebrew/bin/shark`（App 里也自带一份），状态直接读 `~/.sharkbox`。
"打开终端"会用 Terminal.app 打开 `shark shell <name>`；想换 iTerm 之类的：`defaults write dev.sharkbox.app terminalApp iTerm`。

## 要求

- Apple Silicon Mac，macOS 14 以上
- Xcode Command Line Tools（用来编译，`xcode-select --install`）

## 安装

```bash
make install            # 编译、签名、装到 /opt/homebrew/bin/shark
```

只编译不安装：`make build`（CLI，产物 `build/shark`）、`make app`（GUI，产物 `build/Sharkbox.app`）。
二进制必须带 `com.apple.security.virtualization` entitlement 签名（Makefile 会自动做 ad-hoc 签名）。
不需要 Xcode，命令行工具的 `swiftc` 就够了；GUI 代码刻意没用 `@State`（macOS 26+ SDK 里它是宏，宏插件只随 Xcode 提供）。

## 用法

```
shark                          进默认机器的 shell
shark <name> [cmd...]          进 <name> 的 shell / 在里面跑命令
shark -m <name> [cmd...]       同上（OrbStack 风格）

shark create <distro> [name]   创建并启动机器      例：shark create ubuntu
      --cpus 4  --memory 4g  --disk 64g  --no-rosetta  --no-start
shark list                     列出机器
shark start|stop|restart <name>
shark delete [-f] <name>       删除机器及其磁盘
shark info <name>              配置、路径、IP
shark ip <name>                打印机器 IP
shark logs [-f] <name>         看串口控制台日志（排查启动问题）
shark default [name]           查看 / 设置默认机器

shark shell <name>             交互式登录 shell
shark run <name> <cmd...>      跑命令，stdin/stdout 可以管道
shark docker <name>            在机器里装 Docker，并把 Mac 上的 docker CLI 指过去
shark ssh-config [--install]   生成 ~/.sharkbox/ssh_config，之后可以直接 `ssh <name>.shark`

shark images                   可用发行版
shark pull <distro>            提前下载镜像
```

支持的发行版：`ubuntu`（24.04）、`ubuntu:22.04`、`debian`（13）、`debian:12`。镜像来自各发行版官方的 cloud image。

## 机器里长什么样

- 你的 Mac 主目录挂在 `/mnt/mac`，另外 `/Users/<你>` 是指向它的软链接，所以 Mac 上的绝对路径在 Linux 里也能用。
- 在 Mac 的某个目录下敲 `shark`，会直接进到 Linux 里的同一个目录。
- Linux 里的用户名和 uid 跟 Mac 一致（所以共享目录里的文件权限是对的），免密 sudo。
- 有 Rosetta 的 Mac 上，x86_64 的 Linux 二进制可以直接运行（`shark create` 默认开启）。
- 网络是 NAT，机器有自己的 192.168.64.x 地址，能上网。

## 和 OrbStack 的区别

| | OrbStack | Sharkbox |
|---|---|---|
| 价格 | 个人免费，商用 $96/年 | 免费 |
| Linux 机器 | ✓ | ✓ |
| Mac 文件共享 | ✓ | ✓（virtiofs） |
| SSH / 命令 / 目录映射 | ✓ | ✓ |
| Rosetta 跑 x86 | ✓ | ✓ |
| Docker | 内置引擎 | `shark docker` 在机器里装 Docker Engine，Mac 上的 docker CLI（`brew install docker`，或 OrbStack 自带的 `/Applications/OrbStack.app/Contents/MacOS/xbin/docker`）通过 ssh context 连过去 |
| GUI、菜单栏 | ✓ | ✓ |
| Kubernetes | ✓ | ✗ |
| 内存动态回收、`*.orb.local` 域名 | ✓ | ✗ |

## 工作原理

- 每台机器是一个后台进程 `shark __runner <name>`，用 Virtualization.framework 跑虚拟机，数据在 `~/.sharkbox/machines/<name>/`。
- Ubuntu 用内核直接引导（官方 cloud image 的 rootfs + kernel + initrd），Debian 用 UEFI 引导官方 raw 镜像。
- 首次启动用 cloud-init（NoCloud seed ISO）建用户、装 SSH 公钥、挂共享目录、装一个小的 guest agent。
- **SSH 不走 TCP，走 virtio-vsock**：guest agent 把 sshd 暴露在 vsock 上，runner 进程把它变成 Unix socket，
  `ssh` 通过 `ProxyCommand=shark __proxy <name>` 接进去。这样 Mac 上开着 VPN / 代理（比如 Shadowrocket 的 TUN 模式会截获所有 TCP）也照样能连。
- 扩容根分区不在 guest 里在线做（Ubuntu 24.04 的 6.8 内核在线扩到 64G 会把 ext4 搞坏），
  而是创建时先起一个 2 秒的辅助 VM 离线跑 `e2fsck + resize2fs`。

## 已知限制

- 从 Mac 直接访问机器的 IP 端口（比如机器里跑的 web 服务）走的是普通 TCP。如果 Mac 上有 TUN 模式的代理/VPN，需要在代理里把 `192.168.64.0/24` 加进绕过列表，否则会被劫持。`shark` 自己的 shell / run / docker 不受影响。
- 只支持 Apple Silicon。
- 机器停掉再启动会保留磁盘，但 Ubuntu 的内核是宿主提供的（和 OrbStack 一样），在机器里 `apt upgrade` 内核不会生效。

## 卸载

```bash
shark stop --all
make uninstall            # 删 /opt/homebrew/bin/shark 和 /Applications/Sharkbox.app
rm -rf ~/.sharkbox        # 删除所有机器和镜像缓存
```
