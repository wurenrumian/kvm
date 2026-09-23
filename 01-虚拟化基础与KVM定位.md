# 模块 01 · 虚拟化基础与 KVM 定位

## 学习目标

- 说清"虚拟化"解决什么问题，以及有哪几种实现方式；
- 掌握判断一个架构"能不能被虚拟化"的理论条件（Popek-Goldberg），
  并解释 x86 为什么曾经被判定为"不可虚拟化"；
- 理解 KVM 在整套技术栈中的准确位置：它不是完整 hypervisor，而是内核里的一层能力；
- 能区分 Type-1 / Type-2 / 内核内嵌，全虚拟化 / 半虚拟化 / 硬件辅助；
- 能画出从 `virsh start` 到 vCPU 真正执行的调用链；
- 能判断一个场景该用虚拟机、容器，还是两者融合。

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

但在讲"怎么实现"之前，先回答一个更根本的问题：
**什么样的 CPU 架构，原则上可以被虚拟化？**

### 理论基石：Popek-Goldberg 虚拟化条件

1974 年 Popek 和 Goldberg 在 *Formal Requirements for Virtualizable
Third Generation Architectures*（Communications of the ACM）中给出三条经典条件：

| 条件 | 英文 | 含义 |
| --- | --- | --- |
| **等价性 / 保真** | Fidelity / Equivalence | 在 VMM 上运行的程序，其可观察行为与在裸硬件上一致（允许时序和资源量差异） |
| **资源控制** | Safety / Resource Control | VMM 完全掌控所有系统资源，guest 无法绕过它直接访问 |
| **效率** | Performance / Efficiency | 绝大多数指令无需 VMM 干预，直接由硬件执行 |

此外还有一条决定"可行性"的**定理**：

> 一个架构是可虚拟化的，当且仅当**所有敏感指令都是特权指令**。

两个关键定义：

- **特权指令（privileged instruction）**：在非特权态（用户态）执行会触发陷入（trap）。
- **敏感指令（sensitive instruction）**：会读写特权资源、或行为依赖于特权状态的指令。
  它又分为：
  - **控制敏感**：改变系统资源状态（如修改页表基址、TLB、中断使能位）；
  - **行为敏感**：执行结果取决于资源状态（如读取 IDT/GDT 基址、读时钟）。

直观结论：如果一条敏感指令同时是特权指令，guest 执行它就会陷入 VMM，
VMM 就能"接管并模拟"。但如果存在**敏感但非特权**的指令，guest 就能在
不惊动 VMM 的情况下读到/改到本不该碰的状态，隔离被破坏，架构就不满足条件。

### x86 的特权级：Ring 0–3

传统 x86 提供四个特权级，操作系统只用其中的 Ring 0 和 Ring 3：

```text
        特权级（数值越小权限越高）
        +-------------------------------+
Ring 0  | 内核态：可执行全部指令、访问全部资源 |
Ring 1  | （分页/分段模型支持，现代 OS 不用） |
Ring 2  | （同上）                          |
Ring 3  | 用户态：受限，敏感操作触发 #GP/陷入 |
        +-------------------------------+
```

在"无硬件辅助"的年代，VMM 只能把自己塞进 Ring 0，把 guest 内核降级到
Ring 1（Xen 早期就用了 Ring 1/2），或让 guest 内核仍跑 Ring 0 但拦截敏感操作。
x86 的问题恰恰在于：**它有一批敏感指令在 Ring 3 执行不陷入**。

### 为什么 x86 一度"不可虚拟化"

Robin 与 Irvine 在 2000 年对 Pentium 的分析指出，x86 有若干条
**敏感但非特权**的指令（常被引用为 17 条），例如：

| 指令 | 类别 | 在 Ring 3 的问题 |
| --- | --- | --- |
| `sgdt` / `sidt` | 行为敏感 | 直接读到真实的 GDT/IDT 基址，泄露 VMM 状态 |
| `sldt` / `str` | 行为敏感 | 读到真实的任务寄存器/LDT |
| `smsw` | 行为敏感 | 读到真实机器状态字 |
| `pushf` / `popf` | 控制敏感 | `popf` 对 IF（中断使能）的修改在 Ring 3 被静默忽略而不陷入 |
| `lar` / `lsl` / `verr` / `verw` | 行为敏感 | 段权限检查结果基于真实状态 |

