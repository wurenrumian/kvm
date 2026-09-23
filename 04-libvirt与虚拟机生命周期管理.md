# 模块 04 · libvirt 与虚拟机生命周期管理

> 模块 03 讲的是 KVM 的内核机制；这一模块回到日常真正操作的那一层——libvirt。
> 目标不只是"会用 virsh"，而是能讲清 XML 为什么长这样、快照为什么不是备份、
> 状态机在背后做了什么，排错才有方向。

## 学习目标

- 讲清 libvirt 的分层架构：客户端库、RPC、守护进程、驱动模型；
- 说清 `qemu:///system` 与 `qemu:///session` 在权限、路径、能力上的差异；
- 读懂并手写完整域 XML（os/features/cpu/clock/devices/controller），理解 q35 与 i440fx 的取舍；
- 理解域状态机，以及每个生命周期操作背后真正发生了什么；
- 讲清内部快照 vs 外部快照、qcow2 覆盖层、`blockcommit`/`blockpull` 的原理与边界；
- 会用完整/链接克隆、`virt-customize`、备份 API、存储池/网络管理与批量自动化。

---

## 4.1 libvirt 的核心概念与架构

### 为什么需要 libvirt

直接用 QEMU 命令行的问题：参数极长、生命周期无人管、监控/迁移/存储/网络各自为政。
libvirt 把"管一台虚拟机"抽象成统一 API，向上给 `virsh`/`virt-manager`/OpenStack 用，
向下把请求翻译成 QEMU 命令行和内核接口。

```text
┌────────────────────────────────────────────────────────────────┐
│ 管理工具：virsh / virt-manager / virt-install / oVirt / OpenStack │
└───────────────────────────────┬────────────────────────────────┘
                                │ libvirt C API（libvirt.so）
┌───────────────────────────────▼────────────────────────────────┐
│ 客户端库：把 API 调用编码成 RPC 请求（XDR）                       │
└───────────────────────────────┬────────────────────────────────┘
                                │ UNIX socket / TCP+TLS / SSH
┌───────────────────────────────▼────────────────────────────────┐
│ 守护进程：virtqemud / virtnetworkd / virtstoraged …（modular）    │
│  ├─ 驱动层：qemu / lxc / xen / bhyve …                          │
│  └─ 通用层：域 / 网络 / 存储池 / 密钥 / 事件                      │
└───────────────────────────────┬────────────────────────────────┘
                                │ 拼装 QEMU 参数 / 调内核接口
┌───────────────────────────────▼────────────────────────────────┐
│ QEMU 进程 + /dev/kvm + KVM 内核模块                              │
└────────────────────────────────────────────────────────────────┘
```

核心概念表（保留并扩充）：

| 概念 | 说明 | 主要命令 |
| --- | --- | --- |
| **连接（Connection）** | 到某个 hypervisor 的通道，如 `qemu:///system` | `virsh -c` |
| **域（Domain）** | 一台虚拟机，状态由守护进程持有 | `virsh dom*` |
| **网络（Network）** | 虚拟网络（NAT/桥接/隔离） | `virsh net-*` |
| **存储池（Pool）** | 存储后端（目录/LVM/Ceph） | `virsh pool-*` |
| **卷（Volume）** | 池里的磁盘/镜像 | `virsh vol-*` |
| **接口（Interface）** | 宿主机物理/虚拟网卡 | `virsh iface-*` |
| **密钥（Secret）** | 加密盘、RBD 认证等敏感数据 | `virsh secret-*` |
| **检查点（Checkpoint）** | 增量备份的脏位图锚点 | `virsh checkpoint-*` |

### 驱动模型

libvirt 用"驱动"适配不同 hypervisor。每个驱动注册一个函数表（qemu 驱动的
`qemuDriver`，源码 `src/qemu/qemu_driver.c`），实现 `virDomainCreateXML`、
`virDomainDestroy`、`virDomainSnapshotCreateXML` 等回调。上层 API 名字与驱动回调
一一对应，因此"libvirt 报错"往往要先判断是哪一层的问题。

- XML 解析与校验：`src/conf/domain_conf.c`，产出 `virDomainDef`（域的"期望状态"）。
- 运行时对象：`virDomainObj` 存在 `virDomainObjList` 哈希表里，保存当前状态。
- 作业控制：`qemuDomainObjBeginJob` 给破坏性操作加锁，避免并发冲突。
- 事件：域生命周期、块设备、网卡变化通过事件回调推给客户端。

