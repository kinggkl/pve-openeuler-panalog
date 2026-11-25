#!/bin/bash
# ============================================================
# PVE 快速构建 openEuler 24.03 VM —— 用于部署 PanaLog Ultra
# 标准镜像模式：从你自己的母盘（已固化 qemu-guest-agent + root SSH 修复）克隆
# 适用: pve-host (198.51.100.10), pve-manager 9.2.x
# 用法: bash build-openeuler-panalog.sh [VMID] [系统盘G] [数据盘G]
# 例:   bash build-openeuler-panalog.sh 110 40 100
# 前置: 标准镜像模板（制作方法见 README.md 第一节）
#       /var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-standard.qcow2
# ============================================================
set -euo pipefail

VMID=${1:-110}
DISK_SYS=${2:-40}
DISK_DATA=${3:-100}
NAME="panalog-ultra-euler"
TEMPLATE="/var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-standard.qcow2"

[ -f "$TEMPLATE" ] || { echo "❌ 标准镜像模板不存在: $TEMPLATE（先按 README 第一节制作）"; exit 1; }
qm status $VMID >/dev/null 2>&1 && { echo "❌ VMID $VMID 已存在"; exit 1; }

echo "==> 1/5 创建 VM 骨架 (${NAME}, ${VMID})"
qm create $VMID --name "$NAME" --memory 8192 --cores 4 --cpu host \
  --ostype l26 --scsihw virtio-scsi-pci \
  --net0 virtio,bridge=vmbr0 --serial0 socket --vga qxl \
  --agent enabled=1 \
  --boot order=scsi0

echo "==> 2/5 导入系统盘 (标准镜像 → scsi0, ${DISK_SYS}G)"
# --format=qcow2 必须显式指定：默认导入为 raw（vm-XXX-disk-0.raw），
# 与下方 scsi0 的 qcow2 路径不一致会导致 volume does not exist
qm importdisk $VMID "$TEMPLATE" local --format=qcow2
qm set $VMID --scsi0 local:$VMID/vm-$VMID-disk-0.qcow2
CUR=$(qemu-img info /var/lib/vz/images/$VMID/vm-$VMID-disk-0.qcow2 \
      | awk '/virtual size:/{gsub(/[^0-9]/,"",$3); print $3}')
[ "$CUR" != "$DISK_SYS" ] && qm resize $VMID scsi0 ${DISK_SYS}G

echo "==> 3/5 数据盘 scsi1 ${DISK_DATA}G (PanaLog Ultra 日志/数据)"
qm set $VMID --scsi1 local:${DISK_DATA},format=qcow2

echo "==> 4/5 启动"
qm start $VMID

echo "==> 5/5 等待 guest agent 就绪并定位 IP"
sleep 20
IP=""
for i in $(seq 1 15); do
  # qm guest cmd network-get-interfaces 顶层即为数组（非 {"return": [...]}）
  IP=$(qm guest cmd $VMID network-get-interfaces 2>/dev/null | python3 -c "
import json,sys
try:
    for iface in json.load(sys.stdin):
        for addr in iface.get('ip-addresses',[]):
            a=addr.get('ip-address','')
            if addr.get('ip-address-type')=='ipv4' and not a.startswith('127.'):
                print(a); sys.exit()
except Exception: pass
" 2>/dev/null | head -1)
  [ -n "$IP" ] && break
  sleep 10
done
[ -n "$IP" ] && echo "✅ VM $VMID 就绪: $IP (root，密码为标准镜像模板预置值)" || echo "⚠️ 未定位 IP，请到 PVE Web 控制台查看"

cat <<'EOF'
──────────────────────────────────────────────
后续（VM 内）:
  1. 数据盘初始化（mkfs 需在 VM 内执行；盘符以 lsblk 为准，可能为 sda 或 sdb）:
       lsblk   # 识别新盘（100G 无分区的那块）
       echo -e "n\np\n1\n\n\nw\n" | fdisk /dev/<盘符>
       mkfs.xfs /dev/<盘符>1
       mkdir -p /data && mount /dev/<盘符>1 /data
       echo "UUID=$(blkid -s UUID -o value /dev/<盘符>1) /data xfs defaults 0 0" >> /etc/fstab
  2. 安装 PanaLog Ultra（见 PANALOG-ULTRA-INSTALL.md；数据盘交给 install.sh 处理，挂 /logdata）
──────────────────────────────────────────────
EOF
