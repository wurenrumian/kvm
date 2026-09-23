#!/usr/bin/env bash
# run-all.sh —— 一键跑完：环境自检 → 安装工具链 → 全部演示 → 打印完成汇总
# 用法： ./run-all.sh [--no-install] [--install-only] [--no-download] [--skip "04 05"] [--yes]
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ---------- 参数 ----------
DO_INSTALL=1
INSTALL_ONLY=0
DO_DOWNLOAD=1
SKIP=""
FORCE_YES=0

usage() {
  cat <<EOF
用法: $0 [选项]

  --no-install     不安装工具链（跳过 02）
  --install-only   只安装，不跑演示
  --no-download    不下载演示镜像（04/05 将跳过）
  --skip "04 05"   跳过指定编号的演示
  --yes            所有确认自动通过（无终端时默认开启）
  -h, --help       显示本帮助

示例:
  $0                          # 自检 → 安装 → 下载镜像 → 全部演示 → 汇总
  $0 --no-install             # 已装好，只跑演示
  $0 --skip "04 05" --yes     # 非交互跑其余演示
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-install)   DO_INSTALL=0 ;;
    --install-only) INSTALL_ONLY=1 ;;
    --no-download)  DO_DOWNLOAD=0 ;;
    --skip)         SKIP="${2:-}"; shift ;;
    --yes|-y)       FORCE_YES=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 1 ;;
  esac
  shift
done

# ---------- 交互判定（必须在重定向之前） ----------
INTERACTIVE=0
[[ -t 0 ]] && INTERACTIVE=1
if [[ "$FORCE_YES" == "1" || "$INTERACTIVE" == "0" ]]; then
  export ASSUME_YES=1 NO_PAUSE=1
fi

# ---------- 日志 ----------
LOG_DIR="${KVM_LOG_DIR:-$HOME/kvm/logs}"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/run-all-$STAMP.log"
STATUS="$LOG_DIR/last-status.txt"
exec > >(tee -a "$LOG") 2>&1

RESULTS=()
FAILED=0

run_demo() {
  local id="$1" script="$2"
  local name; name="$(basename "$script")"
  if [[ " $SKIP " == *" $id "* ]]; then
    warn "跳过演示 $id（$name）"
    RESULTS+=("$id|$name|SKIP")
    return 0
  fi
  step "运行演示 $id：$name"
  local start=$SECONDS
  if ASSUME_YES=1 NO_PAUSE=1 "$script"; then
    ok "演示 $id 完成（$((SECONDS - start))s）"
    RESULTS+=("$id|$name|PASS")
  else
    err "演示 $id 失败（$((SECONDS - start))s）"
    RESULTS+=("$id|$name|FAIL")
    FAILED=$((FAILED + 1))
  fi
}

# ============================================================
banner "KVM 课程 · 一键演示"
info "开始时间 : $(date '+%F %T')"
info "日志文件 : $LOG"
info "运行模式 : $([[ "$INTERACTIVE" == 1 ]] && echo 交互 || echo 非交互)"

# ---------- 0. 环境自检 ----------
run_demo "01" "$SCRIPT_DIR/01-check-env.sh"

# ---------- 1. 安装工具链 ----------
INSTALL_RESULT="skipped"
if [[ "$DO_INSTALL" == "1" ]]; then
  if command -v qemu-system-x86_64 >/dev/null 2>&1 && command -v virsh >/dev/null 2>&1; then
    ok "QEMU/libvirt 已存在，跳过安装"
    INSTALL_RESULT="already"
  else
    step "安装工具链（非交互模式下会弹出图形授权框，请输入密码）"
    if ASSUME_YES=1 "$SCRIPT_DIR/02-setup-toolchain.sh"; then
      INSTALL_RESULT="ok"
    else
      INSTALL_RESULT="failed"
      FAILED=$((FAILED + 1))
    fi
  fi
else
  warn "按参数要求跳过安装（--no-install）"
fi

# ---------- 仅安装则结束 ----------
if [[ "$INSTALL_ONLY" == "1" ]]; then
  printf '\a'
  banner "安装完成（结果：$INSTALL_RESULT）"
  info "请重新登录让 kvm/libvirt 组生效，然后运行： $SCRIPT_DIR/run-all.sh --no-install"
  info "日志：$LOG"
  exit "$([[ "$INSTALL_RESULT" == "failed" ]] && echo 1 || echo 0)"
fi

# ---------- 2. 准备演示镜像（调用独立下载脚本） ----------
ISO_READY=0
if [[ -n "${KVM_ISO:-}" && -f "${KVM_ISO:-}" ]]; then ISO_READY=1; fi
if [[ -f "$ISO_DIR/alpine-virt.iso" ]]; then ISO_READY=1; fi

if [[ "$ISO_READY" == "1" ]]; then
  ok "演示镜像已就绪"
elif [[ "$DO_DOWNLOAD" == "1" ]]; then
  step "下载演示镜像（调用 00-download-iso.sh）"
  if "$SCRIPT_DIR/00-download-iso.sh"; then
    ISO_READY=1
  else
    warn "镜像下载失败，04/05 将跳过"
  fi
else
  warn "未提供镜像且指定了 --no-download，04/05 将跳过"
fi
[[ "$ISO_READY" == "0" ]] && SKIP="$SKIP 04 05"

# ---------- 3. 全部演示 ----------
run_demo "03" "$SCRIPT_DIR/03-demo-storage.sh"
run_demo "04" "$SCRIPT_DIR/04-demo-vm-process.sh"
run_demo "05" "$SCRIPT_DIR/05-demo-vm-lifecycle.sh"
run_demo "06" "$SCRIPT_DIR/06-demo-network.sh"
run_demo "07" "$SCRIPT_DIR/07-demo-monitor-perf.sh"

# ---------- 4. 汇总 ----------
PASS=0; SKIPPED=0
{
  echo "KVM 课程演示结果 · $(date '+%F %T')"
  echo "日志：$LOG"
  echo "安装：$INSTALL_RESULT"
  echo "----------------------------------------"
  printf '%-6s %-34s %s\n' "编号" "脚本" "结果"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r id name res <<<"$r"
    printf '%-6s %-34s %s\n' "$id" "$name" "$res"
  done
} > "$STATUS"

banner "演示汇总"
cat "$STATUS"
echo
for r in "${RESULTS[@]}"; do
  IFS='|' read -r _ _ res <<<"$r"
  case "$res" in
    PASS) PASS=$((PASS + 1)) ;;
    SKIP) SKIPPED=$((SKIPPED + 1)) ;;
  esac
done
info "通过 $PASS 项，失败 $FAILED 项，跳过 $SKIPPED 项"
info "结束时间 : $(date '+%F %T')"
info "完整日志 : $LOG"

# ---------- 5. 结束提示（纯终端） ----------
printf '\a'
if [[ "$FAILED" -eq 0 ]]; then
  banner "完成 ✅  通过 $PASS 项，跳过 $SKIPPED 项"
else
  banner "完成（有失败）⚠  通过 $PASS 项，失败 $FAILED 项，跳过 $SKIPPED 项"
fi
info "日志：$LOG"
info "状态：$STATUS"
[[ "$FAILED" -ne 0 ]] && note "把日志贴给我即可帮你定位问题"

exit "$([[ "$FAILED" -eq 0 ]] && echo 0 || echo 1)"