### RPC 与守护进程

客户端与守护进程之间是 libvirt 自己的 RPC 协议（XDR 编码，协议定义在
`src/remote/remote_protocol.x`）。默认走 UNIX socket，也可 TCP+TLS 或 SSH 隧道。

连接 URI 常用形式：

| URI | 传输 | 认证 | 场景 |
| --- | --- | --- | --- |
| `qemu:///system` | 本地 UNIX socket | polkit / libvirt 组 | 生产 |
| `qemu:///session` | 本地用户 socket | 无 | 开发、无 root |
| `qemu+ssh://host/system` | SSH 隧道 | SSH 密钥 | 远程管理（最常用） |
| `qemu+tls://host/system` | TCP + TLS | 证书 | 大规模集中管理 |
| `qemu+tcp://host/system` | TCP 明文 | SASL | 仅隔离网络，不推荐 |

> 老教材里的单体守护进程 `libvirtd`，在 libvirt 7.0 之后被 **modular daemons**
> 取代。Fedora 44 默认按需启动分进程守护进程；`libvirtd` 仍可作为单体模式运行，
> 但新部署应使用 modular。

| 守护进程 | 职责 | 监听 socket |
| --- | --- | --- |
| `virtqemud` | qemu 域的生命周期 | `/run/libvirt/virtqemud-sock` |
| `virtnetworkd` | 虚拟网络 | `virtnetworkd-sock` |
| `virtstoraged` | 存储池/卷 | `virtstoraged-sock` |
| `virtnodedevd` | 宿主机设备 | `virtnodedevd-sock` |
| `virtsecretd` | 密钥 | `virtsecretd-sock` |
| `virtnwfilterd` | 网络过滤器 | `virtnwfilterd-sock` |
| `virtinterfaced` | 宿主机网卡 | `virtinterfaced-sock` |
| `virtproxyd` | 统一入口，转发到各驱动进程 | `/run/libvirt/libvirt-sock` |
| `virtlogd` | 域日志轮转 | `virtlogd-sock` |
| `virtlockd` | 磁盘锁，防同一盘被两台宿主同时写 | `virtlockd-sock` |

好处：崩溃隔离（网络守护进程挂了不影响运行中的域）、最小权限（每个进程只开自己
需要的权限）、可独立重启。排查"连接不上"时，先看
`systemctl status virtqemud.socket`、`systemctl status virtproxyd.socket`。

### system vs session：差异不止权限

| 维度 | `qemu:///system` | `qemu:///session` |
| --- | --- | --- |
| QEMU 运行身份 | `qemu:qemu`（可在 `qemu.conf` 改） | 当前用户 |
| 域配置目录 | `/etc/libvirt/qemu/` | `~/.config/libvirt/qemu/` |
| 默认镜像目录 | `/var/lib/libvirt/images/` | `~/.local/share/libvirt/images/` |
| socket 路径 | `/run/libvirt/libvirt-sock` | `/run/user/$UID/libvirt/libvirt-sock` |
| 默认网络 | `default` NAT 可用 | 无 `default`，通常只能 `type='user'`（slirp） |
| 桥接/直通 | 支持 | 基本不可用 |
| LVM/iSCSI 池 | 支持 | 受限 |
| 认证 | polkit / `libvirt` 组 | 无 |
| 适用 | 生产、系统服务 | 开发、无 root、CI |

> 常见坑：普通用户 `virsh list` 看到空列表，不是没 VM，而是连到了
> `qemu:///session`。用 `virsh -c qemu:///system list --all`，或把用户加入
> `libvirt` 组并设置 `LIBVIRT_DEFAULT_URI`。

```bash
# 确认当前连接与默认 URI
virsh uri
echo "$LIBVIRT_DEFAULT_URI"
virsh -c qemu:///system list --all
virsh -c qemu:///session list --all

# 环境自检（检查内核模块、设备、权限）
virt-host-validate
```

## 4.2 域的 XML：完整结构与取舍

XML 是 libvirt 的"唯一真相"。`virsh dumpxml` 看到的最终形态是 libvirt 补全后的结果；
自己写的最小 XML 可以省略大量默认值。下面是一份带注释、覆盖主要元素的示例。