后果是致命的：guest 内核以为自己在独占 CPU，实际读到的是宿主机的状态；
VMM 也无法靠"等它陷入"来模拟，因为根本不陷入。

历史上对这条死路的三种绕法，正好对应了三种虚拟化流派：

1. **二进制翻译（Binary Translation）**：VMM 在运行时扫描并改写敏感指令，
   用等价的安全指令序列替换——VMware 早期 Workstation/ESX 的做法。
2. **半虚拟化（Paravirtualization）**：改 guest 内核源码，把敏感操作换成
   显式调用 VMM 的 **hypercall**——Xen 的经典路线。
3. **硬件辅助（Hardware Assist）**：CPU 厂商直接新增虚拟化扩展
   （Intel VT-x 2005、AMD-V/SVM 2006），用硬件定义"陷入"边界——KVM 的路线。

### 陷出与模拟：一次特权操作的旅程

无论哪种流派，核心机制都是 **trap-and-emulate（陷入—模拟）**：

```text
  guest 执行一条特权/敏感指令
        |
        v
  硬件产生陷入（#GP / VM-Exit）-----------------+
        |                                       |
        v                                       |
  VMM（KVM）接管，读取陷入原因与现场             |
        |                                       |
        +-- 内核态能处理：直接模拟后 VM-Entry 返回 -+
        |                                       |
        +-- 需要用户态：KVM_RUN 返回给 QEMU，      |
            QEMU 模拟设备/寄存器后再 KVM_RUN -----+
        |
        v
  guest 从"指令执行完"的假象中继续
```

要点：**陷入本身有成本**（VM-Exit/VM-Entry 各几百到上千周期）。
所以现代虚拟化设计的核心目标之一，就是"**能不进 VMM 就不进**"——
EPT/NPT、APICv、vhost、posted interrupt 都是在减少陷入。

---

## 1.2 虚拟化的分类

### 按 hypervisor 位置

| 类型 | 说明 | 例子 |
| --- | --- | --- |
| **Type-1（裸金属）** | 直接跑在硬件上 | Xen、VMware ESXi、Hyper-V、KVM* |
| **Type-2（宿主型）** | 跑在操作系统之上，作为普通应用 | VirtualBox、VMware Workstation、QEMU（无 KVM 时） |
| **内核内嵌型（hybrid）** | 作为通用 OS 内核的一部分，复用其调度/内存/驱动 | **KVM** |

\* KVM 常被归为 Type-1，但严格说它是"内核内嵌"型：它复用 Linux 内核作为
hypervisor 底座，本身只提供虚拟化原语，设备模拟交给用户态的 QEMU。
把它当 Type-1，是因为"guest 之下直接就是硬件，没有宿主 OS 这一层"；
说它不完全是，是因为"hypervisor 逻辑寄生在一个通用 OS 内核里，而非独立微内核"。

三者对比：

| 维度 | Type-1 独立 hypervisor | Type-2 宿主型 | 内核内嵌（KVM） |
| --- | --- | --- | --- |
| 代码位置 | 独立内核层 | 用户态进程 | 通用内核模块 |
| 调度/内存/驱动 | 自己实现 | 借宿主 OS | **直接复用 Linux** |
| 攻击面 | 较小（功能少） | 大（宿主 OS 全暴露） | 中（Linux 全暴露，但有 SELinux/cgroup） |
| 生态与驱动 | 需自建 | 依赖宿主 | 直接吃 Linux 驱动 |
| 代表 | Xen、ESXi | VirtualBox | KVM |

### 按虚拟化程度

