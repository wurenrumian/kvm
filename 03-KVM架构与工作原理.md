# 模块 03 · KVM 架构与工作原理

> 这是全课程的**原理核心**。跑通 VM 之后，回来把这层吃透，后面所有调优才有依据。

## 学习目标

- 讲清 CPU、内存、I/O 三类虚拟化各自怎么做；
- 理解 `/dev/kvm` 的 ioctl 接口与一次 VM-Exit 的完整路径；
- 掌握 VMCS 关键字段、VM-Entry/Exit 常见原因、`KVM_RUN` 生命周期、vCPU 线程模型；
- 理解 GVA→GPA→HPA 三级翻译与影子页表 / EPT-NPT 的差别；
- 看懂 virtqueue 结构、vhost 数据路径、中断虚拟化与 IOMMU；
- 知道 `-cpu host`、EPT、virtio、vhost 分别解决了什么；
- 能画出磁盘读 / 网络收发包的完整数据路径。

---

## 3.1 整体架构

```text
+---------------------------- 用户态 ----------------------------+
|  QEMU 进程                                                       |
|  +- vCPU 线程 -- ioctl(KVM_RUN) --+                             |
|  +- 设备模型（网卡/磁盘/显卡模拟）  |                             |
|  +- 块后端 / 网络后端              |                             |
|  +- 迁移/监控/生命周期              |                             |
+------------------------------------+----------------------------+
                                      | /dev/kvm（ioctl + mmap 共享页）
+-------------------------------------+----------------------------+
|  KVM 内核模块                        v                            |
|  +- CPU 虚拟化：VMCS/SVM、VM-Entry/Exit                          |
|  +- 内存虚拟化：EPT/NPT 二级页表、影子页表、MMU                  |
|  +- 中断虚拟化：APICv、irqfd、eventfd                            |
|  +- vhost：把数据面下沉到内核线程                                |
+------------------------------------------------------------------+
                                      |
+-------------------------------------+----------------------------+
|  硬件：VT-x/AMD-V、EPT/NPT、VT-d/AMD-Vi、APICv                   |
+------------------------------------------------------------------+
```

**核心循环**：vCPU 线程不断调用 `KVM_RUN`，CPU 进入 guest 执行；遇到需要
hypervisor 处理的事件（I/O、特权操作、中断）就 **VM-Exit** 回到内核，
内核再决定是"自己处理"还是"交给 QEMU 用户态处理"。

### KVM 源码地图

| 路径 | 内容 |
| --- | --- |
| `virt/kvm/kvm_main.c` | KVM 核心：VM/vCPU 创建、memslot、`KVM_RUN` 入口 |
| `virt/kvm/eventfd.c` | irqfd / ioeventfd 实现 |
| `virt/kvm/vfio.c` | VFIO 与 KVM 的桥接 |
| `arch/x86/kvm/x86.c` | x86 架构主体：ioctl、MSR/CPUID、vCPU 状态 |
| `arch/x86/kvm/vmx/` | Intel VMX：`vmx.c`（VM-Entry/Exit）、`vmcs.h`、`nested.c` |
| `arch/x86/kvm/svm/` | AMD SVM 对应实现 |
| `arch/x86/kvm/mmu/` | MMU：影子页表、EPT、页错误处理 |
| `arch/x86/kvm/lapic.c` | 虚拟 LAPIC |
| `arch/x86/kvm/irq_comm.c` | 中断路由（GSI → 中断） |
| `include/uapi/linux/kvm.h` | 用户态可见的 ioctl 定义、`struct kvm_run` |
| `Documentation/virt/kvm/api.rst` | KVM ioctl API 权威文档 |

> 目录名提示：老内核里是 `Documentation/virtual/kvm/`，新内核已更名为
> `Documentation/virt/kvm/`。查资料时两个都试。

---

## 3.2 CPU 虚拟化

### 3.2.1 VMX root / non-root 与 VMCS

Intel VT-x 把 CPU 分成两种执行环境：

```text
                 特权级
            Ring 0            Ring 3
   +------------------+------------------+
   |  VMX root        |  VMX root        |  <- KVM / 宿主机
   |  (hypervisor)    |  (QEMU 用户态)   |
   +------------------+------------------+
   |  VMX non-root    |  VMX non-root    |  <- guest
   |  (guest 内核)    |  (guest 用户态)  |
   +------------------+------------------+
```