```xml
<domain type='kvm'>
  <name>web01</name>
  <uuid>...</uuid>
  <memory unit='MiB'>2048</memory>
  <currentMemory unit='MiB'>2048</currentMemory>
  <vcpu placement='static'>2</vcpu>

  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <!-- UEFI 启动：loader 为 OVMF 固件，nvram 保存变量 -->
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE.fd</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/web01_VARS.fd</nvram>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <hap/>
    <kvm><hidden state='on'/></kvm>
  </features>

  <cpu mode='host-passthrough' check='none'>
    <topology sockets='1' dies='1' cores='2' threads='1'/>
  </cpu>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='kvmclock' present='yes'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>

  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='io_uring' discard='unmap'/>
      <source file='/var/lib/libvirt/images/web01.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    <controller type='usb' index='0' model='qemu-xhci'/>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
      <driver name='vhost' queues='2'/>
    </interface>
    <serial type='pty'><target type='isa-serial'/></serial>
    <console type='pty'><target type='serial'/></console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <graphics type='spice' autoport='yes'/>
    <video><model type='virtio'/></video>
    <memballoon model='virtio'/>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
  </devices>
</domain>
```

主要元素速查：

| 元素 | 作用 | 常见取值 / 坑 |
| --- | --- | --- |
| `os/type` | 架构、机器类型、虚拟化类型 | `hvm`=硬件虚拟化；`machine` 见下表 |
| `loader` / `nvram` | UEFI 固件与变量存储 | 换固件后旧 nvram 可能启动失败 |
| `features` | ACPI/APIC/Hyper-V 等 | 老 OS 可能需 `hyperv` 兼容项 |
| `cpu mode` | CPU 型号透传策略 | `host-passthrough` 快但不便迁移 |
| `clock` | 时钟源与漂移策略 | Windows/高精度计时场景重点 |
| `on_poweroff` 等 | 关机/重启/崩溃动作 | `on_crash` 默认 `destroy`，HA 需改 |
| `devices/disk` | 磁盘与驱动参数 | `cache`/`io`/`discard` 见模块 05 |
| `controller` | 控制器拓扑 | virtio-scsi 支持更多队列/磁盘 |
| `channel` | guest agent 通道 | 缺它快照无法静默文件系统 |

**q35 与 i440fx 的取舍**：

| 维度 | `q35`（`pc-q35-*`） | `i440fx`（`pc-i440fx-*`） |
| --- | --- | --- |
| 总线 | PCIe 原生，根总线 `pcie.0` | 传统 PCI |
| 磁盘控制器 | 无 IDE，用 SATA/AHCI 或 virtio | 有 IDE |
| PCIe 直通/热插拔 | 支持良好 | 受限 |
| 老系统兼容 | 部分老 OS 不认 | 兼容最好 |
| 建议 | 新装 Linux/Windows 首选 | 老镜像、特定兼容需求 |

> `machine` 还可用带版本号的 `pc-q35-9.0` 之类锁定机器类型，保证**迁移时设备拓扑
> 一致**。迁移场景不要用模糊的 `q35`。

XML 校验与编辑：

```bash
# 校验一份 XML 是否符合 schema（RNG）
virt-xml-validate web01.xml

# 直接编辑运行中/已定义的域（保存退出即 define，可能需要重启域才生效）
virsh edit web01

# 用 virt-xml 做"单点修改"，不必手改整份 XML
virt-xml web01 --edit --vcpus 4
virt-xml web01 --edit --disk vda --disk cache=none
```

> 关键：`virsh edit` 改的是**持久配置**。很多改动对正在运行的域不生效，需要
> `virsh destroy && virsh start`；支持热插拔的设备可用 `attach-device`/
> `update-device` 在线生效。

## 4.3 域状态机与生命周期操作

libvirt 内部用一组状态描述域，`virsh domstate` 输出的就是它：

```text
                    ┌──────────────┐
   define ────────► │   shutoff    │ ◄──── destroy / 正常关机
                    └──────┬───────┘
                           │ start（创建 QEMU 进程，载入固件/内核）
                           ▼
   suspend ───────► ┌──────────────┐ ◄────── resume
                    │   running    │
                    └──┬────────┬──┘
        ACPI/guest 关机 │        │ 保存内存（managedsave / save）
                        ▼        ▼
                    shutoff    paused（blocked 也可能出现）
                                 │
                                 └─► restore / 自动恢复
```

