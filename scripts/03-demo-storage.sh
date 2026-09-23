#!/usr/bin/env bash
# 03-demo-storage.sh —— 演示存储虚拟化：镜像格式、精简置备、后备链、扩容
# 对应课程：模块 05
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

banner "演示 03：存储虚拟化（qemu-img）"
note "纯离线演示，只用到 qemu-img / qemu-io，不启动虚拟机"

if ! need_cmd qemu-img; then
  warn "未找到 qemu-img，请先运行： sudo $SCRIPT_DIR/02-setup-toolchain.sh"
  exit 1
fi

WORK="$(mktmpdir storage)"
cd "$WORK" || exit 1
trap 'cd /; rm -rf "$WORK"' EXIT

human_size() { du -h "$1" 2>/dev/null | cut -f1; }

step "1. 创建 qcow2 —— 声明 10G，实际按需分配（精简置备）"
run qemu-img create -f qcow2 disk.qcow2 10G
info "声明大小 (apparent) : $(du -h --apparent-size disk.qcow2 | cut -f1)"
info "实际占用 (du)       : $(human_size disk.qcow2)   ← 几乎为 0"

step "2. 创建 raw —— 立即分配全部空间"
run qemu-img create -f raw disk.raw 256M
info "raw 实际占用        : $(human_size disk.raw)   ← 与声明一致"

step "3. 往 qcow2 写 1MB 数据，观察它按需增长"
if command -v qemu-io >/dev/null 2>&1; then
  run qemu-io -c 'write 0 1M' disk.qcow2 >/dev/null
  info "写入后实际占用      : $(human_size disk.qcow2)"

  step "4. 查看分配映射（qemu-img map：哪些块真正落盘）"
  qemu-img map --output=json disk.qcow2 | head -c 300; echo
else
  warn "未找到 qemu-io，跳过写入演示"
fi

step "5. 格式转换 qcow2 → raw"
run qemu-img convert -f qcow2 -O raw disk.qcow2 converted.raw
info "converted.raw 实际占用: $(human_size converted.raw)  ← 被「撑满」到 10G"

step "6. 后备链 —— 链接克隆只存差异（overlay 依赖 base）"
run qemu-img create -f qcow2 -b disk.qcow2 -F qcow2 overlay.qcow2
info "查看整条链："
qemu-img info --backing-chain overlay.qcow2 | grep -E 'image:|backing file:|virtual size|disk size' | sed 's/^/      /'

step "7. 扩容（只增不减）"
run qemu-img resize disk.qcow2 +5G
qemu-img info disk.qcow2 | grep -E 'virtual size|disk size' | sed 's/^/    /'

step "8. 把 overlay 的改动合并回 base（qemu-img commit）"
run qemu-img commit overlay.qcow2
ok "overlay 数据已合并进 disk.qcow2"

step "9. 一致性检查"
run qemu-img check disk.qcow2

banner "小结"
info "qcow2  = 精简置备 + 快照 + 后备链，默认首选"
info "raw    = 性能最好但不省空间，适合固定大小的高性能盘"
info "后备链越长性能越差，生产要定期 blockcommit 收敛（模块 05）"
ok "演示结束，临时目录已清理"
