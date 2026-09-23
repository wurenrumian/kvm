# 模块 01 · 虚拟化基础与 KVM 定位

## 学习目标

- 说清"虚拟化"解决什么问题，以及有哪几种实现方式；
- 理解 KVM 在整套技术栈中的准确位置：它不是完整 hypervisor，而是内核里的一层能力；
- 能区分 Type-1 / Type-2、全虚拟化 / 半虚拟化、硬件辅助虚拟化。

---

## 1.1 虚拟化到底在虚拟什么

一台物理机的资源抽象为三类：**计算（CPU）、内存、I/O（设备/存储/网络）**。
虚拟化就是让多个"客户机（guest）"共享这些资源，且彼此隔离。

要实现它，必须解决三个核心问题：

1. **特权指令**：guest 的内核执行特权指令时怎么办？
2. **内存隔离**：guest 以为自己独占物理内存，实际是多者共享。
3. **设备访问**：guest 直接碰硬件会互相干扰，怎么安全地代劳？

后面模块 03 会看到，KVM 对这三个问题的答案分别是：
**VM-Exit 陷入 + 硬件辅助**、**EPT/NPT 二级地址翻译**、**virtio + QEMU 设备模型**。

## 1.2 虚拟化的分类

### 按 hypervisor 位置

| 类型 | 说明 | 例子 |
| --- | --- | --- |
| **Type-1（裸金属）** | 直接跑在硬件上 | KVM*、Xen、VMware ESXi、Hyper-V |
| **Type-2（宿主型）** | 跑在操作系统之上 | VirtualBox、VMware Workstation |

\* KVM 常被归为 Type-1，但严格说它是"内核内嵌"型：它复用 Linux 内核作为
hypervisor 底座，本身只提供虚拟化原语，设备模拟交给用户态的 QEMU。

### 按虚拟化程度

| 方式 | 原理 | 特点 |
| --- | --- | --- |
| **全虚拟化** | guest 无需修改，敏感指令靠二进制翻译/陷入模拟 | 兼容性好，开销略高 |
| **半虚拟化（paravirt）** | guest 主动配合，用 hypercall 代替敏感指令 | 性能好，需 guest 支持 |
| **硬件辅助** | CPU 提供 VT-x/SVM，直接切换执行环境 | 现代默认，性能与兼容兼得 |

现代 KVM = **硬件辅助全虚拟化 + 关键路径半虚拟化（virtio）** 的组合。

## 1.3 KVM 的准确定位

一条常被搞混的关系链：

```
用户敲命令
   │  virsh / virt-install / OpenStack
   ▼
libvirt（管理抽象层，产生 QEMU 命令行）
   │
   ▼
QEMU（用户态进程，设备模型 + 虚拟机生命周期）
   │  ioctl(/dev/kvm)
   ▼
KVM（内核模块：CPU/内存虚拟化）
   │
   ▼
硬件（VT-x / AMD-V / EPT）
```

关键认知：

- **KVM 不模拟设备**。网卡、磁盘、显卡这些由 QEMU 模拟。
- **QEMU 不虚拟化 CPU/内存本身**，它调用 KVM 完成。
- 所以叫 **QEMU/KVM** 才完整；单独说 KVM 时，通常指整套方案。
- 一个 guest 在宿主机上就是一个 **QEMU 进程**（外加若干 vCPU 线程、IO 线程）。

验证一下：

```bash
# 宿主机上每个正在运行的虚拟机 = 一个 qemu-kvm 进程
ps -eLf | grep qemu-system | head
```

## 1.4 为什么要用 KVM

| 优势 | 说明 |
| --- | --- |
| 开源、进主线内核 | 随 Linux 内核发布，无需额外驱动 |
| 性能接近原生 | 硬件辅助 + virtio，CPU 开销通常在个位数百分比 |
| 生态成熟 | libvirt / OpenStack / K8s / Proxmox 全覆盖 |
| 安全复用 | 直接吃 Linux 的安全模型（SELinux/AppArmor/cgroup） |

## 1.5 与容器的边界

| 维度 | KVM（虚拟机） | 容器（Docker/LXC） |
| --- | --- | --- |
| 隔离单位 | 硬件级，独立内核 | 进程级，共享内核 |
| 启动时间 | 秒级 | 毫秒级 |
| 密度 | 几十~上百 | 成百上千 |
| 安全边界 | 强 | 较弱（共享内核） |
| 典型用途 | 异构 OS、强隔离、GPU 直通 | 微服务、CI、快速扩缩 |

> 想两者兼得 → **Kata Containers / Firecracker**（模块 12）。

---

## 动手实验

**实验 1-1：确认虚拟化能力**

```bash
# CPU 是否支持硬件虚拟化
grep -m1 -oE 'vmx|svm' /proc/cpuinfo   # vmx=Intel, svm=AMD

# 内核模块是否加载
lsmod | grep -E '^kvm'
# kvm_intel    ...  1 kvm
# kvm          ...  1 kvm_intel

# KVM 字符设备
ls -l /dev/kvm
# crw-rw-rw- 1 root kvm 10, 232 ... /dev/kvm
```

**实验 1-2：观察"VM 就是一个进程"**

```bash
# 先随便跑一个 VM（模块 02 会教），然后在宿主机：
ps -eLf | grep '[q]emu-system'
# 你会看到主线程 + 每个 vCPU 一个线程 + IO 线程
```

**实验 1-3：查看 KVM 内核模块信息**

```bash
modinfo kvm_intel | head -20
cat /sys/module/kvm_intel/parameters/nested   # 是否支持嵌套虚拟化（Y/N）
```

---

## 排错指南

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `/dev/kvm` 不存在 | BIOS 未开 VT-x/AMD-V，或模块未加载 | 进 BIOS 开启；`modprobe kvm_intel` |
| `grep vmx` 无输出 | CPU 不支持或已被禁用 | 换机器或在 BIOS 打开 |
| 模块加载失败 | 与 VirtualBox/Hyper-V 冲突 | 卸载冲突模块，或换裸机 |

---

## 练习

1. 用自己的话解释：为什么说"KVM 是 Type-1"又"不完全是"？
2. 画出从 `virsh start vm1` 到 vCPU 真正执行的调用链。
3. 举一个场景说明什么时候该用虚拟机而不是容器，反之亦然。

## 延伸阅读

- 内核文档：`Documentation/virtual/kvm/`（在 Linux 源码树中）
- QEMU 官方文档：<https://www.qemu.org/documentation/>
- libvirt 文档：<https://libvirt.org/docs.html>