| 状态 | 含义 | 典型进入方式 |
| --- | --- | --- |
| `running` | 正常运行 | `virsh start` |
| `blocked` | 运行但被阻塞（如 I/O 挂起） | 存储/网络异常 |
| `paused` | vCPU 暂停，内存保留 | `virsh suspend`、迁移中、`save` 后 |
| `shutdown` | guest 已发起关机、尚未退出 | guest 内 `poweroff` |
| `shutoff` | 已关闭 | `destroy`、正常关机完成 |
| `crashed` | guest 崩溃（配合 `on_crash`） | guest panic |
| `pmsuspended` | 电源管理挂起 | `virsh dompmsuspend` |

常用操作（保留原命令并扩充）：

```bash
virsh list --all                    # 列出所有域
virsh start web01                   # 启动
virsh shutdown web01                # ACPI 优雅关机（需 guest 支持）
virsh destroy web01                 # 强制断电（等于拔电源）
virsh reboot web01                  # 重启
virsh reset web01                   # 硬复位（不通知 guest）
virsh suspend web01                 # 暂停（内存保留）
virsh resume web01                  # 恢复
virsh autostart web01               # 宿主机启动时自动拉起
virsh autostart --disable web01     # 取消自启
virsh domstate web01                # 当前状态
virsh dominfo web01                 # 汇总信息
virsh dumpxml web01                 # 导出当前 XML
```

几个容易忽略但很实用的生命周期操作：

```bash
# 保存到磁盘并关机：内存写入文件，下次秒级恢复（适合长时间不用的域）
virsh managedsave web01
virsh dominfo web01 | grep -i saved     # 查看是否有 managed save 镜像
virsh start web01                       # 有 managed save 时会自动恢复

# 手动内存快照（save/restore）
virsh save web01 /data/web01.mem
virsh restore /data/web01.mem

# 电源管理挂起（需 guest 支持 ACPI S3）
virsh dompmsuspend web01 --target mem
virsh dompmwakeup web01

# 删除域：默认只删定义，不删磁盘
virsh undefine web01
virsh undefine web01 --remove-all-storage   # 连磁盘一起删（危险）
virsh undefine web01 --keep-nvram           # 保留 UEFI 变量
```

> `destroy` 不会丢配置，只是断电；`undefine` 才删定义。生产上误 `undefine` 后，
> 若 QEMU 进程还在运行，可在 destroy 之前用 `virsh dumpxml` 抢救回配置。

## 4.4 快照：原理与边界

### 两类快照

| 维度 | 内部快照 | 外部快照 |
| --- | --- | --- |
| 存放位置 | qcow2 文件**内部**的快照表 | 新建 qcow2 **覆盖层**文件 |
| 支持格式 | 仅 qcow2 | 任意（含 raw，靠覆盖层） |
| 是否含内存 | 可含（受格式/大小限制） | 可单独写内存文件 |
| 回滚速度 | 快 | 取决于覆盖层 |
| 与后端配合 | 受限 | 可与块设备、LVM 配合 |
| 生产建议 | 简单场景、临时回滚 | **推荐** |

```text
内部快照：                    外部快照（覆盖层）：
┌──────────────┐              base.qcow2（只读）
│  web01.qcow2 │              ┌──────────────┐
│ ┌──────────┐ │              │  原始数据     │
│ │  snap1   │ │              └──────┬───────┘
│ ├──────────┤ │                     │ backing file
│ │  snap2   │ │              snap1.qcow2（活跃盘，只写差异）
│ └──────────┘ │              ┌──────────────┐
│   当前数据    │              │  差异数据     │
└──────────────┘              └──────────────┘
```

外部快照的机制：libvirt 创建覆盖层后，把域的活跃盘从 base 切到 overlay，
此后所有写入落到 overlay，base 保持不变。这依赖 qcow2 的 **backing file**
（模块 05 详解）。

```bash
# 内部快照
virsh snapshot-create-as web01 snap1 "before upgrade"
virsh snapshot-list web01
virsh snapshot-info web01 snap1
virsh snapshot-revert web01 snap1
virsh snapshot-delete web01 snap1

# 外部快照（磁盘级）
virsh snapshot-create-as web01 ext1 "external" --disk-only --atomic
virsh domblklist web01                  # 观察活跃盘已指向 overlay

# 含内存的外部快照（需 guest agent 静默文件系统）
virsh snapshot-create-as web01 ext2 "with-mem" --disk-only \
  --memspec file=/data/web01.mem,snapshot=external --quiesce
```