| 方式 | 原理 | 优点 | 代价 |
| --- | --- | --- | --- |
| **全虚拟化** | guest 无需修改，敏感指令靠二进制翻译/陷入模拟 | 兼容任意未改 OS | 翻译/陷入开销 |
| **半虚拟化（paravirt）** | 改 guest，用 hypercall 代替敏感指令 | 性能好、路径短 | 需 guest 支持与配合 |
| **硬件辅助** | CPU 提供 VT-x/SVM，硬件切换执行环境 | 兼容 + 性能兼得 | 依赖 CPU 特性 |

现代 KVM = **硬件辅助全虚拟化 + 关键路径半虚拟化（virtio）** 的组合。
换句话说：CPU/内存走硬件辅助，I/O 走 virtio 半虚拟化，两条腿走路。

### 三维对照总表

| 方案 | 位置 | 程度 | 典型实现 |
| --- | --- | --- | --- |
| 全虚拟化 + 二进制翻译 | Type-2 | 全虚拟 | VMware Workstation（早期） |
| 半虚拟化 | Type-1 | 半虚拟 | Xen（PV 模式） |
| 硬件辅助全虚拟化 | 内核内嵌 | 全虚拟 | **KVM + QEMU** |
| 硬件辅助 + virtio | 内核内嵌 | 混合 | **KVM + virtio/vhost** |

---

## 1.3 KVM 的准确定位

一条常被搞混的关系链：

```text
用户敲命令
   |  virsh / virt-install / OpenStack
   v
libvirt（管理抽象层，产生 QEMU 命令行）
   |
   v
QEMU（用户态进程，设备模型 + 虚拟机生命周期）
   |  ioctl(/dev/kvm)
   v
KVM（内核模块：CPU/内存虚拟化）
   |
   v
硬件（VT-x / AMD-V / EPT）
```

关键认知：

- **KVM 不模拟设备**。网卡、磁盘、显卡这些由 QEMU 模拟。
- **QEMU 不虚拟化 CPU/内存本身**，它调用 KVM 完成。
- 所以叫 **QEMU/KVM** 才完整；单独说 KVM 时，通常指整套方案。
- 一个 guest 在宿主机上就是一个 **QEMU 进程**（外加若干 vCPU 线程、IO 线程）。

### KVM 是什么、不是什么

| 是 | 不是 |
| --- | --- |
| 一个内核模块（`kvm` + `kvm_intel`/`kvm_amd`） | 一个能独立运行的 hypervisor 产品 |
| 一个字符设备 `/dev/kvm` 及其 ioctl API | 一个设备模拟器（那是 QEMU 的活） |
| CPU/内存虚拟化 + 中断控制器/定时器虚拟化 | 一个完整的虚拟化管理平台（那是 libvirt） |
| Linux 调度器、内存管理、cgroup、SELinux 的复用者 | 自带调度器/内存管理器的独立内核 |

### 与 Xen 的架构差异

这是理解 KVM 定位最重要的一张图：

```text
            Xen（独立 hypervisor）              KVM（内核内嵌）
        +----------+ +----------+          +----------+ +----------+
        | guest A  | | guest B  |          | guest A  | | guest B  |
        | (PV/HVM) | |          |          |          | |          |
        +----+-----+ +----+-----+          +----+-----+ +----+-----+
             | hypercall  |                     | QEMU 进程  | QEMU 进程
        +----v------------v-----+          +----v------------v-----+
        |      Xen hypervisor    |          |    Linux 内核 + KVM    |
        |  自带调度/内存/中断管理 |          |  复用 CFS/mm/中断/驱动 |
        +------------------------+          +------------------------+
        |  Dom0（特权驱动域）     |          |  宿主机用户态（systemd）|
        |  DomU（普通 guest）     |          |  cgroup / SELinux      |
        +----------+-------------+          +----------+-------------+
                   v                                    v
        +----------------------------------------------------------+
        |                         硬件                              |
        +----------------------------------------------------------+
```

差异的实质：

| 维度 | Xen | KVM |
| --- | --- | --- |
| hypervisor 形态 | 独立微内核，guest 之下第一层 | Linux 内核的一个模块 |
| 驱动来源 | 需 Dom0 特权域 + 驱动后端 | 直接用 Linux 驱动栈 |
| 调度器 | Xen 自带（Credit/Credit2） | Linux CFS/EEVDF |
| 内存管理 | 自带 | Linux mm |
| 启动方式 | 先引导 Xen，再引导 Dom0 | 正常引导 Linux，`modprobe kvm_intel` |
| 生态 | 独立栈 | 完整 Linux 生态（libvirt/容器/云） |