- **VMX root**：hypervisor 运行态，拥有全部特权。
- **VMX non-root**：guest 运行态，行为受 VMCS 控制。
- 从 root 到 non-root 叫 **VM-Entry**，反向叫 **VM-Exit**。

每个 vCPU 关联一个 **VMCS（Virtual Machine Control Structure）**，
它是硬件规定的内存结构，按字段区域组织：

| 区域 | 作用 | 典型字段 |
| --- | --- | --- |
| Guest-state area | 保存 guest 的 CPU 状态 | guest RSP/RIP/RFLAGS、CR0/CR3/CR4、段寄存器、GDTR/IDTR、VMCS link pointer |
| Host-state area | VM-Exit 时恢复的宿主状态 | host CR3、host RSP/RIP、host 段寄存器 |
| VM-execution controls | 控制 guest 执行行为 | pin-based、primary/secondary processor-based、exception bitmap、MSR bitmaps、I/O bitmaps、**EPTP**（EPT 指针）、CR3 target count |
| VM-exit controls | 控制退出行为 | exit MSR 相关、VM-Exit 时保存/加载哪些 MSR |
| VM-entry controls | 控制进入行为 | 注入事件（中断/异常）、加载哪些 MSR |
| VM-exit information | 退出原因与现场 | exit reason、exit qualification、VM-instruction error、guest-linear address、guest-physical address |

几个必须记住的字段/机制：

- **EPTP**：指向 EPT 页表根，是内存虚拟化的入口。
- **Exception bitmap**：指定哪些异常要触发 VM-Exit（如缺页、一般保护）。
- **MSR bitmaps / I/O bitmaps**：哪些 MSR / 端口访问会退出。
- **CR3 target count / CR3 guest-host mask**：控制 guest 写 CR3 时是否退出，
  是影子页表与 VPID 优化的关键。
- **VMCS link pointer**：嵌套虚拟化时指向另一个 VMCS。

VMCS 不是普通内存，必须用 **VMREAD / VMWRITE** 指令访问。
KVM 在 `arch/x86/kvm/vmx/vmx.c` 里封装了 `vmcs_readl()`/`vmcs_writel()` 等。

### 3.2.2 VM-Entry / VM-Exit 常见原因

VM-Entry 用 **VMLAUNCH**（首次）或 **VMRESUME**（恢复）。常见 VM-Exit 原因：

| exit_reason（符号） | 典型场景 | KVM 处理 |
| --- | --- | --- |
| `EXIT_REASON_EXCEPTION_NMI` | guest 触发异常 / NMI | 按 exception bitmap 决定模拟或注入 |
| `EXIT_REASON_EXTERNAL_INTERRUPT` | 宿主机中断到达 | 注入 guest 或返回用户态 |
| `EXIT_REASON_CPUID` | guest 执行 `cpuid` | 按 vCPU 的 CPUID 模型模拟 |
| `EXIT_REASON_HLT` | guest 执行 `hlt` | 阻塞 vCPU，等中断唤醒 |
| `EXIT_REASON_IO_INSTRUCTION` | guest 访问 I/O 端口 | 交给用户态（`KVM_EXIT_IO`）或内核 |
| `EXIT_REASON_MSR_READ` / `MSR_WRITE` | guest 读写 MSR | 模拟或透传 |
| `EXIT_REASON_VMCALL` | guest 执行 `vmcall`（hypercall） | 处理 hypercall |
| `EXIT_REASON_EPT_VIOLATION` | EPT 缺页 / 权限违例 | 填充 EPT 或识别为 MMIO |
| `EXIT_REASON_EPT_MISCONFIG` | EPT 配置错误 | 通常是 bug，返回用户态 |
| `EXIT_REASON_PREEMPTION_TIMER` | 抢占定时器到期 | 调度相关 |
| `EXIT_REASON_CR_ACCESS` | guest 访问 CR0/CR3/CR4 | 模拟或放行 |
| `EXIT_REASON_APIC_ACCESS` | guest 访问 APIC MMIO | 虚拟 APIC 处理 |

> 具体数值由 Intel SDM 定义；实战里用 `perf kvm stat` 看按原因分类的统计最有价值。

一次 VM-Exit 的完整路径：

```text
 guest 执行敏感指令 / 访问 MMIO / 收到中断
        |
        v
 硬件按 VMCS 的 VM-execution controls 判定要退出
        |  保存 guest 状态到 VMCS，加载 host 状态
        v
 vmx_vcpu_run 返回 -> vmx_handle_exit
        |
        +- kvm_vmx_exit_handlers[exit_reason] 分发
        |
        +- 内核可处理：处理后回到 vcpu_enter_guest 循环，直接 VM-Entry
        |
        +- 必须用户态：填充 kvm_run.exit_reason -> KVM_RUN 返回
                          -> QEMU 处理 -> 再次 KVM_RUN
```