> `--quiesce` 需要 guest 内的 `qemu-guest-agent`：它把文件系统刷盘并冻结，
> 否则快照可能处于"崩溃一致"状态，恢复后需要 fsck。

### blockcommit / blockpull：收敛覆盖层

覆盖层不能无限增长，否则后备链变长、性能下降，且 base 无法删除。

```bash
# blockcommit：把 overlay 的差异合并回 base（缩短链）
virsh blockcommit web01 vda --active --pivot --verbose
# --active：合并当前活跃层；--pivot：合并后把活跃盘切回 base

# blockpull：把 base 的数据拉进 overlay，让 overlay 独立（链变平）
virsh blockpull web01 vda --wait --verbose
virsh blockjob web01 vda --info          # 查看进度
virsh blockjob web01 vda --abort         # 中止
```

```text
blockcommit（合并回 base）         blockpull（拉平到 overlay）
base ◄── overlay1 ◄── active       base ◄── overlay1 ◄── active
        │                                   │
        └─ commit 后 base 吸收差异           └─ pull 后 active 含全部数据
```

> 快照**不是备份**：快照依赖 base 链，base 损坏或链断裂，快照一起丢。
> 快照只解决"回到某个时间点"，不解决"介质损坏 / 误删整个域"。

## 4.5 克隆：完整与链接

| 类型 | 磁盘处理 | 空间 | 适用 |
| --- | --- | --- | --- |
| **完整克隆** | 复制整块盘 | 大 | 独立生产实例 |
| **链接克隆** | 新建 qcow2，backing 指向模板 | 小、秒级 | 批量部署、临时环境 |

```bash
# 完整克隆：复制磁盘并生成新域
virt-clone --original web01 --name web02 \
  --file /var/lib/libvirt/images/web02.qcow2

# 自动生成克隆名与磁盘路径（仍是完整克隆）
virt-clone --original web01 --name web03 --auto-clone

# 链接克隆需要手工建覆盖层，再改 XML（virt-clone 不直接做链接克隆）
qemu-img create -f qcow2 -b /var/lib/libvirt/images/base.qcow2 \
  -F qcow2 /var/lib/libvirt/images/web04.qcow2
virsh dumpxml web01 > web04.xml
# 编辑 web04.xml：改 name/uuid、disk source、MAC 地址
virsh define web04.xml
```

> 纠错：`virt-clone --auto-clone` 只是**自动命名并做完整克隆**，并非链接克隆。
> 想要省空间的链接克隆，必须用 `qemu-img create -b` 手工建覆盖层。

克隆后必须处理的身份 / 配置：

- **MAC 地址**：libvirt 克隆时会生成新 MAC，但手工 `virsh define` 的克隆要自己改；
- **hostname / machine-id**：`/etc/machine-id` 重复会导致 DHCP 冲突、systemd 异常；
- **SSH 主机密钥**：模板复制的密钥相同，建议重新生成；
- **cloud-init / 首次启动脚本**：用于注入主机名、用户、密钥。

`virt-customize`（libguestfs）可在**离线**状态下改镜像：

```bash
virt-customize -a /var/lib/libvirt/images/web02.qcow2 \
  --hostname web02 \
  --root-password password:secret \
  --ssh-inject root:file:/root/.ssh/id_ed25519.pub \
  --run-command 'systemctl enable httpd' \
  --install nginx
```

把一台配好的 VM 变成可复用模板，用 `virt-sysprep` 做"密封"：

```bash
# 清 machine-id、hostname、SSH 主机密钥、日志、DHCP 租约等
virt-sysprep -a /var/lib/libvirt/images/template.qcow2 --operations defaults
```

## 4.6 备份：libvirt 备份 API

libvirt 6.0 起提供 `virDomainBackupBegin`（`virsh backup-begin`），做**块级、全量/
增量**备份，无需手工管覆盖层。核心概念是 **checkpoint**：用 qcow2 持久化脏位图记录
自上次检查点以来变化的簇，从而实现增量备份。

```xml
<domainbackup mode='push'>
  <disks>
    <disk name='vda' backup='yes' type='file'>
      <driver type='qcow2'/>
      <target file='/backup/web01-vda.qcow2'/>
    </disk>
  </disks>
</domainbackup>
```