一句话：**Xen 造了一个新内核来当 hypervisor；KVM 让 Linux 内核兼职当 hypervisor。**

### KVM 简史

- **2006 年**：Avi Kivity 在 Qumranet 公司发起 KVM 项目（Kernel-based Virtual Machine），
  最初只支持 Intel VT-x；同年 10 月公开。
- **2007 年 2 月**：KVM 合并进 **Linux 2.6.20** 主线，成为内核的一部分。
  这是 KVM 与 Xen 命运分岔的关键——它随内核一起发布，无需额外 hypervisor。
- **2008 年**：Red Hat 收购 Qumranet，KVM 成为 RHEL 的默认虚拟化方案，
  取代了此前的 Xen。
- 此后：AMD SVM 支持、virtio、vhost、EPT/NPT、APICv、VFIO、
  nested、SEV/TDX 等能力持续并入。

### QEMU/KVM 分工

| 职责 | KVM（内核） | QEMU（用户态） |
| --- | --- | --- |
| vCPU 执行与陷入 | 是 | 否 |
| 内存二级翻译 EPT/NPT | 是 | 否 |
| 中断控制器/定时器 | 是（in-kernel irqchip） | 可选 |
| 磁盘/网卡/显卡/USB 模拟 | 否 | 是 |
| 设备直通编排 | 部分（VFIO） | 是 |
| 虚拟机生命周期/迁移 | 否 | 是 |
| 块设备后端/网络后端 | vhost 加速 | 是 |

验证一下：

```bash
# 宿主机上每个正在运行的虚拟机 = 一个 qemu-kvm 进程
ps -eLf | grep qemu-system | head
```

---

## 1.4 为什么要用 KVM

| 优势 | 说明 |
| --- | --- |
| 开源、进主线内核 | 随 Linux 内核发布，无需额外驱动 |
| 性能接近原生 | 硬件辅助 + virtio，CPU 开销通常在个位数百分比 |
| 生态成熟 | libvirt / OpenStack / K8s / Proxmox 全覆盖 |
| 安全复用 | 直接吃 Linux 的安全模型（SELinux/AppArmor/cgroup） |
| 运维复用 | 调度、监控、存储、网络全是熟悉的 Linux 工具 |

反面（什么时候别硬上 KVM）：

- 只需要跑同内核的短生命周期任务 → 容器更轻。
- 极致密度的函数计算 → Firecracker/gVisor 这类专用 microVM。
- 需要比内核更强的隔离保证（多租户恶意代码）→ 机密计算（SEV/TDX）或独立硬件。

---

## 1.5 与容器的边界

| 维度 | KVM（虚拟机） | 容器（Docker/LXC） |
| --- | --- | --- |
| 隔离单位 | 硬件级，独立内核 | 进程级，共享内核 |
| 启动时间 | 秒级 | 毫秒级 |
| 密度 | 几十~上百 | 成百上千 |
| 安全边界 | 强 | 较弱（共享内核） |
| 资源抽象 | 虚拟硬件 | namespace + cgroup |
| 典型用途 | 异构 OS、强隔离、GPU 直通 | 微服务、CI、快速扩缩 |
| 逃逸难度 | 需突破 hypervisor | 内核漏洞即可逃逸 |

补充一张边界图：

```text
        虚拟机                                容器
  +------------------+                +------------------+
  |  App A |  App B  |                |  App A |  App B  |
  |  ------+-------- |                |  ------+-------- |
  |  Guest | Guest   |                |  共享内核         |
  |  Kernel| Kernel  |                +------------------+
  +--------+---------+                |  Host Kernel      |
  |  Hypervisor(KVM) |                +------------------+
  +------------------+                |  Host Kernel      |
  |  Host Kernel     |                +------------------+
  +------------------+
  |  Hardware        |
  +------------------+
```

