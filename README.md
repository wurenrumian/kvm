# KVM 虚拟化系统课程

> **环境基线**：Fedora 44 / Linux 7.2 / Intel VT-x（本机 `kvm_intel` 已加载，`/dev/kvm` 可用）
> **课程位置**：`/home/rumian/kvm`
> **写课原则**：每个模块 = 概念 → 原理 → 命令 → 实验 → 排错 → 练习。能动手的绝不止于理论。

---

## 在线文档站

课程同时提供 Astro + Starlight 构建的文档站，带侧边栏导航和全文搜索：

- 线上：<https://wurenrumian.github.io/kvm/>
- 源码：`site/`
- 本地预览：`cd site && npm install && npm run dev`

站点内容由根目录 Markdown 自动同步生成（`site/scripts/sync-docs.mjs`），无需维护两份内容。

---

## 一、这套课程是什么

面向"有 Linux 基础、想把 KVM 从会用到讲得清"的工程师。它不走学术路线，而是围绕
**一条主线**：从一台裸机到能生产可用的虚拟化平台，中间每一层（CPU、内存、I/O、存储、
网络、迁移、安全、性能）都讲清楚"为什么这么设计"和"怎么调、怎么排错"。

## 二、适合人群与前置知识

| 需要会 | 不需要 |
| --- | --- |
| Linux 命令行、进程/内存/网络基本概念 | 内核开发经验 |
| 会看 `dmesg`、`journalctl`、`systemctl` | 汇编 / 硬件电路 |
| 基本 shell 脚本 | 已装好的虚拟化平台 |

## 三、学习目标

学完你能做到：

1. 用 QEMU 手写命令和 libvirt 两种方式创建、管理虚拟机；
2. 讲清 KVM 的 CPU/内存/I/O 虚拟化原理与关键数据结构；
3. 设计虚拟机的存储与网络方案，并做性能调优；
4. 独立完成在线迁移、快照、备份与故障恢复；
5. 用 sVirt / SELinux / Secure Boot / vTPM 加固虚拟机；
6. 用 `perf kvm`、`kvm_stat`、`virsh domstats` 定位性能与故障问题。

## 四、课程结构

| # | 模块 | 主题 | 建议学时 | 难度 |
| --- | --- | --- | --- | --- |
| 00 | [课程总览](README.md) | 大纲、环境准备、学习方法 | 0.5h | ★ |
| 01 | [虚拟化基础与 KVM 定位](01-虚拟化基础与KVM定位.md) | 虚拟化分类、KVM 在栈中的位置 | 1.5h | ★ |
| 02 | [环境搭建与第一台虚拟机](02-环境搭建与第一台虚拟机.md) | 装 QEMU/libvirt、跑通第一台 VM | 2h | ★★ |
| 03 | [KVM 架构与工作原理](03-KVM架构与工作原理.md) | CPU/内存/I/O 虚拟化、ioctl、VM-Exit | 3h | ★★★ |
| 04 | [libvirt 与虚拟机生命周期管理](04-libvirt与虚拟机生命周期管理.md) | XML 域定义、virsh、快照、克隆 | 2.5h | ★★ |
| 05 | [存储虚拟化](05-存储虚拟化.md) | qcow2/raw/LVM/Ceph、cache 模式、快照 | 3h | ★★★ |
| 06 | [网络虚拟化](06-网络虚拟化.md) | bridge/NAT/macvtap/OVS/SR-IOV、vhost | 3h | ★★★ |
| 07 | [设备直通与 I/O 虚拟化](07-设备直通与IO虚拟化.md) | virtio、VFIO、IOMMU、GPU 直通 | 3h | ★★★★ |
| 08 | [性能调优](08-性能调优.md) | CPU pinning、NUMA、HugePages、io_uring | 3h | ★★★★ |
| 09 | [迁移与高可用](09-迁移与高可用.md) | 热迁移、post-copy、共享存储、HA | 2.5h | ★★★ |
| 10 | [安全与隔离](10-安全与隔离.md) | sVirt/SELinux、Secure Boot、vTPM、侧信道 | 2.5h | ★★★ |
| 11 | [监控与排障](11-监控与排障.md) | kvm_stat、perf kvm、domstats、trace | 2.5h | ★★★ |
| 12 | [高级主题与生态](12-高级主题与生态.md) | 嵌套虚拟化、SEV/TDX、KubeVirt、Firecracker | 2h | ★★★★ |
| 附 | [命令速查表](附录-命令速查表.md) | 常用命令一页纸 | 查阅 | — |