```bash
# 全量备份（push：由 libvirt 写到目标文件）
virsh backup-begin web01 --backupxml backup.xml

# 增量备份：先建 checkpoint，再基于位图备份
virsh checkpoint-create-as web01 ckpt1 --diskspec vda
virsh backup-begin web01 --backupxml backup-incr.xml --checkpointxml ckpt2.xml
virsh checkpoint-list web01
virsh backup-dumpxml web01

# 查看备份作业
virsh domjobinfo web01
virsh domjobabort web01
```

传统"外部快照 + 拷盘"的备份方式仍然有效，但要注意一致性：

```bash
# 外部快照后拷贝 base，再 blockcommit 收回
virsh snapshot-create-as web01 bkp --disk-only --atomic --no-metadata
cp /var/lib/libvirt/images/web01.qcow2 /backup/
virsh blockcommit web01 vda --active --pivot   # 合并回原盘

# 离线备份（关机后，用 libguestfs 从镜像里取文件）
virt-copy-out -a /var/lib/libvirt/images/web01.qcow2 /etc/hosts /tmp/   # 需 libguestfs
```

> 备份三要素：**一致性**（quiesce 或关机）、**可恢复性**（定期演练 restore）、
> **异地**（不要和原盘放同一个存储）。快照 / 检查点都不能替代这三条。

## 4.7 存储池与网络管理

```bash
# 存储池
virsh pool-list --all
virsh pool-define-as mypool dir --target /data/vms
virsh pool-build mypool && virsh pool-start mypool && virsh pool-autostart mypool
virsh vol-create-as mypool disk1.qcow2 20G --format qcow2
virsh vol-list mypool
virsh vol-info --pool mypool disk1.qcow2
virsh vol-clone --pool mypool disk1.qcow2 disk2.qcow2   # 池内克隆
virsh vol-resize --pool mypool disk1.qcow2 30G          # 扩容
virsh vol-delete --pool mypool disk2.qcow2

# 网络
virsh net-list --all
virsh net-start default
virsh net-autostart default
virsh net-dumpxml default
virsh net-edit default
virsh net-dhcp-leases default            # 查看 DHCP 租约
virsh net-update default add ip-dhcp-host \
  '<host mac="52:54:00:aa:bb:cc" ip="192.168.122.50"/>' --live --config
```

存储池类型：`dir`、`fs`、`netfs`（NFS）、`logical`（LVM）、`disk`、`iscsi`、
`rbd`（Ceph）、`gluster`、`vstorage`、`zfs`。定义方式除了 `pool-define-as`，
也可以用 XML：

```xml
<pool type='logical'>
  <name>vg_vms</name>
  <source><name>vg0</name></source>
  <target><path>/dev/vg0</path></target>
</pool>
```

> `pool-define-as` 只是"登记"，`pool-build` 创建底层结构，`pool-start` 激活，
> `pool-autostart` 让宿主机启动时自动激活。四步缺一，重启后池会消失。

## 4.8 批量与自动化

```bash
# 批量操作所有域
for d in $(virsh list --name); do echo "== $d =="; virsh dominfo "$d"; done

# 只取运行中的域
virsh list --name --state-running

# 批量导出配置
mkdir -p /backup/xml
for d in $(virsh list --name --all); do
  virsh dumpxml "$d" > "/backup/xml/$d.xml"
done

# 用 virsh 脚本模式（从标准输入读命令）
virsh -c qemu:///system <<'EOF'
list --all
net-list
pool-list
EOF
```

更工程化的做法：

- 用 `virt-install --print-xml` 生成 XML，再程序化改字段后 `virsh define`；
- 用 `virsh --readonly` 做只读巡检，避免误操作；
- 用 Python `libvirt` 绑定或 Ansible `community.libvirt` 做编排；
- 用 `virsh list --all --name` 配合 `xargs -r virsh start` 批量开机。

```bash
# 只读巡检示例：拿所有域的块设备与网卡清单
virsh -r list --name | while read -r d; do
  echo "== $d =="; virsh domblklist "$d"; virsh domiflist "$d"
done
```

## 4.9 virsh 高级用法