### 3.2.3 KVM_RUN 生命周期与 kvm_run

`KVM_RUN` 是 vCPU 的主循环，在用户态表现为一个**阻塞 ioctl**：

```text
QEMU vCPU 线程
  loop:
    ioctl(vcpu_fd, KVM_RUN, 0)
      |
      v  内核
    kvm_vcpu_ioctl(KVM_RUN)
      -> kvm_arch_vcpu_ioctl_run()
        -> vcpu_run() 循环:
            vcpu_enter_guest()
              -> vmx_vcpu_run()
                -> VMLAUNCH / VMRESUME   <- 进入 non-root
                <- VM-Exit
            vmx_handle_exit()  <- 内核态处理
            if 需要用户态: return 到用户态
    <- KVM_RUN 返回
    读 kvm_run.exit_reason，处理，再次 KVM_RUN
```

`struct kvm_run` 是 vcpu fd `mmap` 出来的一页共享内存（大小 `KVM_VCPU_MMAP_SIZE`），
用户态和内核都能读写，避免额外拷贝。核心字段：

| 字段 | 作用 |
| --- | --- |
| `request_interrupt_window` | 请求"中断窗口"退出 |
| `immediate_exit` | 让 KVM_RUN 立刻返回（用于信号 / 踢出 vCPU） |
| `exit_reason` | 本次退出的原因（`KVM_EXIT_*`） |
| `ready_for_interrupt_injection` | 是否可注入中断 |
| `if_flag` | 退出时的 IF |
| `cr8` | 退出时的 CR8（TPR） |
| `apic_base` | APIC 基址 |
| `kvm_valid_regs` / `kvm_dirty_regs` | 同步寄存器 |
| union（`io`/`mmio`/`hypercall`/`fail_entry`/`internal_error`/`system_event`…） | 各退出类型的细节 |

用户态可见的 `KVM_EXIT_*` 常见值：

| `KVM_EXIT_*` | 含义 | QEMU 做什么 |
| --- | --- | --- |
| `KVM_EXIT_IO` | guest 访问 I/O 端口 | 模拟端口设备，回填数据 |
| `KVM_EXIT_MMIO` | guest 访问 MMIO | 模拟设备寄存器 |
| `KVM_EXIT_HLT` | guest 执行 hlt | 等待事件 / 中断 |
| `KVM_EXIT_SHUTDOWN` | guest 关机 / 三连异常 | 结束或复位 |
| `KVM_EXIT_INTR` | 被信号打断 | 处理信号后重试 |
| `KVM_EXIT_FAIL_ENTRY` | VM-Entry 失败 | 打印硬件错误码 |
| `KVM_EXIT_INTERNAL_ERROR` | KVM 内部错误 | 报 bug / 复位 |
| `KVM_EXIT_HYPERCALL` | hypercall | 处理 |
| `KVM_EXIT_X86_RDMSR` / `WRMSR` | 需要用户态处理的 MSR | 模拟 |

> 结论：**不是每次 VM-Exit 都回用户态**。内核能处理的（EPT violation、
> APIC 访问、中断注入）会直接在 `vcpu_run` 循环里再进 guest。
> 回用户态的次数越少，性能越好——这是后面所有优化的主线。

### 3.2.4 vCPU 线程模型

- 一个 vCPU = **宿主机上的一个线程**（`KVM_CREATE_VCPU` 创建 vcpu fd，
  QEMU 为每个 fd 起一个线程跑 `KVM_RUN`）。
- 线程被 Linux 调度器（CFS/EEVDF）当作普通线程调度，所以能 pin、能设优先级、
  能受 cgroup 限制——这直接引出模块 08 的 CPU 调优。
- 需要从用户态"踢出"正在 guest 里跑的 vCPU 时，通常给该线程发信号，
  KVM 让 `KVM_RUN` 以 `KVM_EXIT_INTR` 返回。
- vCPU 线程大部分时间阻塞在 `KVM_RUN` 里，`ps` 看是 `S`/`R` 交替。

```bash
# 看 vCPU 线程
ps -eLf | grep '[q]emu-system'
# 线程名常见：CPU 0/KVM、CPU 1/KVM
ls /proc/$(pgrep -f qemu-system | head -1)/task/*/comm | head
```