### 何时选 VM / 容器 / 融合

| 需求 | 选择 |
| --- | --- |
| 跑 Windows / 异构内核 / 不同发行版内核 | **VM** |
| 强安全边界、多租户、PCI 直通 | **VM** |
| 秒级扩缩、高密度微服务 | **容器** |
| 既要容器体验又要 VM 隔离 | **Kata Containers**（轻量 VM 包容器） |
| 极致轻量 microVM（函数计算） | **Firecracker** |
| 用户态内核（syscall 拦截） | **gVisor** |

> 融合路线见模块 12。

---

## 1.6 从 virsh start 到 vCPU 执行

这是把"用户态—内核态—硬件"串起来的一张关键图，后面每个模块都会回看它。

```text
用户
 |  $ virsh start demo01
 v
virsh（libvirt-client，用户态）
 |  libvirt RPC over /run/libvirt/libvirt-sock
 v
virtqemud（Fedora modular daemon）/ libvirtd
 |  1. 读取 domain XML
 |  2. 生成 QEMU 命令行（-machine/-cpu/-device/-netdev ...）
 |  3. fork + exec qemu-system-x86_64
 v
qemu-system-x86_64（用户态进程）
 |  open("/dev/kvm")
 |  ioctl(KVM_GET_API_VERSION)
 |  ioctl(KVM_CREATE_VM)                 -> vm fd
 |  ioctl(KVM_SET_USER_MEMORY_REGION)    -> 注册 guest RAM（mmap 的宿主内存）
 |  ioctl(KVM_CREATE_IRQCHIP) / KVM_CREATE_PIT2
 |  ioctl(KVM_CREATE_VCPU) x N           -> vcpu fd x N
 |  mmap(vcpu fd, KVM_VCPU_MMAP_SIZE)    -> struct kvm_run 共享页
 v
每个 vCPU 一个宿主线程，循环：
 |  ioctl(vcpu_fd, KVM_RUN, 0)
 v
KVM 内核（kvm.ko / kvm_intel.ko）
 |  kvm_vcpu_ioctl -> kvm_arch_vcpu_ioctl_run
 |  -> vcpu_enter_guest -> vmx_vcpu_run
 |  -> VMLAUNCH / VMRESUME（VM-Entry）
 v
CPU 切到 VMX non-root，开始执行 guest 代码
 |  遇到敏感操作 / 中断 / I/O
 v
VM-Exit -> vmx_handle_exit 按 exit_reason 分发
 +- 内核能处理（EPT violation、APIC、HLT、MSR…）
 |    -> 处理后直接 VM-Entry，不返回用户态
 +- 需要用户态（KVM_EXIT_IO / KVM_EXIT_MMIO / KVM_EXIT_SHUTDOWN…）
      -> KVM_RUN 返回，kvm_run.exit_reason 告知 QEMU
      -> QEMU 模拟设备/寄存器，再次 KVM_RUN
```

对应的 ioctl 时序（简化）：

```text
QEMU                       KVM                     硬件
 | open /dev/kvm            |                        |
 | KVM_GET_API_VERSION ---->|                        |
 | KVM_CREATE_VM ---------->|                        |
 | KVM_SET_USER_MEMORY_REGION ->|                    |
 | KVM_CREATE_IRQCHIP ----->|                        |
 | KVM_CREATE_VCPU -------->|                        |
 | mmap(kvm_run) ---------->|                        |
 | KVM_RUN ---------------->| vcpu_enter_guest       |
 |                          | VMLAUNCH ------------->| non-root
 |                          |<------ VM-Exit --------|
 |<-- KVM_RUN 返回（exit_reason）                     |
 | 处理设备 I/O             |                        |
 | KVM_RUN ---------------->| VMRESUME ------------->|
```

关键点：

- `KVM_RUN` 是**阻塞**的：guest 不退出，调用就不返回。所以 vCPU 线程绝大部分时间
  停在这个 ioctl 里。
- 不是每次 VM-Exit 都回用户态。内核能自己搞定的（如缺页、中断注入）直接再进 guest，
  这是性能关键。