**总计约 32 学时**，可按下面两条路线走。

## 五、两条学习路线

**速通路线（约 1 周，目标：能独立搭平台）**
`01 → 02 → 04 → 05 → 06 → 09 → 附`

**系统路线（约 4 周，目标：讲得清 + 调得动）**
`01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11 → 12`

## 六、实验环境准备（Fedora 44）

本机 CPU 已支持 Intel VT-x，`/dev/kvm` 已存在，只差用户态工具：

```bash
# 安装虚拟化套件（宿主机）
sudo dnf install -y qemu-kvm libvirt-daemon-kvm virt-install libguestfs-tools \
    virt-top bridge-utils guestfs-tools

# 启动并开机自启 libvirtd
sudo systemctl enable --now libvirtd

# 把自己加入 kvm/libvirt 组（重新登录生效）
sudo usermod -aG kvm,libvirt "$USER"

# 验证
ls -l /dev/kvm
systemctl is-active libvirtd
virsh list --all          # 应输出空列表且无报错
```

> 如果 `systemd-detect-virt` 显示你在虚拟机里（当前是 `none`，即裸机），
> 想做嵌套虚拟化实验需在 BIOS/宿主层开启嵌套支持，见模块 12。

## 六点五、配套演示脚本

`scripts/` 下有一套**可直接运行**的演示脚本，每个对应课程里的一个核心概念：

| 脚本 | 演示内容 | 模块 | 需要 root |
| --- | --- | --- | --- |
| `run-all.sh` | 一键：自检→安装→下载镜像→全部演示 | — | 安装步 |
| `00-download-iso.sh` | 下载演示镜像（独立脚本） | — | 否 |
| `01-check-env.sh` | 环境自检（只读） | 01/02 | 否 |
| `02-setup-toolchain.sh` | 安装配置工具链 | 02 | 是 |
| `03-demo-storage.sh` | 镜像格式/后备链/精简置备 | 05 | 否 |
| `04-demo-vm-process.sh` | 虚拟机就是一个进程 | 01/03 | 否 |
| `05-demo-vm-lifecycle.sh` | libvirt 生命周期管理 | 04 | 否 |
| `06-demo-network.sh` | 网桥/tap/NAT 数据通路 | 06 | 部分 |
| `07-demo-monitor-perf.sh` | kvm_stat/perf/domstats | 08/11 | 部分 |

```bash
cd scripts && chmod +x *.sh
./01-check-env.sh                  # 先自检
sudo ./02-setup-toolchain.sh       # 缺工具就装（装完重新登录）
./00-download-iso.sh               # 下载演示镜像（独立脚本）
./03-demo-storage.sh               # 然后逐个体验
./04-demo-vm-process.sh
./05-demo-vm-lifecycle.sh
```

或者一把梭：`./run-all.sh`（自检 → 安装 → 下载 → 全部演示 → 汇总）。

完整说明见 [`scripts/README.md`](scripts/README.md)。

## 七、每模块的统一结构

- **学习目标**：学完你能做什么
- **核心概念**：术语与心智模型
- **原理拆解**：机制、数据结构、关键路径
- **动手实验**：可直接复制的命令
- **排错指南**：常见报错与定位
- **练习**：检验掌握程度
- **延伸阅读**：内核文档 / 官方手册

## 八、学习方法建议

1. **先跑通再深挖**：模块 02 先让 VM 起来，有体感后再看模块 03 的原理。
2. **对照 `virsh dumpxml` 与 QEMU 命令行**：libvirt 的 XML 最终会翻译成 QEMU 参数，
   用 `ps -ef | grep qemu` 看真实命令行，理解映射关系。
3. **每学一层就压一次**：用 `stress-ng` / `fio` / `iperf3` 压测，观察宿主机指标。
4. **善用 `virsh edit` + `virsh define`**：XML 是 libvirt 的"唯一真相"。

---

准备好了就从 [模块 01](01-虚拟化基础与KVM定位.md) 开始。