### 3.2.5 `-cpu` 机制：CPUID、MSR 与模型

guest 看到的 CPU，是由用户态"喂"给它的 CPUID 结果和 MSR 初值决定的。

- QEMU/libvirt 通过 `KVM_GET_SUPPORTED_CPUID` 拿到宿主 KVM 支持的能力，
  裁剪后经 `KVM_SET_CPUID2` 写入 vCPU。
- guest 执行 `cpuid` → VM-Exit（`EXIT_REASON_CPUID`）→ KVM 用 vCPU 的
  CPUID 表返回，所以**可以任意伪装 CPU**。

| 模式 | 行为 | 优点 | 缺点 |
| --- | --- | --- | --- |
| `host-passthrough`（`-cpu host`） | 直接透传宿主 CPUID（含新特性） | 性能最好、支持嵌套 | 跨异构宿主不可迁移 |
| `host-model` | 按宿主 + libvirt CPU 基线自动裁剪 | 兼顾性能与迁移 | 仍有少量兼容差异 |
| `custom`（`-cpu qemu64,+ssse3`） | 手工指定特性集合 | 完全可控、可迁移 | 需人工维护 |

libvirt 的 CPU 模型数据在 `/usr/share/libvirt/cpu_map/*.xml`，
`virsh domcapabilities` 能看到当前宿主可用的 model 与特性。

```bash
# 看 QEMU 认为宿主支持什么 CPU
qemu-system-x86_64 -cpu help | head
virsh domcapabilities | sed -n '/<cpu>/,/<\/cpu>/p' | head -40

# guest 内对照
grep -m1 'model name' /proc/cpuinfo
```

### 3.2.6 SMT 与拓扑

- 宿主的超线程（SMT）会作为额外的逻辑 CPU 暴露。guest 看到的拓扑由
  CPUID leaf `0xB`（或较新的 `0x1F`）和 leaf `4` 描述。
- `-smp 4,sockets=1,cores=2,threads=2` 或 libvirt 的
  `--vcpus 4,sockets=1,cores=2,threads=2` 会设置这个拓扑。
- 影响：guest 的调度器据此决定是否把两个 vCPU 当成同一物理核的兄弟线程；
  错误拓扑可能让 guest 做出糟糕的调度决策。
- 性能实践：把 vCPU pin 到宿主物理核（避免兄弟线程争抢），见模块 08。

---

## 3.3 内存虚拟化

### 3.3.1 三级地址：GVA → GPA → HPA

```text
 guest 里：进程访问虚拟地址
      |  guest 页表（CR3 指向）
      v
 GVA（Guest Virtual Address）
      |
      v
 GPA（Guest Physical Address）—— guest 以为的"物理地址"
      |  需要第二次翻译
      v
 HPA（Host Physical Address）—— 真正的内存条地址
```

问题：guest 自己维护 GVA→GPA 的页表，但 GPA→HPA 由 hypervisor 掌控。
两种做法：**影子页表** 和 **EPT/NPT**。

### 3.3.2 影子页表 vs EPT/NPT

```text
        影子页表（软件）                       EPT/NPT（硬件）
  +-----------------------+          +-----------------------+
  | 把 GVA->HPA 合成一张表  |          | GVA->GPA：guest 页表   |
  | 直接给硬件用            |          | GPA->HPA：EPT/NPT 页表 |
  | 拦截 guest 写 CR3/页表  |          | 两次翻译都在硬件里走   |
  | 需要同步（影子）        |          | 硬件缓存 TLB            |
  +-----------------------+          +-----------------------+
```

| 方案 | 原理 | 代价 |
| --- | --- | --- |
| 影子页表 | hypervisor 维护 GVA→HPA 合并映射，拦截 guest 页表写并同步 | 复杂、大量 VM-Exit、内存翻倍 |
| **EPT / NPT** | CPU 硬件做二级翻译：GVA→GPA→HPA | 几乎零额外开销（现代默认） |

**EPT（Intel）/ NPT（AMD）** 是性能关键。可用性检查：

```bash
grep -oE 'ept|npt' /proc/cpuinfo | head -1
```

二维页走查（2D page walk）示意：

```text
  GVA --guest 页表(4 级)--> GPA --EPT 页表(4 级)--> HPA
        每级都要读内存            每级都要读内存
  最坏情况：4 x 4 = 16 次额外内存访问 -> 靠 TLB / EPT TLB 缓存
```

