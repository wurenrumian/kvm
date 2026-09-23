#!/usr/bin/env bash
# 00-download-iso.sh —— 下载演示用 Linux 镜像（独立脚本，与演示解耦）
#
# 默认下载 Alpine virt ISO（约 60MB，体积小、启动快、走串口，适合演示）
# 保存为 ~/kvm/iso/alpine-virt.iso，演示脚本 04/05 会自动使用它。
#
# 用法:
#   ./00-download-iso.sh                          # 下载 Alpine virt ISO
#   ./00-download-iso.sh --dir /data/iso          # 指定保存目录
#   ./00-download-iso.sh --force                  # 已存在也重新下载
#   ./00-download-iso.sh --url https://.../x.iso  # 下载任意镜像
#   ./00-download-iso.sh --url URL --name my.iso  # 指定本地文件名
#   ./00-download-iso.sh --print                  # 只打印解析到的 URL，不下载
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"

DEST_DIR="$ISO_DIR"
URL=""
LOCAL_NAME=""
FORCE=0
PRINT_ONLY=0

usage() {
  cat <<EOF
用法: $0 [选项]

  --url URL      下载指定 URL 的镜像（默认：Alpine virt ISO 最新稳定版）
  --name NAME    本地保存的文件名（默认：alpine-virt.iso，或从 URL 推断）
  --dir DIR      保存目录（默认：$ISO_DIR）
  --force, -f    已存在也重新下载
  --print        只打印解析到的 URL，不下载
  -h, --help     显示本帮助

示例:
  $0
  $0 --dir /data/iso --force
  $0 --url https://example.com/linux.iso --name mylinux.iso
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)       URL="${2:-}"; shift ;;
    --name)      LOCAL_NAME="${2:-}"; shift ;;
    --dir)       DEST_DIR="${2:-}"; shift ;;
    --force|-f)  FORCE=1 ;;
    --print)     PRINT_ONLY=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) err "未知参数：$1"; usage; exit 1 ;;
  esac
  shift
done

# ---------- 下载工具 ----------
fetch_stdout() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    err "需要 curl 或 wget"; return 1
  fi
}
download_file() {
  local u="$1" o="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$o" "$u"
  else
    wget -O "$o" "$u"
  fi
}

banner "下载演示镜像"
need_cmd curl wget 2>/dev/null || true

# ---------- 解析 URL 与本地文件名 ----------
if [[ -z "$URL" ]]; then
  step "解析 Alpine 最新稳定版"
  yaml="$(fetch_stdout "$ALPINE_MIRROR/latest-releases.yaml")" \
    || { err "无法获取版本列表（网络不可用？）"; exit 1; }
  remote="$(printf '%s\n' "$yaml" | grep -oE 'alpine-virt-[0-9.]+-x86_64\.iso' | head -1)"
  [[ -n "$remote" ]] || { err "无法解析 ISO 文件名"; exit 1; }
  URL="$ALPINE_MIRROR/$remote"
  [[ -z "$LOCAL_NAME" ]] && LOCAL_NAME="alpine-virt.iso"
  info "版本：$remote"
else
  [[ -z "$LOCAL_NAME" ]] && LOCAL_NAME="$(basename "$URL")"
fi

info "来源：$URL"
info "保存：$DEST_DIR/$LOCAL_NAME"

if [[ "$PRINT_ONLY" == "1" ]]; then
  echo "$URL"
  exit 0
fi

DEST="$DEST_DIR/$LOCAL_NAME"
if [[ -f "$DEST" && "$FORCE" != "1" ]]; then
  ok "文件已存在，跳过下载（加 --force 可强制重下）"
  info "$DEST"
  exit 0
fi

# ---------- 下载 ----------
mkdir -p "$DEST_DIR"
step "下载中…"
if ! download_file "$URL" "$DEST"; then
  err "下载失败"
  rm -f "$DEST"
  exit 1
fi
ok "下载完成：$DEST（$(du -h "$DEST" | cut -f1)）"

# ---------- 校验 ----------
step "校验完整性"
if command -v sha256sum >/dev/null 2>&1; then
  expected="$(fetch_stdout "${URL}.sha256" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  if [[ -n "$expected" ]]; then
    actual="$(sha256sum "$DEST" | awk '{print $1}')"
    if [[ "$expected" == "$actual" ]]; then
      ok "SHA256 校验通过"
    else
      err "SHA256 不匹配，文件可能损坏"
      exit 1
    fi
  else
    warn "未找到校验和文件，跳过验证"
  fi
else
  warn "未安装 sha256sum，跳过验证"
fi

banner "完成"
info "演示脚本会自动使用： $DEST"
info "也可显式指定：       KVM_ISO=$DEST ./04-demo-vm-process.sh"
