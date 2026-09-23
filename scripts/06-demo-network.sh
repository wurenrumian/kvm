#!/usr/bin/env bash
# 06-demo-network.sh —— 演示虚拟网络：网桥、tap 设备、NAT
# 对应课程：模块 06
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

banner "演示 06：虚拟网络链路"
note "只读观察宿主机网络；不会改动配置"

# ---------- 1. 物理网卡 ----------
step "1. 物理网卡"
ip -brief link show | grep -vE '^(lo|virbr|vnet|docker|br-|tap)' | sed 's/^/    /' || true

# ---------- 2. 网桥 ----------
step "2. Linux 网桥（软件交换机）"
BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}')"
if [[ -n "$BRIDGES" ]]; then
  for b in $BRIDGES; do
    info "网桥 $b："
    ip -d link show "$b" | sed -n '1,2p' | sed 's/^/      /'
    bridge link show dev "$b" 2>/dev/null | sed 's/^/      /'
  done
else
  info "当前没有 Linux 网桥（virbr0 属于 libvirt 的 NAT 网络，见下）"
fi

# ---------- 3. libvirt 网络 ----------
step "3. libvirt 管理的网络"
if command -v virsh >/dev/null 2>&1 && virsh -c qemu:///system net-list --all >/dev/null 2>&1; then
  virsh -c qemu:///system net-list --all | sed 's/^/    /'
  step "4. default 网络定义（NAT，默认 192.168.122.0/24）"
  virsh -c qemu:///system net-dumpxml default 2>/dev/null | sed 's/^/    /'
  info "宿主机网关接口："
  ip -brief addr show virbr0 2>/dev/null | sed 's/^/      /' || info "      virbr0 未启动（virsh net-start default）"
else
  warn "无法访问 qemu:///system（权限或 daemon 未启动），跳过 libvirt 网络信息"
fi

# ---------- 5. tap 设备 ----------
step "5. tap 设备（QEMU 网卡在宿主机侧的端点）"
TAPS="$(ip -o link show type tun 2>/dev/null | awk -F': ' '{print $2}')"
if [[ -n "$TAPS" ]]; then
  for t in $TAPS; do ip -d link show "$t" | sed -n '1,2p' | sed 's/^/      /'; done
else
  info "当前没有 tap 设备（没有运行中的虚拟机）"
  note "启动一台 VM 后再运行本脚本，就能看到 vnetX / tapX"
fi

# ---------- 6. 转发与 NAT ----------
step "6. 转发开关与 NAT 规则"
info "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
if command -v nft >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  info "nftables 中的 NAT 规则（需 root，已用 sudo -n）："
  sudo -n nft list ruleset 2>/dev/null | grep -iE 'masquerade|192\.168\.122' | head -5 | sed 's/^/      /'
else
  note "NAT 规则需 root 查看：sudo nft list ruleset | grep masquerade"
fi

# ---------- 7. 数据通路图解 ----------
banner "数据通路：guest 出网"
cat <<'EOF'
    guest 内 virtio-net 驱动
         │  (共享内存 virtqueue)
         ▼
    QEMU 的 tap 设备 (tapX / vnetX)
         │
         ▼
    Linux 网桥 (br0)  ←── 物理网卡 (enpXsY) 桥接在此
         │
         ▼
    物理网络

    NAT 模式：virbr0 + iptables/nftables MASQUERADE
      优点：零配置、免打扰宿主网络
      缺点：外部无法主动访问 guest

    桥接模式：guest 与宿主同网段，双向可达（生产常用）
    直通模式：SR-IOV VF / macvtap，绕过软件交换机，性能最高
EOF
ok "演示结束"
