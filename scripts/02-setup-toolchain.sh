#!/usr/bin/env bash
# 02-setup-toolchain.sh —— 安装并配置 KVM 工具链（需要 sudo）
# 对应课程：模块 02
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

banner "演示 02：安装 KVM 工具链"
note "本脚本会调用 dnf 安装软件包，并启用 libvirt 服务。需要 sudo。"

if [[ "$(id -u)" -eq 0 ]]; then
  err "请以普通用户运行（脚本内部会用 sudo），不要直接用 root。"
  exit 1
fi

CORE_PKGS=(qemu-kvm libvirt-daemon-kvm virt-install libguestfs-tools bridge-utils)
EXTRA_PKGS=(perf stress-ng fio iperf3 kvm_stat trace-cmd swtpm swtpm-tools)

step "将安装的核心软件包"
for p in "${CORE_PKGS[@]}"; do info "$p"; done
confirm "开始安装？" || { warn "已取消"; exit 0; }

sudo dnf install -y "${CORE_PKGS[@]}" || { err "核心包安装失败"; exit 1; }

step "可选工具（压测/监控/加密，用于后续模块）"
if confirm "是否安装可选工具？" ; then
  sudo dnf install -y "${EXTRA_PKGS[@]}" || warn "部分可选包安装失败，不影响核心功能"
else
  info "跳过可选工具"
fi

step "启用 libvirt 服务并把当前用户加入 kvm/libvirt 组"
# 合并成一次 sudo 调用，减少输密码次数
sudo sh -c '
  for svc in libvirtd virtqemud.socket virtnetworkd.socket virtstoraged.socket; do
    systemctl enable --now "$svc" >/dev/null 2>&1 && echo "  ✓ $svc 已启用"
  done
  usermod -aG kvm,libvirt "'"$USER"'" && echo "  ✓ 已把 '"$USER"' 加入 kvm,libvirt 组"
  exit 0
' || warn "服务启用或用户组配置可能未完全成功，请检查"
ok "配置完成（组权限需重新登录生效）"

step "验证安装"
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
  info "QEMU: $(qemu-system-x86_64 --version | head -1)"
fi
if command -v virsh >/dev/null 2>&1; then
  info "libvirt: $(virsh --version)"
  virsh -c qemu:///system version >/dev/null 2>&1 \
    && ok "qemu:///system 可连接" \
    || warn "qemu:///system 暂不可连接（可能需要重新登录或启动 daemon）"
fi

banner "完成"
note "重新登录后运行： $SCRIPT_DIR/01-check-env.sh"
note "然后开始演示：   $SCRIPT_DIR/03-demo-storage.sh"