- **VPID**：给每个 vCPU 一个 ID，VM-Entry/Exit 不必刷全部 TLB。
- **PCID**：进程上下文 ID，进一步减少 TLB 刷新。
- **EPT violation**（`EXIT_REASON_EPT_VIOLATION`）：EPT 里没有映射或权限不符时退出。
  KVM 的 MMU 代码（`arch/x86/kvm/mmu/`）决定是"缺页填充"还是"这是 MMIO"。
- **EPT misconfig**：EPT 配置本身非法，通常是内核 bug，会把错误抛给用户态。

### 3.3.3 MMU 与内存槽

- KVM 用 **memslot（内存槽）** 描述 guest 物理地址空间到宿主用户态内存的映射，
  用户态通过 `KVM_SET_USER_MEMORY_REGION` 注册（新版本还有 region2 变体）。
- QEMU 用 `mmap` 分配 guest RAM，然后把这段宿主虚拟地址交给 KVM；
  KVM 据此建立 EPT 映射。
- MMU 角色（`struct kvm_mmu_page`、role）决定一张页表能不能复用，
  角色变化会触发重建。
- 内存槽数量有上限（`KVM_CAP_NR_MEMSLOTS`），直通/热插拔会占用槽位。

### 3.3.4 KSM、Ballooning、HugePages

| 机制 | 做什么 | 代价/风险 | 适用 |
| --- | --- | --- | --- |
| **KSM** | 合并内容相同的页（写时复制） | 吃 CPU；侧信道风险（去重攻击） | 同质 VM 多、内存紧张 |
| **Ballooning** | guest 内驱动动态"充气/放气"回收内存 | 需 guest 驱动；回收有延迟 | 内存超分、弹性 |
| **HugePages** | 2MB/1GB 大页减少 TLB miss | 需预分配；可能浪费 | 内存密集、数据库 |

- **KSM（Kernel Same-page Merging）**：内核线程扫描并合并相同页。
  控制接口在 `/sys/kernel/mm/ksm/`（`run`、`pages_shared`、`pages_sharing`）。
  `ksmtuned` 服务按内存压力自动调节。
- **Ballooning**：guest 里的 `virtio-balloon` 驱动，宿主机 `virsh setmem`
  触发。宿主机想回收内存时让 balloon 膨胀，guest 归还页。
  新方向：**free page reporting**（guest 主动上报空闲页）。
- **HugePages**：两种——
  - 透明大页（THP）：内核自动合并，`/sys/kernel/mm/transparent_hugepage/`；
  - 显式大页（hugetlbfs）：`vm.nr_hugepages` 预分配，
    libvirt 用 `memoryBacking` + `hugepages` 指定。
  配合 EPT 大页映射，能显著降低 TLB 压力。

```bash
# KSM
cat /sys/kernel/mm/ksm/run
cat /sys/kernel/mm/ksm/pages_sharing

# 显式 2MB 大页
grep -i huge /proc/meminfo
# 预分配 2048 个 2MB 页 = 4GB
echo 2048 | sudo tee /proc/sys/vm/nr_hugepages

# 透明大页
cat /sys/kernel/mm/transparent_hugepage/enabled
```

---

## 3.4 I/O 虚拟化

I/O 是虚拟化开销最大的部分，演进路线：

```text
全模拟设备（e1000/IDE）-> virtio 半虚拟化 -> vhost 内核加速 -> vhost-user -> 硬件直通
   兼容好、慢            快、需驱动        更快          用户态加速     接近原生
```

### 3.4.1 virtio 与 virtqueue

**virtio** 是一套标准化的半虚拟化设备接口：guest 装 virtio 驱动，
与后端通过共享内存中的 **virtqueue** 通信，避免逐寄存器模拟真实硬件。

split virtqueue 的三个部分：

```text
 +------------------- Descriptor Table（描述符表）-------------------+
 | desc[0]: addr,len,flags(NEXT/WRITE/INDIRECT),next                 |
 | desc[1]: ...                                                       |
 | ...                                                                |
 +--------------------------------------------------------------------+
 +------------ Available Ring（guest -> 后端，我准备好了）-------------+
 | flags | idx | ring[]: 指向 desc 的下标                            |
 +--------------------------------------------------------------------+
 +------------ Used Ring（后端 -> guest，我用完了）--------------------+
 | flags | idx | ring[]: {id, len}                                   |
 +--------------------------------------------------------------------+
```