```bash
# 向 guest 注入按键（BIOS 菜单、GRUB、登录界面调试）
virsh send-key web01 KEY_ENTER
virsh send-key web01 --codeset linux KEY_LEFTCTRL KEY_LEFTALT KEY_DELETE

# 直接调 QEMU monitor（QMP 或 HMP）
virsh qemu-monitor-command web01 --hmp 'info block'
virsh qemu-monitor-command web01 \
  '{"execute":"query-blockstats","arguments":{}}'

# 调用 guest agent（需 channel 已配且 agent 在跑）
virsh qemu-agent-command web01 '{"execute":"guest-info"}'
virsh domifaddr web01 --source agent      # 用 agent 拿 guest IP

# 事件：监听生命周期/块设备/网卡变化（写自动化脚本常用）
virsh event --list
virsh event --all --loop                  # 持续监听所有事件
virsh event --domain web01 --event lifecycle --loop

# 统计信息
virsh domstats web01
virsh domstats --block --interface web01
virsh domblkstat web01 vda
virsh domifstat web01 vnet0
virsh domcontrol web01                    # 查看监控通道状态
```

> 事件是"推送"模型，比轮询 `virsh list` 高效。做 HA / 自动拉起脚本时，用
> `virsh event --event lifecycle` 捕获 `stopped`/`crashed` 再触发动作。

---

## 动手实验

**实验 4-1：全 XML 定义一台 VM**
手写一份 XML（参考 4.2），用 `virsh define` 定义，`virt-xml-validate` 校验，
再 `virsh start`。对比 `virsh dumpxml` 看 libvirt 补全了哪些默认值。

**实验 4-2：快照与回滚**
装个包 → 打内部快照 → 删包 → 回滚 → 验证包又回来了。再用外部快照重复一遍，
用 `virsh domblklist` 观察活跃盘切换。

**实验 4-3：覆盖层收敛**
连续做 3 次外部快照，`qemu-img info --backing-chain` 看链长度，然后
`virsh blockcommit --active --pivot` 把链收敛回 base。

**实验 4-4：克隆并改身份**
克隆一台，进 guest 改 hostname 和 `/etc/machine-id`，验证网络正常。

**实验 4-5：用 virt-customize 批量改配置**

```bash
virt-customize -a /var/lib/libvirt/images/web02.qcow2 \
  --hostname web02 --root-password password:secret
```

**实验 4-6：监听域事件**
开一个终端跑 `virsh event --domain web01 --event lifecycle --loop`，
另一个终端对 web01 做 `suspend`/`resume`/`shutdown`，观察事件流。

---

## 排错指南

| 现象 | 根因 | 定位命令 | 处理 |
| --- | --- | --- | --- |
| `virsh list` 看不到 VM | 连到了 `qemu:///session` | `virsh uri` | 加 `-c qemu:///system`，或设 `LIBVIRT_DEFAULT_URI` |
| 普通用户操作 system 连接被拒 | 不在 `libvirt` 组 / polkit 未放行 | `id`、`journalctl -u virtqemud` | 加入 `libvirt` 组并重新登录 |
| `define` 报 XML 校验失败 | 元素顺序 / 必填项错误 | `virt-xml-validate x.xml` | 按 RNG 报错修正，注意子元素顺序 |
| `virsh edit` 后不生效 | 改的是持久配置，运行域未重载 | `virsh dumpxml` vs `dumpxml --inactive` | 热插拔用 `update-device`，否则重启域 |
| 快照创建失败 | 磁盘是 raw / 不支持内部快照 | `qemu-img info`、`virsh domblklist` | 转 qcow2 或用 `--disk-only` 外部快照 |
| 快照回滚后启动失败 | 后备链被破坏 / 中间层被删 | `qemu-img info --backing-chain` | 恢复缺失层，或从备份重建 |
| `--quiesce` 报错 | guest 没装 / 没跑 qemu-guest-agent | `virsh qemu-agent-command` | 安装并启用 guest agent |
| 克隆后网络不通 | MAC/hostname/machine-id 冲突 | `virsh domiflist`、guest 内 `ip a` | 重置 machine-id、重新生成 MAC |
| 克隆后磁盘冲突 | 两台域指向同一 qcow2 | `virsh domblklist` | 改用独立盘或链接克隆 |
| `blockcommit` 卡住 | 有作业在跑 / 链被占用 | `virsh blockjob <d> vda --info` | `--abort` 后重试，检查快照依赖 |
| 备份报不支持 | 磁盘格式 / 版本不支持位图 | `qemu-img info`、libvirt 版本 | 升级 libvirt，盘转 qcow2 并加位图 |
| 增量备份无数据 | 未创建 checkpoint | `virsh checkpoint-list` | 先 `checkpoint-create-as` 再备份 |
| `undefine` 后磁盘还在 | 默认不删存储 | `virsh vol-list` | 用 `--remove-all-storage`（谨慎） |
| 域起不来且无日志 | 守护进程 / 权限 / 磁盘锁问题 | `journalctl -u virtqemud`、`/var/log/libvirt/qemu/*.log` | 按日志定位，检查 `virtlockd` 锁 |
| 远程连接超时 | socket 未监听 / 防火墙 / SSH 隧道 | `systemctl status virtproxyd.socket` | 启动 socket、检查端口与证书 |

