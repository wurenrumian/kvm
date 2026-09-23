# 演示脚本

配套课程 `/home/rumian/kvm` 的可运行演示。每个脚本对应课程里的一个核心概念，
输出带讲解，可单独运行。

## 快速开始

```bash
cd /home/rumian/kvm/scripts
chmod +x *.sh

# 1) 先自检环境（只读，安全）
./01-check-env.sh

# 2) 缺工具就装（需要 sudo，会装 QEMU/libvirt）
sudo ./02-setup-toolchain.sh
#   装完请重新登录，让 kvm/libvirt 组生效

# 3) 下载演示镜像（独立脚本，约 60MB）
./00-download-iso.sh

# 4) 按顺序体验各演示
./03-demo-storage.sh
./04-demo-vm-process.sh
./05-demo-vm-lifecycle.sh
./06-demo-network.sh
./07-demo-monitor-perf.sh
```

懒得一步步来就直接用 `./run-all.sh`（见下）。

## 一键运行（run-all.sh）

```bash
cd /home/rumian/kvm/scripts
./run-all.sh
```

它会依次：**环境自检 → 安装工具链 → 下载镜像 → 跑全部演示 → 打印完成汇总**。
安装那步会调用 `sudo`，在终端里输一次密码即可；结束时会打印一张结果表并响铃。

| 选项 | 作用 |
| --- | --- |
| `--no-install` | 已装好，只跑演示 |
| `--install-only` | 只安装，不跑演示 |
| `--no-download` | 不下载演示镜像（04/05 将跳过） |
| `--skip "04 05"` | 跳过指定编号的演示 |
| `--yes` | 所有确认自动通过（无终端时默认开启） |

日志写在 `~/kvm/logs/run-all-<时间>.log`，最近一次结果在 `~/kvm/logs/last-status.txt`。

> 没有终端（如放进 CI）时，`sudo` 无法输密码，安装会失败；此时请先手动
> `sudo ./02-setup-toolchain.sh`，再用 `./run-all.sh --no-install --yes` 跑演示。

## 脚本清单

| 脚本 | 演示内容 | 对应模块 | 需要 root | 需要镜像 |
| --- | --- | --- | --- | --- |
| `run-all.sh` | 一键：自检→安装→下载镜像→全部演示→汇总 | — | 安装步需要 | 自动下载 |
| `00-download-iso.sh` | 下载演示镜像（独立脚本） | — | 否 | — |
| `01-check-env.sh` | 环境自检：CPU/模块/设备/工具链 | 01, 02 | 否 | 否 |
| `02-setup-toolchain.sh` | 安装并配置 KVM 工具链 | 02 | 是 | 否 |
| `03-demo-storage.sh` | 镜像格式、精简置备、后备链、扩容 | 05 | 否 | 否 |
| `04-demo-vm-process.sh` | 虚拟机就是一个 Linux 进程（vCPU=线程） | 01, 03 | 否 | 是 |
| `05-demo-vm-lifecycle.sh` | libvirt define/start/suspend/destroy | 04 | 否 | 是 |
| `06-demo-network.sh` | 网桥、tap 设备、NAT 数据通路 | 06 | 部分 | 否 |
| `07-demo-monitor-perf.sh` | kvm_stat / perf kvm / domstats | 08, 11 | 部分 | 否 |

## 环境变量

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `KVM_ISO` | 指定已有的 ISO 路径，优先于默认位置 | 无 |
| `KVM_ISO_DIR` | ISO 存放目录 | `~/kvm/iso` |
| `LIBVIRT_URI` | libvirt 连接 URI | `qemu:///session` |
| `KVM_DEMO_BASE` | 临时工作目录根 | `/tmp/opencode` |
| `ASSUME_YES` | 设为 1 时所有确认自动通过 | 0 |
| `NO_PAUSE` | 设为 1 时不等待回车 | 0 |
| `NO_COLOR` | 设为 1 时关闭彩色输出 | 无 |

## 下载镜像（00-download-iso.sh）

下载是**独立脚本**，演示脚本自己不下载。默认下载 Alpine virt ISO 到
`~/kvm/iso/alpine-virt.iso`，并做 SHA256 校验。

```bash
./00-download-iso.sh                            # 下载 Alpine virt ISO
./00-download-iso.sh --dir /data/iso            # 指定保存目录
./00-download-iso.sh --force                    # 已存在也重下
./00-download-iso.sh --url https://.../x.iso    # 下载任意镜像
./00-download-iso.sh --url URL --name my.iso    # 指定本地文件名
./00-download-iso.sh --print                    # 只打印 URL，不下载
```

## 关于 ISO

`04` 和 `05` 需要一个小镜像来启动演示用虚拟机。脚本按以下优先级查找已有镜像：

1. 环境变量 `KVM_ISO` 指定的文件；
2. `$KVM_ISO_DIR/alpine-virt.iso`（`00-download-iso.sh` 的默认输出）。

找不到时会直接提示你去运行 `./00-download-iso.sh`，不会自己下载。

Alpine 镜像小、启动快、走串口，非常适合做“跑起来看看”的演示。
也可以换成任意 Linux ISO：

```bash
KVM_ISO=/path/to/your.iso ./04-demo-vm-process.sh
```

## 设计原则

- **安全**：默认只读；会改系统的只有 `02`（且要 sudo + 确认）；
- **免 root**：`05` 默认用 `qemu:///session`，避开 SELinux 标签问题；
- **可重复**：所有演示在临时目录进行，退出时自动清理；
- **可中断**：非交互环境下 `confirm`/`pause` 自动跳过，方便放进 CI。

## 常见问题

**Q：`04`/`05` 报错 "缺少 qemu-system-x86_64"？**
先运行 `sudo ./02-setup-toolchain.sh`。

**Q：`05` 连不上 `qemu:///session`？**
确认已安装 `libvirt-daemon-kvm`，并尝试 `virsh -c qemu:///session version` 排查。

**Q：系统模式（`qemu:///system`）下 VM 起不来，SELinux 报错？**
把镜像放到 `/var/lib/libvirt/images/` 并 `restorecon`，或改用 session 模式（模块 10）。