- guest 把请求放进 descriptor table，把下标写进 avail ring，更新 `avail->idx`，
  再"敲铃"（写设备 MMIO doorbell / `Queue Notify`）。
- 后端处理完，把结果写进 used ring，更新 `used->idx`，再给 guest 发中断。
- 关键 feature bit：`VIRTIO_F_VERSION_1`（现代设备）、
  `VIRTIO_RING_F_INDIRECT_DESC`（间接描述符，支持大请求）、
  `VIRTIO_RING_F_EVENT_IDX`（中断抑制，减少中断风暴）、
  `VIRTIO_F_ACCESS_PLATFORM`（需要 DMA/IOMMU 支持）。
- 新版还有 **packed virtqueue**（`VIRTIO_F_RING_PACKED`），结构更紧凑。

设备类型：

| 设备 | 队列 | 用途 |
| --- | --- | --- |
| `virtio-blk` | 单队列（可多队列） | 简单块设备，性能好 |
| `virtio-scsi` | 多队列 + 多设备 | 支持 SCSI 语义、热插拔、多盘 |
| `virtio-net` | rx/tx 多队列 + ctrl | 网卡，支持多队列 |
| `virtio-balloon` | 控制队列 | 内存回收 |
| `virtio-fs` | 多队列 | 共享文件系统 |
| `virtio-vsock` | — | 宿主 guest 套接字 |

### 3.4.2 vhost 数据路径

**vhost** 把 virtio 的**数据面**从 QEMU 用户态下沉到内核线程，减少上下文切换与拷贝。

```text
              QEMU 进程                        内核
  +---------------------------+      +--------------------------+
  | 控制面：设置 virtqueue 地址 |      | vhost 内核线程            |
  | 通过 ioctl 交给 vhost       |----->|  直接从 guest 内存取请求  |
  |                            |      |  直接读写 tap/镜像 fd     |
  +---------------------------+      +--------------------------+
```

- `vhost-net`：网卡版本（`drivers/vhost/vhost_net.c`），通常自动启用。
- `vhost-scsi`：SCSI 版本。
- `vhost-vsock`：套接字版本。
- 数据面用 **eventfd** 做通知：guest 敲铃 → `ioeventfd` 唤醒 vhost 线程；
  vhost 完成 → `irqfd` 注入中断。
- **vhost-user**：数据面放到独立用户态进程（OVS-DPDK、SPDK、virtiofsd），
  用 Unix socket 传控制、共享内存 + eventfd 传数据，适合高性能网络/存储。
- **vhost-vdpa**：对接支持 vDPA 的硬件。

### 3.4.3 IOMMU

- **IOMMU**（Intel VT-d / AMD-Vi）给设备提供地址翻译与隔离：
  设备 DMA 的地址也要经过翻译与权限检查。
- **中断重映射**：MSI 中断也走 IOMMU，配合 posted interrupt。
- **iommu_group**：IOMMU 的隔离单位；同一 group 内的设备不能单独直通。
  `ACS`（Access Control Services）决定能否把 group 拆细。
- VFIO（`vfio-pci`）用 IOMMU 把设备安全地交给 guest（模块 07）。

```bash
# 查看 IOMMU 分组
for g in /sys/kernel/iommu_groups/*; do
  echo "== $g =="
  ls "$g/devices"
done
```

---

## 3.5 中断虚拟化

- 传统：guest 中断靠 QEMU 注入，每次都要 VM-Exit，开销大。
- **内核内 irqchip**（`KVM_CREATE_IRQCHIP`）：PIC/IOAPIC/LAPIC 在内核里虚拟，
  减少用户态往返。
- **APICv**（Intel）/ **AVIC**（AMD）：硬件虚拟化本地 APIC，
  用 virtual-APIC page + posted interrupt，进一步减少 VM-Exit。
- **irqfd / eventfd**：
  - `KVM_IRQFD` 把一个 eventfd 绑定到某个 GSI，事件触发时直接注入 guest 中断；
  - `KVM_IOEVENTFD` 把 eventfd 绑定到一段 MMIO/PIO，guest 访问时直接唤醒后端。
- **MSI/MSI-X**：消息信号中断，写一个特定地址即触发中断；配合 vhost 实现高性能。
  中断路由通过 `KVM_SET_GSI_ROUTING` 配置。
- **posted interrupt**（VT-d PI）：直通设备的中断可绕过 hypervisor 直接投递，
  是 VFIO + 高性能网络的关键。

