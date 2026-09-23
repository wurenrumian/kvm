#!/usr/bin/env bash
# 05-demo-vm-lifecycle.sh —— 演示 libvirt 管理虚拟机生命周期
# 对应课程：模块 04
# 默认使用 qemu:///session（免 root、无 SELinux 标签烦恼）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

banner "演示 05：libvirt 虚拟机生命周期"
URI="${LIBVIRT_URI:-qemu:///session}"
note "连接：$URI （可用 LIBVIRT_URI=qemu:///system 覆盖）"

require_libvirt || exit 1

if ! virsh -c "$URI" version >/dev/null 2>&1; then
  err "无法连接 $URI"
  warn "请先运行： sudo $SCRIPT_DIR/02-setup-toolchain.sh，并重新登录"
  exit 1
fi
ok "libvirt 连接正常"

ISO="$(resolve_iso)" || exit 1
info "使用镜像: $ISO"

DOM="kvm-demo-$$"
WORK="$(mktmpdir lifecycle)"
XML="$WORK/$DOM.xml"

cleanup() {
  virsh -c "$URI" destroy "$DOM" >/dev/null 2>&1
  virsh -c "$URI" undefine "$DOM" >/dev/null 2>&1
  cd /; rm -rf "$WORK"
}
trap cleanup EXIT

step "1. 生成域 XML（从 ISO 启动，user 模式网络，串口控制台）"
cat > "$XML" <<EOF
<domain type='kvm'>
  <name>$DOM</name>
  <memory unit='MiB'>512</memory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='cdrom'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$ISO'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='user'>
      <model type='virtio'/>
    </interface>
    <console type='pty'><target type='serial'/></console>
    <video><model type='vga'/></video>
  </devices>
</domain>
EOF
info "已写入 $XML"

step "2. virsh define —— 把 XML 注册为持久化域（此时还没运行）"
run virsh -c "$URI" define "$XML"
virsh -c "$URI" list --all | sed 's/^/    /'

step "3. virsh start —— 启动"
run virsh -c "$URI" start "$DOM"
sleep 2
virsh -c "$URI" list | sed 's/^/    /'
info "状态: $(virsh -c "$URI" domstate "$DOM")"

step "4. virsh dominfo —— 查看基本信息"
virsh -c "$URI" dominfo "$DOM" | sed 's/^/    /'

step "5. 宿主机侧确认它确实是一个进程"
ps -eo pid,comm,args | grep '[q]emu-system' | head -3 | sed 's/^/    /'

step "6. virsh suspend / resume —— 暂停与恢复（内存保留）"
run virsh -c "$URI" suspend "$DOM"
info "暂停后状态: $(virsh -c "$URI" domstate "$DOM")"
run virsh -c "$URI" resume "$DOM"
info "恢复后状态: $(virsh -c "$URI" domstate "$DOM")"

step "7. virsh domstats —— 运行时统计"
virsh -c "$URI" domstats "$DOM" --state --cpu-total --balloon 2>/dev/null | sed 's/^/    /'

step "8. virsh destroy —— 强制断电（对比 shutdown 是 ACPI 优雅关机）"
run virsh -c "$URI" destroy "$DOM"
info "状态: $(virsh -c "$URI" domstate "$DOM")"

step "9. virsh undefine —— 删除域定义"
run virsh -c "$URI" undefine "$DOM"
virsh -c "$URI" list --all | sed 's/^/    /'

banner "小结"
info "XML 是 libvirt 的唯一真相：define 注册、edit 修改、dumpxml 导出"
info "shutdown=优雅（需 guest 支持 ACPI），destroy=拔电源"
info "真实 QEMU 命令行可用 ps 看到，是 XML 翻译的结果（模块 02/04）"
ok "演示结束，临时目录已清理"