### 案例复盘 1：`virsh list` 空白，以为 VM 丢了

现象：用户 A 在终端 `virsh list --all` 输出为空，但 `systemctl status virtqemud`
正常，`ps -ef | grep qemu` 能看到 QEMU 进程。

定位：`virsh uri` 显示 `qemu:///session`。原因是该用户没有加入 `libvirt` 组，
`virsh` 回退到了 session 连接，而域定义在 `/etc/libvirt/qemu/`（system 域）。

处理：`sudo usermod -aG libvirt "$USER"`，重新登录；或显式
`virsh -c qemu:///system`。根治：在 shell profile 里设
`export LIBVIRT_DEFAULT_URI=qemu:///system`。

教训：**先看 `virsh uri`**。libvirt 的"看不见"十有八九是连接错了，不是数据丢了。

### 案例复盘 2：改了大内存，重启却还是老配置

现象：`virsh edit web01` 把 `memory` 从 2048 改成 4096，保存退出，但 guest 内
`free -h` 仍是 2G。`virsh dumpxml` 却显示 4096。

定位：`virsh edit` 写入的是持久定义；运行中的域仍用启动时的参数。用
`virsh dumpxml --inactive web01` 看持久定义，`virsh dumpxml web01` 看运行态。

处理：`virsh destroy web01 && virsh start web01`。内存属于需要重启才生效的参数。
可热插的（`attach-disk`、部分 `update-device`）才不用重启。

教训：XML 有"持久定义"和"运行态"两份。改完先想清楚**能不能热生效**。

### 案例复盘 3：外部快照链越拉越长，性能掉一半

现象：某 VM 每天做一次外部快照，几周后磁盘随机写 IOPS 大幅下降，
`qemu-img info --backing-chain web01.qcow2` 显示十几层。

定位：每次外部快照都在链顶加一层，读要逐层回溯，写触发 COW，链越长越慢；
同时 base 被所有层依赖，无法删除。

处理：`virsh blockcommit web01 vda --active --pivot` 把活跃层合并回 base，
反复执行直到只剩一层；改用 libvirt 备份 API 或"定期全量 + 增量"策略，
不要无限堆快照。

教训：**快照是临时回滚点，不是长期归档**。长期保留要用备份，不是快照。

### 案例复盘 4：备份成功，恢复却失败

现象：备份脚本每天跑 `backup-begin`，日志显示成功，但真正 restore 时报
"backing file not found"。

定位：备份的目标文件是增量 / 覆盖层形式，依赖某个 base，而 base 已不在原路径；
或备份时没有把整条链一起保存。

处理：备份时要么用 `backup-begin` 的全量模式并确认目标是独立盘，
要么确保 base 与所有层一起归档；并定期做恢复演练。

教训：**没演练过的备份不算备份**。备份的可信度只由"能否恢复"决定。

---

## 练习

1. 写一份支持 UEFI 启动 + 两块 virtio 磁盘 + guest agent 通道的 XML，并用 `virt-xml-validate` 校验。
2. 对比内部快照和外部快照的优缺点，各举一个适用场景，说明为什么生产更推荐外部快照。
3. 设计一套"每日外部快照 + 每周全量备份"的方案，说明如何处理覆盖层收敛与恢复演练。
4. 用 `virsh event` 写一个"域意外关闭自动发通知"的脚本思路。
5. 解释 `blockcommit` 与 `blockpull` 的区别，各自适用于什么场景。

## 延伸阅读

- `man virsh`、`virsh help <command>`
- libvirt 域 XML 全量参考：<https://libvirt.org/formatdomain.html>
- libvirt 备份 API：<https://libvirt.org/formatbackup.html>
- libvirt 快照：<https://libvirt.org/formatsnapshot.html>
- modular daemons 说明：<https://libvirt.org/daemons.html>
- `virt-clone`、`virt-customize`、`virt-sysprep` 的 man 手册
