# 模块 03 · KVM 架构与工作原理

> 这是全课程的**原理核心**。跑通 VM 之后，回来把这层吃透，后面所有调优才有依据。

## 学习目标

- 讲清 CPU、内存、I/O 三类虚拟化各自怎么做；
- 理解 `/dev/kvm` 的 ioctl 接口与一次 VM-Exit 的完整路径；
- 知道 `-cpu host`、EPT、virtio、vhost 分别解决了什么。

---

## 3.1 整体架构

```
┌──────────────────────────── 用户态 ────────────────────────────┐
│  QEMU 进程                                                       │
│  ├─ vCPU 线程 ── ioctl(KVM_RUN) ──┐                             │
│  ├─ 设备模型（网卡/磁盘/显卡模拟）  │                             │
│  └─ 迁移/监控/生命周期              │                             │
└────────────────────────────────────┼────────────────────────────┘
                                      │ /dev/kvm
┌─────────────────────────────────────┼────────────────────────────┐
│  KVM 内核模块                        ▼                            │
│  ├─ CPU 虚拟化：VMCS/SVM、VM-Entry/Exit                          │
│  ├─ 内存虚拟化：EPT/NPT 二级页表                                  │
│  └─ 中断虚拟化：APICv、irqfd                                      │
└──────────────────────────────────────────────────────────────────┘
```

**核心循环**：vCPU 线程不断调用 `KVM_RUN`，CPU 进入 guest 执行；遇到需要
hypervisor 处理的事件（I/O、特权操作、中断）就 **VM-Exit** 回到内核，
内核再决定是"自己处理"还是"交给 QEMU 用户态处理"。

## 3.2 CPU 虚拟化

### 硬件辅助原理（Intel VT-x）

- CPU 有两种执行模式：**VMX root**（hypervisor）和 **VMX non-root**（guest）。
- 每个 vCPU 关联一个 **VMCS**（Virtual Machine Control Structure），保存
  guest 状态、宿主机状态、以及"哪些操作会触发 VM-Exit"的配置。
- guest 执行敏感指令 → 触发 **VM-Exit** → 陷入 KVM → 处理完 → **VM-Entry** 回到 guest。

### 关键点

- `-cpu host`（host-passthrough）把宿主机 CPU 特性直接透传给 guest，
  性能最好、支持嵌套，但**不利于跨不同型号宿主机的迁移**。
- `-cpu host-model` 是折中：libvirt 根据宿主机和基线自动裁剪，兼顾兼容与性能。
- **vCPU 就是宿主机上的一个普通线程**，由 Linux CFS 调度——这直接引出模块 08 的
  CPU pinning / NUMA 调优。

## 3.3 内存虚拟化

问题：guest 看到的是"guest 物理地址（GPA）"，而硬件要用"宿主机物理地址（HPA）"，
中间需要翻译。

| 方案 | 原理 | 代价 |
| --- | --- | --- |
| 影子页表 | hypervisor 维护 GPA→HPA 映射，拦截 guest 页表写 | 复杂、开销大 |
| **EPT / NPT** | CPU 硬件做二级翻译：GVA→GPA→HPA | 几乎零额外开销（现代默认） |

**EPT（Intel）/ NPT（AMD）** 是性能关键。可用性检查：

```bash
grep -oE 'ept|npt' /proc/cpuinfo | head -1
```

相关机制：

- **KSM（Kernel Same-page Merging）**：合并相同内存页，省内存但吃 CPU，且
  有侧信道风险（模块 10）。
- **HugePages**：用 2MB/1GB 大页减少 TLB miss，提升内存密集负载性能（模块 08）。
- **Ballooning**：guest 内驱动动态回收内存，宿主机按需调整。

## 3.4 I/O 虚拟化

I/O 是虚拟化开销最大的部分，演进路线：

```
全模拟设备（e1000/IDE）→ virtio 半虚拟化 → vhost 内核加速 → vhost-user → 硬件直通
   兼容好、慢            快、需驱动        更快          用户态加速     接近原生
```

- **virtio**：guest 装 virtio 驱动，与 hypervisor 用共享环（virtqueue）通信，
  避免模拟真实硬件寄存器。磁盘用 `virtio-blk`/`virtio-scsi`，网卡用 `virtio-net`。
- **vhost**：把 virtio 的数据面从 QEMU 用户态下沉到内核线程，减少上下文切换。
  `vhost-net` 是网卡版本，通常自动启用。
- **vhost-user**：数据面放到独立用户态进程（如 DPDK/OVS），适合高性能网络。
- **VFIO 直通**：把整块物理设备给 guest 独占，性能接近原生（模块 07）。

## 3.5 中断虚拟化

- 传统：guest 中断靠 QEMU 注入，开销大。
- **APICv**：硬件虚拟化本地 APIC，减少 VM-Exit。
- **irqfd / eventfd**：让设备中断直接投递给 guest，绕过用户态。
- **MSI/MSI-X**：消息信号中断，配合 vhost 实现高性能。

---

## 动手实验

**实验 3-1：观察 VM-Exit 频率**

```bash
# 需要 perf 和内核符号
sudo dnf install -y perf
sudo perf kvm stat live            # 实时看 VM-Exit 原因分布
# 或录制一段时间
sudo perf kvm stat record -a sleep 5
sudo perf kvm stat report
```

**实验 3-2：对比 KVM 与纯模拟的性能**

```bash
# 有 -enable-kvm
time qemu-system-x86_64 -enable-kvm -cpu host -m 512 -nographic -kernel ... 
# 去掉 -enable-kvm 再跑一次，感受差距
```

**实验 3-3：验证 EPT 与 vCPU 线程**

```bash
grep -m1 ept /proc/cpuinfo
# 起一台 2 vCPU 的 VM 后：
ps -eLf | grep '[q]emu-system' | awk '{print $2, $NF}'
```

**实验 3-4：查看 KVM 的 ioctl 接口（选做）**

```bash
# 查看内核暴露的 KVM 能力
cat /sys/module/kvm/parameters/* 2>/dev/null
# 读内核头文件了解 API（装 kernel-devel 后）
grep -n 'KVM_CREATE_VM\|KVM_RUN' /usr/include/linux/kvm.h | head
```

---

## 排错指南

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| VM 极慢 | 没加 `-enable-kvm`，纯软件模拟 | 加 `-enable-kvm` |
| `-cpu host` 迁移失败 | 宿主机 CPU 型号不同 | 改用 `host-model` 或自定义 model |
| 内存不足报错 | 未开 overcommit 或大页耗尽 | 检查 `vm.overcommit_memory`、HugePages |
| I/O 瓶颈 | 用了模拟设备 | 换 virtio / 开 vhost |

---

## 练习

1. 用图描述一次磁盘读操作从 guest 到宿主机再返回的完整路径。
2. 为什么 `-cpu host` 性能最好却不利于迁移？libvirt 如何折中？
3. 解释 EPT 相比影子页表为什么能大幅降低开销。

## 延伸阅读

- Intel SDM Vol.3：VMX 章节（了解 VMCS/VM-Exit 权威定义）
- 内核源码：`arch/x86/kvm/`、`virt/kvm/`
- `Documentation/virtual/kvm/api.rst`（KVM ioctl API 权威文档）
- `Documentation/virt/kvm/`（含 nested、locking 等专题）
