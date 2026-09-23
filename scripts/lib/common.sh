#!/usr/bin/env bash
# lib/common.sh —— 演示脚本公共函数库
# 用法：source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# 不用 set -e：演示中某些命令失败本身也是要展示的内容
set -o pipefail

# ---------- 颜色 ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m';  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=; C_BOLD=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_CYAN=
fi

# ---------- 输出 ----------
banner() {
  local line="======================================================================"
  printf '\n%s%s%s\n' "$C_BOLD$C_BLUE" "$line" "$C_RESET"
  printf '%s  %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"
  printf '%s%s%s\n' "$C_BOLD$C_BLUE" "$line" "$C_RESET"
}
step()  { printf '\n%s▶ %s%s\n' "$C_CYAN$C_BOLD" "$*" "$C_RESET"; }
ok()    { printf '%s  ✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()  { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()   { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
info()  { printf '    %s\n' "$*"; }
note()  { printf '    %s%s%s\n' "$C_BLUE" "$*" "$C_RESET"; }

# 展示并执行命令
run() {
  printf '    %s$ %s%s\n' "$C_BOLD" "$*" "$C_RESET"
  "$@"
}

# ---------- 交互 ----------
is_tty() { [[ -t 0 && -t 1 ]]; }

confirm() {
  local prompt="${1:-继续？}"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then ok "自动确认：$prompt"; return 0; fi
  if ! is_tty; then warn "非交互环境，跳过：$prompt"; return 1; fi
  local a
  read -r -p "$(printf '%s    %s [y/N] %s' "$C_YELLOW" "$prompt" "$C_RESET")" a
  [[ "$a" == "y" || "$a" == "Y" ]]
}

pause() {
  [[ "${NO_PAUSE:-0}" == "1" ]] && return 0
  is_tty || return 0
  read -r -p "$(printf '%s    —— 按回车继续 ——%s' "$C_CYAN" "$C_RESET")" _ || true
}

# ---------- 依赖检查 ----------
need_cmd() {
  local c missing=0
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "缺少命令：$c"; missing=1
    fi
  done
  return $missing
}

require_qemu() {
  if ! need_cmd qemu-system-x86_64 qemu-img; then
    warn "未找到 QEMU。请先运行： sudo $SCRIPT_DIR/02-setup-toolchain.sh"
    return 1
  fi
}

require_libvirt() {
  if ! need_cmd virsh; then
    warn "未找到 virsh。请先运行： sudo $SCRIPT_DIR/02-setup-toolchain.sh"
    return 1
  fi
}

# ---------- 镜像解析 ----------
# 只负责“查找已有镜像”，下载交给独立脚本 00-download-iso.sh
ISO_DIR="${KVM_ISO_DIR:-$HOME/kvm/iso}"

# 解析一个可用的演示 ISO：
#   1) 环境变量 KVM_ISO 指定的文件
#   2) $ISO_DIR/alpine-virt.iso（00-download-iso.sh 的默认输出）
# 找不到就报错并提示去跑下载脚本
resolve_iso() {
  local iso="${KVM_ISO:-}"
  if [[ -n "$iso" && -f "$iso" ]]; then echo "$iso"; return 0; fi

  iso="$ISO_DIR/alpine-virt.iso"
  if [[ -f "$iso" ]]; then echo "$iso"; return 0; fi

  err "未找到演示 ISO"
  info "请先运行下载脚本： ${SCRIPT_DIR:-.}/00-download-iso.sh"
  info "或指定已有镜像：   KVM_ISO=/path/to.iso <演示脚本>"
  return 1
}

# ---------- 临时目录 ----------
DEMO_BASE="${KVM_DEMO_BASE:-/tmp/opencode}"
mktmpdir() {
  local name="${1:-demo}"
  mkdir -p "$DEMO_BASE"
  mktemp -d "$DEMO_BASE/kvm-$name-XXXXXX"
}

