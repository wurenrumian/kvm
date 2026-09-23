#!/usr/bin/env bash
# 07-demo-monitor-perf.sh —— 演示监控与性能观测
# 对应课程：模块 08 / 11
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

banner "演示 07：监控与性能观测"
note "先看系统层指标，再看虚拟机层指标；有运行中的 VM 时额外展示 domstats"

# ---------- 1. 系统资源开关 ----------
step "1. 内存相关开关（影响性能）"
info "HugePages    : $(grep -E 'HugePages_Total|Hugepagesize' /proc/meminfo | tr '\n' ' ')"
info "KSM 运行     : $(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo 不可用)"
info "Swap 总量    : $(grep SwapTotal /proc/meminfo | awk '{printf "%.1f GiB\n", $2/1024/1024}')"

step "2. CPU / NUMA 拓扑"
if command -v numactl >/dev/null 2>&1; then
  numactl --hardware 2>/dev/null | sed 's/^/    /'
else
  info "（未安装 numactl：sudo dnf install numactl）"
  lscpu | grep -iE '^CPU\(s\)|NUMA|Model name' | sed 's/^/    /'
fi

# ---------- 3. KVM 层 ----------
step "3. KVM 层：VM-Exit 统计（kvm_stat）"
if command -v kvm_stat >/dev/null 2>&1; then
  if kvm_stat --once >/dev/null 2>&1; then
    kvm_stat --once 2>/dev/null | head -12 | sed 's/^/    /'
  elif sudo -n true 2>/dev/null; then
    sudo -n kvm_stat --once 2>/dev/null | head -12 | sed 's/^/    /'
  else
    note "kvm_stat 需要 root： sudo kvm_stat --once"
  fi
else
  note "未安装 kvm_stat： sudo dnf install kvm_stat"
fi

step "4. perf kvm（更精细的 VM-Exit 剖析）"
if command -v perf >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    sudo -n perf kvm stat record -a sleep 2 >/dev/null 2>&1
    sudo -n perf kvm stat report 2>/dev/null | head -15 | sed 's/^/    /'
  else
    note "需要 root： sudo perf kvm stat live"
  fi
else
  note "未安装 perf： sudo dnf install perf"
fi

# ---------- 5. 虚拟机层 ----------
step "5. 虚拟机层：domstats"
if command -v virsh >/dev/null 2>&1; then
  RUNNING="$(virsh -c qemu:///session list --name 2>/dev/null; virsh -c qemu:///system list --name 2>/dev/null)"
  RUNNING="$(printf '%s\n' "$RUNNING" | sed '/^$/d' | sort -u)"
  if [[ -n "$RUNNING" ]]; then
    for d in $RUNNING; do
      info "域 $d："
      (virsh -c qemu:///session domstats "$d" --state --cpu-total --balloon --block --interface 2>/dev/null \
        || virsh -c qemu:///system domstats "$d" --state --cpu-total --balloon --block --interface 2>/dev/null) \
        | head -20 | sed 's/^/      /'
    done
  else
    note "当前没有运行中的虚拟机。可先跑 05-demo-vm-lifecycle.sh，再运行本脚本"
  fi
fi

# ---------- 6. 可选压测 ----------
step "6. 可选：快速压测（建立基线）"
if command -v stress-ng >/dev/null 2>&1; then
  if confirm "运行 5 秒 CPU 压测并观察 steal time？（会短暂占用 CPU）"; then
    stress-ng --cpu 2 --timeout 5s >/dev/null 2>&1 &
    SPID=$!
    for i in 1 2 3 4 5; do
      info "t=${i}s  load=$(cut -d' ' -f1 /proc/loadavg)  $(top -bn1 | grep -E '^%Cpu' | head -1)"
      sleep 1
    done
    wait "$SPID" 2>/dev/null
    ok "压测结束"
  fi
else
  note "未安装 stress-ng： sudo dnf install stress-ng"
fi

banner "排障思路（模块 11）"
cat <<'EOF'
    症状                     先查
    ─────────────────────────────────────────────────────────
    VM 卡顿 / 延迟高          top 看 steal time → perf kvm
    磁盘 I/O 慢               virsh domblkstat → iostat -x
    网络慢 / 丢包             virsh domifstat → ethtool -S
    内存不足                  virsh dommemstat → 超分 / KSM
    VM 起不来                 /var/log/libvirt/qemu/<name>.log + SELinux avc
EOF
ok "演示结束"