```text
 设备/后端完成 --eventfd--> irqfd --> KVM 注入 --> guest 中断处理
 guest 敲铃 ----MMIO 写--> ioeventfd --> 唤醒 vhost/后端（不返回 QEMU）
```

---

## 3.6 完整数据路径时序

### 3.6.1 磁盘读（virtio-blk + vhost）

```text
 guest 应用 read()
   |
   v
 guest VFS -> 块层 -> virtio_blk 驱动
   |  1. 在 descriptor table 填请求（header + data buffer + status）
   |  2. 下标写入 avail ring，avail->idx++
   |  3. 写 virtio-blk MMIO doorbell（Queue Notify）
   v
 KVM：EPT violation / MMIO 退出 -> ioeventfd 触发
   |
   v
 vhost 内核线程被唤醒
   |  4. 从 guest 内存读取描述符
   |  5. 直接 read() 镜像文件（或块设备）
   |  6. 数据写回 guest 的 data buffer
   |  7. 更新 used ring，used->idx++
   |  8. irqfd 注入中断
   v
 guest 中断处理 -> virtio_blk 完成回调 -> 唤醒应用
```

对照：不走 vhost 时，第 4~8 步由 QEMU 用户态完成（走 QEMU 的块后端
`io_uring`/线程池），上下文切换更多。

### 3.6.2 网络收包（宿主 → guest）

```text
 物理 NIC 收包
   |
   v
 宿主机内核网络栈
   |
   v
 tap 设备（tun/tap）
   |
   v
 vhost_net 内核线程
   |  1. 从 guest virtio-net 的 rx virtqueue 取空闲 buffer
   |  2. 把数据拷进 guest 内存
   |  3. 更新 used ring
   |  4. irqfd / posted interrupt 注入中断
   v
 guest virtio-net 驱动 -> NAPI poll -> 协议栈 -> 应用
```

### 3.6.3 网络发包（guest → 宿主/外网）

```text
 guest 应用 send()
   |
   v
 guest 协议栈 -> virtio-net tx queue
   |  1. 填 descriptor + avail ring
   |  2. 敲铃（ioeventfd）
   v
 vhost_net 内核线程
   |  3. 取出请求
   |  4. write() 到 tap fd
   v
 宿主机网络栈 -> 物理 NIC -> 外网
```

关键结论：

- 从 guest 看，virtio 设备就是一块普通网卡/磁盘；
- 从宿主看，数据面尽量不进 QEMU 用户态（vhost）；
- 优化方向永远是：**减少 VM-Exit、减少上下文切换、减少拷贝**。

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
# 有 KVM 加速
time qemu-system-x86_64 -accel kvm -cpu host -m 512 -nographic -kernel ...
# 去掉加速（TCG）再跑一次，感受差距
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

**实验 3-5：观察 vhost 与内核线程**

```bash
# VM 运行中
lsmod | grep -E 'vhost|tap|tun'
ps -eLo comm | grep -i vhost
```

**实验 3-6：大页与 KSM 状态**

```bash
grep -i huge /proc/meminfo
cat /sys/kernel/mm/ksm/run /sys/kernel/mm/ksm/pages_sharing
```

---

## 排错指南

| 现象 | 根因 | 定位命令 | 处理 |
| --- | --- | --- | --- |
| VM 极慢 | 没加 KVM 加速，走 TCG | `ps -ef \| grep qemu`（看有无 `-accel kvm`） | 加 `-accel kvm` |
| `-cpu host` 迁移失败 | 宿主 CPU 型号/特性不同 | `virsh domcapabilities` | 改 `host-model` 或自定义 model |
| guest 里缺 CPU 特性 | CPUID 被裁剪 | `grep flags /proc/cpuinfo`（guest 内） | 用 `host-passthrough` 或 `+feature` |
| 内存不足报错 | 未开 overcommit 或大页耗尽 | `grep -i huge /proc/meminfo; sysctl vm.overcommit_memory` | 调大页数 / 开 overcommit |
| I/O 瓶颈 | 用了模拟设备（e1000/IDE） | `virsh dumpxml \| grep -E 'model\|bus'` | 换 virtio / 开 vhost |
| 中断风暴 | 事件索引未启用 | `perf kvm stat` 看中断类退出 | 启用 `EVENT_IDX`；多队列 |
| 大量 EPT violation | 内存热插拔/直通频繁改映射 | `perf kvm stat report` | 预分配内存；少热插拔 |
| `KVM_EXIT_INTERNAL_ERROR` | KVM 内部 bug 或坏 CPUID | `dmesg; virsh dumpxml` | 升级内核/QEMU；简化 CPU model |
| `KVM_EXIT_FAIL_ENTRY` | VMCS 配置非法 | `dmesg` 看硬件错误码 | 检查 nested/CPU 特性组合 |
| 嵌套下性能差 | VM-Exit 双层放大 | `perf kvm stat live` | 减少陷入；别在生产多层嵌套 |
| KSM 吃满 CPU | 页合并扫描 | `cat /sys/kernel/mm/ksm/run` | 关闭 KSM |
| 大页分配失败 | 内存碎片 / 预留不足 | `grep Huge /proc/meminfo` | 开机预留 `hugepages=`；重启 |
| vhost 没启用 | 后端不支持 / 未配 | `lsmod \| grep vhost_net; virsh dumpxml` | 装 vhost 模块；确认 tap 后端 |
| 直通设备 DMA 失败 | IOMMU 未开 / 分组不对 | `dmesg \| grep -i iommu; ls /sys/kernel/iommu_groups` | 开 `intel_iommu=on`；查 ACS |

