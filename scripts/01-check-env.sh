#!/usr/bin/env bash
# 01-check-env.sh —— KVM 环境自检（只读，不修改系统）
# 对应课程：模块 01 / 02
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

banner "演示 01：KVM 环境自检"
note "只读检查，不会修改系统。本机基线：Fedora 44 / Intel VT-x"

# ---------- 1. 系统 ----------
step "1. 操作系统与内核"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  info "$( . /etc/os-release; echo "${PRETTY_NAME:-unknown}" )"
fi
info "内核版本      : $(uname -r)"
info "架构          : $(uname -m)"
VIRT="$(systemd-detect-virt 2>/dev/null || true)"
[[ -z "$VIRT" ]] && VIRT=unknown
info "运行环境      : $VIRT  （none=裸机，kvm/qemu=当前就在虚拟机里）"

# ---------- 2. CPU 虚拟化 ----------
step "2. CPU 硬件虚拟化能力"
FLAGS="$(grep -m1 -oE 'vmx|svm' /proc/cpuinfo || true)"
if [[ "$FLAGS" == "vmx" ]]; then
  ok "检测到 Intel VT-x（vmx）"
elif [[ "$FLAGS" == "svm" ]]; then
  ok "检测到 AMD-V（svm）"
else
  err "未检测到 vmx/svm —— CPU 不支持或 BIOS 未开启虚拟化"
fi
info "逻辑 CPU 数   : $(nproc)"
info "NUMA 节点     : $(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)"

# ---------- 3. 内核模块 ----------
step "3. KVM 内核模块"
# 注意：不要用 `lsmod | grep -q`，pipefail 下 grep -q 提前退出会让管道判失败
MODINFO="$(lsmod 2>/dev/null || true)"
if grep -qE '^kvm_intel|^kvm_amd' <<<"$MODINFO"; then
  grep -E '^kvm_intel|^kvm_amd|^kvm ' <<<"$MODINFO" | sed 's/^/    /'
  ok "KVM 模块已加载"
else
  warn "KVM 模块未加载（可尝试：sudo modprobe kvm_intel）"
fi
NESTED_FILE=""
[[ -e /sys/module/kvm_intel/parameters/nested ]] && NESTED_FILE=/sys/module/kvm_intel/parameters/nested
[[ -e /sys/module/kvm_amd/parameters/nested   ]] && NESTED_FILE=/sys/module/kvm_amd/parameters/nested
if [[ -n "$NESTED_FILE" ]]; then
  info "嵌套虚拟化    : $(cat "$NESTED_FILE")  （Y/N，模块 12 会用到）"
fi

# ---------- 4. /dev/kvm ----------
step "4. /dev/kvm 字符设备"
if [[ -e /dev/kvm ]]; then
  ls -l /dev/kvm | sed 's/^/    /'
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ok "当前用户可读写 /dev/kvm"
  else
    warn "当前用户对 /dev/kvm 无读写权限，请把自己加入 kvm 组后重新登录"
  fi
  info "当前用户所属组: $(id -nG "$USER")"
else
  err "/dev/kvm 不存在 —— BIOS 未开虚拟化，或模块未加载"
fi

# ---------- 5. IOMMU ----------
step "5. IOMMU（设备直通的前提，模块 07）"
IOMMU_GROUPS="$(ls -d /sys/kernel/iommu_groups/*/ 2>/dev/null | wc -l)"
if [[ "$IOMMU_GROUPS" -gt 0 ]]; then
  ok "IOMMU 已启用（$IOMMU_GROUPS 个 IOMMU 分组）"
else
  warn "IOMMU 未启用（直通实验需要内核参数：intel_iommu=on iommu=pt）"
fi

# ---------- 6. 内存相关 ----------
step "6. 内存虚拟化相关开关（模块 08）"
info "HugePages     : $(grep -E 'HugePages_Total|Hugepagesize' /proc/meminfo | tr '\n' ' ')"
info "KSM 运行状态  : $(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo '不可用')  （1=开启）"
info "内存总量      : $(grep MemTotal /proc/meminfo | awk '{printf "%.1f GiB\n", $2/1024/1024}')"

# ---------- 7. 工具链 ----------
step "7. 用户态工具链"
missing=0
for c in qemu-system-x86_64 qemu-img qemu-io virsh virt-install; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c -> $(command -v "$c")"
  else
    warn "$c 未安装"
    missing=1
  fi
done
for c in kvm_stat perf stress-ng fio iperf3 trace-cmd; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c -> $(command -v "$c")"
  else
    warn "$c 未安装（可选）"
  fi
done

# ---------- 8. libvirt ----------
step "8. libvirt 服务状态"
if command -v virsh >/dev/null 2>&1; then
  if virsh -c qemu:///system version >/dev/null 2>&1; then
    ok "qemu:///system 连接正常"
  else
    warn "qemu:///system 连接失败（daemon 未启动或权限不足）"
  fi
  if virsh -c qemu:///session version >/dev/null 2>&1; then
    ok "qemu:///session 连接正常（免 root，适合本机演示）"
  else
    warn "qemu:///session 连接失败"
  fi
fi

# ---------- 结论 ----------
banner "结论与下一步"
if [[ "$missing" == "1" ]]; then
  warn "缺少 QEMU/libvirt，先安装："
  info "sudo $SCRIPT_DIR/02-setup-toolchain.sh"
else
  ok "环境就绪，可以直接运行其它演示："
  info "$SCRIPT_DIR/03-demo-storage.sh          # 存储：镜像格式/后备链/精简置备"
  info "$SCRIPT_DIR/04-demo-vm-process.sh       # 原理：虚拟机就是一个进程"
  info "$SCRIPT_DIR/05-demo-vm-lifecycle.sh     # libvirt 生命周期管理"
  info "$SCRIPT_DIR/06-demo-network.sh          # 网络：网桥/tap/NAT"
  info "$SCRIPT_DIR/07-demo-monitor-perf.sh     # 监控与性能"
fi