- `struct kvm_run` 是 QEMU 与 KVM 共享的一页内存，`exit_reason` 是二者的"暗号"。

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

# 确认自己是不是裸机（不是嵌套/容器）
systemd-detect-virt          # 期望：none
lscpu | grep -i hypervisor   # 期望：无输出
```

**实验 1-2：观察"VM 就是一个进程"**

```bash
# 先随便跑一个 VM（模块 02 会教），然后在宿主机：
ps -eLf | grep '[q]emu-system'
# 你会看到主线程 + 每个 vCPU 一个线程 + IO 线程

# 数一下线程总数（含 vCPU 线程）
ls /proc/$(pgrep -f qemu-system | head -1)/task | wc -l
```

**实验 1-3：查看 KVM 内核模块信息**

```bash
modinfo kvm_intel | head -20
cat /sys/module/kvm_intel/parameters/nested   # 是否支持嵌套虚拟化（Y/N）

# 看 KVM 支持哪些能力位/参数
ls /sys/module/kvm/parameters/
```

**实验 1-4：亲手触发一次"敏感指令"（选做）**

```bash
# sgdt 在用户态可执行且不陷入（这正是 x86 的老问题）
cat > /tmp/sgdt.c <<'EOF'
#include <stdio.h>
struct { unsigned short limit; unsigned long base; } __attribute__((packed)) d;
int main(void) {
    asm volatile("sgdt %0" : "=m"(d));
    printf("GDT base=0x%lx\n", d.base);
    return 0;
}
EOF
gcc -o /tmp/sgdt /tmp/sgdt.c && /tmp/sgdt
# 在裸机上它能读到宿主机 GDT 基址——若没有硬件辅助隔离，guest 也能这么读
```

---

## 排错指南

| 现象 | 根因 | 定位命令 | 处理 |
| --- | --- | --- | --- |
| `/dev/kvm` 不存在 | BIOS 未开 VT-x/AMD-V，或模块未加载 | `ls -l /dev/kvm; lsmod \| grep kvm` | 进 BIOS 开启；`modprobe kvm_intel` |
| `grep vmx` 无输出 | CPU 不支持、BIOS 禁用、或已在 VM 内 | `grep -m1 -oE 'vmx\|svm' /proc/cpuinfo; systemd-detect-virt` | 换机器 / 开 BIOS；嵌套见模块 12 |
| `modprobe kvm_intel` 失败 | 与其他 hypervisor 冲突（VirtualBox/Hyper-V/WSL2） | `dmesg \| tail; lsmod \| grep -E 'vbox\|hyperv'` | 卸载冲突模块或改用裸机 |
| `kvm` 已加载但 `kvm_intel` 不加载 | 固件占用 VT-x 或 BIOS 选项冲突 | `dmesg \| grep -iE 'kvm\|vmx'` | 关闭 BIOS 中冲突的虚拟化/安全选项 |
| `virsh` 报连接失败 | daemon 未起或用户无权限 | `systemctl status virtqemud.socket; id` | 启 socket；加入 `libvirt` 组 |
| 找不到 qemu 进程 | 用了 `qemu:///session` 或跑在容器里 | `ps -eLf \| grep qemu; virsh uri` | 确认连接 URI |
| `systemd-detect-virt` 返回 `kvm` | 当前就在虚拟机里 | `systemd-detect-virt; lscpu \| grep -i hypervisor` | 裸机才直通 `/dev/kvm`；嵌套需宿主开 |
| 嵌套已开仍起不来 | 嵌套下 EPT/VMCS 受限 | `cat /sys/module/kvm_intel/parameters/nested` | 用 `kvm_intel.nested=1`，别 `host-passthrough` 全透 |
| KSM 让 CPU 飙高 | 页合并持续扫描 | `cat /sys/kernel/mm/ksm/run` | `echo 0 > /sys/kernel/mm/ksm/run` |
| 以为 KVM 在模拟网卡 | 设备模型在 QEMU | `ps -ef \| grep qemu; lsmod \| grep vhost` | 排 I/O 问题看 QEMU/vhost，不是 KVM |
| 容器里跑 KVM 失败 | 容器缺 `/dev/kvm` 或权限 | `ls -l /dev/kvm; grep Cap /proc/self/status` | `--device /dev/kvm --security-opt seccomp=unconfined` |
| 迁移到异构 CPU 失败 | `host-passthrough` 透传了宿主特性 | `virsh domcapabilities` | 改 `host-model` 或自定义 CPU model |
| 嵌套下性能奇差 | 嵌套下 VM-Exit 双层放大 | `perf kvm stat live` | 减少陷入；生产避免多层嵌套 |

