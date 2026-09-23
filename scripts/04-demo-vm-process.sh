#!/usr/bin/env bash
# 04-demo-vm-process.sh —— 演示「虚拟机就是一个普通 Linux 进程」
# 对应课程：模块 01 / 03
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

banner "演示 04：虚拟机 = 一个 Linux 进程"
note "用裸 QEMU 启动一台 Alpine 虚拟机，然后在宿主机侧观察它"

require_qemu || exit 1
ISO="$(resolve_iso)" || exit 1
info "使用镜像: $ISO"

WORK="$(mktmpdir process)"
LOG="$WORK/serial.log"
cd "$WORK" || exit 1

cleanup() {
  [[ -n "${QPID:-}" ]] && kill -9 "$QPID" 2>/dev/null
  cd /; rm -rf "$WORK"
}
trap cleanup EXIT

step "1. 启动虚拟机（KVM 加速，2 vCPU，512MB，无图形，串口写日志）"
info "命令： qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 512 \\"
info "          -cdrom <iso> -boot d -display none -serial file:serial.log"
qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 512 \
  -cdrom "$ISO" -boot d -display none -serial "file:$LOG" -monitor none -no-reboot \
  >/dev/null 2>&1 &
QPID=$!
info "QEMU PID = $QPID"
sleep 2

if ! kill -0 "$QPID" 2>/dev/null; then
  err "QEMU 启动失败（可能缺 KVM 权限）。日志尾部："
  tail -5 "$LOG" 2>/dev/null | sed 's/^/    /'
  exit 1
fi

step "2. 在宿主机上，它就是这样一个进程"
ps -o pid,ppid,stat,pcpu,pmem,etime,comm -p "$QPID" | sed 's/^/    /'

step "3. 它的线程：主线程 + 每个 vCPU 一个 KVM 线程"
note "注意 comm 里的 'CPU 0/KVM'、'CPU 1/KVM' —— 这就是 vCPU"
ps -L -o pid,tid,stat,pcpu,comm -p "$QPID" | sed 's/^/    /'

step "4. 它持有 /dev/kvm（虚拟化能力的入口）"
FDS="$(ls -l "/proc/$QPID/fd" 2>/dev/null || true)"
if grep -qi kvm <<<"$FDS"; then
  grep -i kvm <<<"$FDS" | sed 's/^/    /'
else
  info "（fd 列表未直接暴露 kvm，属正常；KVM 通过内核 ioctl 持有）"
fi

step "5. 内存占用：-m 512 大致对应 RSS"
grep -E 'VmSize|VmRSS' "/proc/$QPID/status" 2>/dev/null | sed 's/^/    /'

step "6. 等 guest 启动，看串口输出（Alpine 启动日志）"
sleep 8
if [[ -s "$LOG" ]]; then
  info "--- serial.log 前 30 行 ---"
  sed -n '1,30p' "$LOG" | sed 's/^/    /'
else
  warn "串口暂无输出（ISO 可能需要更久，或该镜像未走串口）"
fi

step "7. 关掉虚拟机 = kill 这个进程"
kill "$QPID" 2>/dev/null
sleep 1
kill -9 "$QPID" 2>/dev/null || true
QPID=""
ok "进程已结束"

banner "小结"
info "每个 vCPU = 宿主机上一个线程，由 Linux 调度器管理 → 所以 CPU pinning 有效（模块 08）"
info "QEMU 进程崩溃 = 虚拟机宕机 → 所以 QEMU 是安全边界（模块 10）"
info "KVM 只负责 CPU/内存虚拟化，设备由 QEMU 模拟 → 所以叫 QEMU/KVM（模块 03）"