### 案例复盘

**案例 1：`perf kvm stat` 里全是 EPT violation。**
一台数据库 VM 吞吐上不去。`perf kvm stat report` 显示 EPT violation 异常多。
根因是 guest 内存被频繁热插拔/直通映射变动，导致 EPT 表反复重建。
定位：`perf kvm stat report` 按 exit 原因排序；对照 `virsh domstats` 内存变化。
处理：预分配固定内存、关闭不必要的内存热插拔与 balloon 抖动。
教训：**EPT 本身快，但映射频繁变化会让它退化成"每次都要填表"。**

**案例 2：`-cpu host` 的 VM 换机器后 guest 内核 panic。**
同一磁盘，从 A 机迁到 B 机，guest 启动即崩。
根因是 `host-passthrough` 透传了 B 机不支持的 CPUID 特性，
guest 里的内核按 A 机特性做了优化路径。
定位：两机 `virsh domcapabilities` 对比；guest `/proc/cpuinfo`。
处理：统一 `host-model`；或 `-cpu host,migratable=on`。
教训：**可迁移性和极限性能要提前权衡，别等迁移时才发现。**

**案例 3：`virsh console` 正常但网络巨慢，其实是中断走了用户态。**
某 VM 网络吞吐只有预期的 1/5。`perf kvm stat` 看到大量 I/O 退出。
根因是没用 vhost-net，每个包都要回 QEMU 用户态。
定位：`virsh dumpxml | grep -A5 interface` 看后端；`lsmod | grep vhost_net`。
处理：确认 tap 后端 + vhost 启用 + 多队列。
教训：**virtio 只是"半虚拟化"，真正的性能来自数据面下沉（vhost）。**

**案例 4：KSM 省了内存，却让延迟毛刺不断。**
开了 KSM 的宿主上，VM 的尾延迟周期性飙高。
根因是 KSM 扫描线程周期性占用 CPU，并触发写时复制。
定位：`cat /sys/kernel/mm/ksm/pages_sharing`、`perf top` 看 ksmd。
处理：对延迟敏感的 VM 关闭 KSM（`echo 0 > /sys/kernel/mm/ksm/run`）。
教训：**省内存的机制通常拿 CPU/延迟换，按负载取舍。**

---

## 练习

1. 用图描述一次磁盘读操作从 guest 到宿主机再返回的完整路径。
2. 为什么 `-cpu host` 性能最好却不利于迁移？libvirt 如何折中？
3. 解释 EPT 相比影子页表为什么能大幅降低开销。
4. 说明 `KVM_RUN` 为什么是阻塞的，以及什么情况下它会返回。
5. 画出 split virtqueue 的三部分结构，并说明 avail/used ring 各自的方向。
6. 解释 ioeventfd 与 irqfd 分别解决什么问题。

## 延伸阅读

- Intel SDM Vol.3：VMX 章节（VMCS / VM-Entry / VM-Exit 权威定义）
- AMD APM Vol.2：SVM 章节
- 内核源码：`arch/x86/kvm/`（含 `vmx/`、`svm/`、`mmu/`）、`virt/kvm/`
- `Documentation/virt/kvm/api.rst`（KVM ioctl API 权威文档）
- `Documentation/virt/kvm/`（含 nested、locking、halt-polling 等专题）
- virtio 规范：<https://docs.oasis-open.org/virtio/virtio/>
- vhost 内核文档：`Documentation/networking/vhost-net.rst`