### 案例复盘

**案例 1：`/dev/kvm` 明明在，`-enable-kvm` 还是报错。**
某工程师在云主机里做实验，`ls /dev/kvm` 有，`lsmod | grep kvm` 也正常，
但 QEMU 报 `KVM not available`。根因是当前环境本身是嵌套虚拟机，
宿主层没开嵌套，`kvm_intel` 能加载但拿不到 VMX 的完整能力。
定位：`systemd-detect-virt` 返回 `kvm`，`dmesg` 里有 VMX 相关警告。
处理：在宿主层加 `kvm_intel.nested=1`，或换裸机。
教训：**`/dev/kvm` 存在不等于具备完整硬件辅助能力**。

**案例 2：同一份镜像，A 机能跑 B 机崩。**
把一台 `-cpu host` 的 VM 从 A 机迁到 B 机，guest 一启动就崩。
根因是 `host-passthrough` 把 A 机的 CPUID 特性（如某些 AVX/AMX 位）
透传给了 guest，B 机没有，guest 里编译/运行的代码走了不存在的指令。
定位：`virsh domcapabilities` 对比两机，或看 guest 里 `/proc/cpuinfo`。
处理：迁移场景统一用 `host-model` 或固定 `custom` model。
教训：**性能最优的 `host-passthrough` 与可迁移性是矛盾的**。

**案例 3：把 KVM 当完整 hypervisor，排错方向全错。**
有人抱怨"KVM 网卡性能差"，去查 KVM 内核模块，越查越远。
实际上网卡设备模型在 QEMU，数据面在 `vhost_net` 内核线程。
定位：`ps -ef | grep qemu` 看真实命令行，`lsmod | grep vhost`。
处理：优化方向是 virtio + vhost + 多队列，而不是 KVM 本身。
教训：**先搞清楚"这一层归谁管"，再排错。**

**案例 4：容器里跑 KVM 的权限坑。**
在 Docker 里做 KVM 实验，报 `Permission denied`。根因是容器默认
没有 `/dev/kvm`，且 seccomp 可能拦截 KVM 相关 ioctl。
定位：`ls -l /dev/kvm`、`grep Cap /proc/self/status`。
处理：`--device /dev/kvm`，必要时 `--security-opt seccomp=unconfined`，
并确保宿主开了嵌套。教训：**容器不是裸机，设备与权限要显式给。**

---

## 练习

1. 用自己的话解释：为什么说"KVM 是 Type-1"又"不完全是"？
2. 画出从 `virsh start vm1` 到 vCPU 真正执行的调用链，标出哪几步会阻塞。
3. 举一个场景说明什么时候该用虚拟机而不是容器，反之亦然。
4. 用 Popek-Goldberg 条件解释：为什么有了 VT-x 之后 x86 才算"可虚拟化"？
5. 说明"敏感指令"和"特权指令"的区别，各举一例。

## 延伸阅读

- 论文：Popek & Goldberg, *Formal Requirements for Virtualizable Third
  Generation Architectures*, CACM 1974
- 论文：Robin & Irvine, *Analysis of the Intel Pentium's Ability to Support a
  Secure Virtual Machine Monitor*, 2000
- 内核文档：`Documentation/virt/kvm/`（在 Linux 源码树中；旧路径 `Documentation/virtual/kvm/`）
- QEMU 官方文档：<https://www.qemu.org/documentation/>
- libvirt 文档：<https://libvirt.org/docs.html>
