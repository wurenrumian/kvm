# 模块 04 · libvirt 与虚拟机生命周期管理

## 学习目标

- 掌握 libvirt 的核心概念（连接、域、网络、存储池）；
- 能用 XML 完整描述一台虚拟机并管理其生命周期；
- 会做快照、克隆、备份与批量操作。

---

## 4.1 libvirt 的核心概念

| 概念 | 说明 | 命令前缀 |
| --- | --- | --- |
| **连接（Connection）** | 到某个 hypervisor 的通道，如 `qemu:///system` | `virsh -c` |
| **域（Domain）** | 一台虚拟机 | `virsh dom*` / `virsh *` |
| **网络（Network）** | 虚拟网络，如 default NAT | `virsh net-*` |
| **存储池（Pool）** | 存储后端（目录/LVM/Ceph） | `virsh pool-*` |
| **卷（Volume）** | 池里的磁盘 | `virsh vol-*` |
| **接口（Interface）** | 宿主机物理/虚拟网卡 | `virsh iface-*` |

连接 URI 常用形式：

- `qemu:///system`：系统级（root 权限，生产用）
- `qemu:///session`：用户级（普通用户，隔离性好，适合开发）
- `qemu+ssh://host/system`：远程管理

## 4.2 域的 XML 结构（精简版）

```xml
<domain type='kvm'>
  <name>web01</name>
  <memory unit='MiB'>2048</memory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/><apic/>
  </features>
  <cpu mode='host-passthrough'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'/>
      <source file='/var/lib/libvirt/images/web01.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'><target type='serial'/></console>
    <graphics type='spice' autoport='yes'/>
  </devices>
</domain>
```

要点：

- `machine='q35'` 是较新的芯片组，支持 PCIe；老镜像有时需 `i440fx`。
- 磁盘 `cache='none' io='native'` 是性能常用组合（模块 05 详解）。
- `bus='virtio'` 优于默认的 IDE/SATA。

## 4.3 生命周期操作

```bash
virsh list --all                    # 列出所有域
virsh start web01
virsh shutdown web01                # ACPI 优雅关机
virsh destroy web01                 # 强制断电
virsh reboot web01
virsh suspend web01                 # 暂停（内存保留）
virsh resume web01
virsh autostart web01               # 宿主机启动时自动拉起
virsh domstate web01
virsh dominfo web01
```

## 4.4 快照

libvirt 快照分两类：

- **内部快照**：快照数据存在 qcow2 文件内部，只支持 qcow2，速度快但管理受限。
- **外部快照**：生成新的 qcow2 覆盖层，支持任何格式（含 raw），推荐生产。

```bash
# 内部快照
virsh snapshot-create-as web01 snap1 "before upgrade"
virsh snapshot-list web01
virsh snapshot-revert web01 snap1
virsh snapshot-delete web01 snap1

# 外部快照（需要磁盘支持，且要 --disk-only）
virsh snapshot-create-as web01 ext1 "external" --disk-only --atomic
```

> **重要**：快照**不是备份**。快照依赖原盘，原盘损坏则快照一起丢。备份见 4.6。

## 4.5 克隆

```bash
# 完整克隆（复制磁盘）
virt-clone --original web01 --name web02 \
  --file /var/lib/libvirt/images/web02.qcow2

# 链接克隆（基于原盘，省空间）
virt-clone --original web01 --name web03 --auto-clone
```

克隆后常需处理：

- MAC 地址冲突（libvirt 会自动重新生成）；
- hostname / machine-id（进 guest 后重置）；
- cloud-init 重新初始化。

## 4.6 备份

```bash
# 块级备份（libvirt 8.0+，推荐）
virsh backup-begin web01 --backupxml backup.xml

# 传统方式：外部快照 + 拷贝原盘
virsh snapshot-create-as web01 bkp --disk-only --atomic --no-metadata
cp /var/lib/libvirt/images/web01.qcow2 /backup/
virsh blockcommit web01 vda --active --pivot   # 合并回原盘

# 离线备份（关机后）
virt-copy-out /var/lib/libvirt/images/web01.qcow2 /tmp/   # 需 libguestfs
```

## 4.7 存储池与网络管理

```bash
# 存储池
virsh pool-list --all
virsh pool-define-as mypool dir --target /data/vms
virsh pool-build mypool && virsh pool-start mypool && virsh pool-autostart mypool
virsh vol-create-as mypool disk1.qcow2 20G --format qcow2
virsh vol-list mypool

# 网络
virsh net-list --all
virsh net-start default
virsh net-autostart default
virsh net-dumpxml default
virsh net-edit default
```

## 4.8 批量与自动化

```bash
# 批量操作所有域
for d in $(virsh list --name); do echo "== $d =="; virsh dominfo "$d"; done

# 用 virsh 脚本模式
virsh -c qemu:///system <<'EOF'
list --all
net-list
EOF
```

---

## 动手实验

**实验 4-1：全 XML 定义一台 VM**
手写一份 XML（参考 4.2），用 `virsh define` 定义，再 `virsh start`。

**实验 4-2：快照与回滚**
装个包 → 打快照 → 删包 → 回滚 → 验证包又回来了。

**实验 4-3：克隆并改身份**
克隆一台，进 guest 改 hostname 和 `/etc/machine-id`，验证网络正常。

**实验 4-4：用 virt-customize 批量改配置**

```bash
virt-customize -a /var/lib/libvirt/images/web02.qcow2 \
  --hostname web02 --root-password password:secret
```

---

## 排错指南

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `define` 报 XML 校验失败 | 元素顺序/必填项问题 | 用 `virt-xml-validate` 校验 |
| 快照创建失败 | 磁盘是 raw / 不支持 | 转 qcow2 或用外部快照 |
| 克隆后网络不通 | MAC/hostname 冲突 | 重置 machine-id、检查 DHCP |
| `virsh edit` 后不生效 | 未保存/未重定义 | 保存退出会自动 define |

---

## 练习

1. 写一份支持 UEFI 启动 + 两块 virtio 磁盘的 XML。
2. 对比内部快照和外部快照的优缺点，各举一个适用场景。
3. 设计一套"每日外部快照 + 每周全量备份"的方案。

## 延伸阅读

- `man virsh`、`virsh help <command>`
- libvirt 域 XML 全量参考：<https://libvirt.org/formatdomain.html>
- libvirt 备份 API：<https://libvirt.org/formatbackup.html>
