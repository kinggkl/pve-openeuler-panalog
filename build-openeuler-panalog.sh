#!/bin/bash
# ============================================================
# PVE 快速构建 openEuler 24.03 VM —— 用于部署 PanaLog Ultra
# 适用: localpve (172.16.128.116), pve-manager 9.2.x
# 用法: bash build-openeuler-panalog.sh [VMID] [系统盘G] [数据盘G]
# 例:   bash build-openeuler-panalog.sh 110 40 100
# 前置: 模板 /var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-x86_64.qcow2
#       （已确认: 虚拟40G/实际2.27G/带cloud-init）
# ============================================================
set -euo pipefail

VMID=${1:-110}
DISK_SYS=${2:-40}
DISK_DATA=${3:-100}
NAME="panalog-ultra-euler"
PASS="${OPENEULER_PASS:?用法: OPENEULER_PASS=<密码> bash build-openeuler-panalog.sh [VMID] [系统盘G] [数据盘G]}"
TEMPLATE="/var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-x86_64.qcow2"
SNIPPET="/var/lib/vz/snippets/openeuler-init.yaml"

[ -f "$TEMPLATE" ] || { echo "❌ 模板不存在: $TEMPLATE"; exit 1; }
qm status $VMID >/dev/null 2>&1 && { echo "❌ VMID $VMID 已存在"; exit 1; }

echo "==> 1/6 创建 VM 骨架 (${NAME}, ${VMID})"
qm create $VMID --name "$NAME" --memory 8192 --cores 4 --cpu host \
  --ostype l26 --scsihw virtio-scsi-pci \
  --net0 virtio,bridge=vmbr0 --serial0 socket --vga qxl \
  --agent enabled=1 \
  --boot order=scsi0

echo "==> 2/6 导入系统盘 (模板 → scsi0)"
qm importdisk $VMID "$TEMPLATE" local
qm set $VMID --scsi0 local:$VMID/vm-$VMID-disk-0.qcow2
CUR=$(qemu-img info /var/lib/vz/images/$VMID/vm-$VMID-disk-0.qcow2 \
      | awk '/virtual size:/{gsub(/[^0-9]/,"",$3); print $3}')
[ "$CUR" != "$DISK_SYS" ] && qm resize $VMID scsi0 ${DISK_SYS}G

echo "==> 3/6 数据盘 scsi1 ${DISK_DATA}G (PanaLog Ultra 日志/数据)"
qm set $VMID --scsi1 local:${DISK_DATA},format=qcow2

echo "==> 4/6 cloud-init (root, 密码来自 OPENEULER_PASS, DHCP)"
qm set $VMID --ide2 local:cloudinit \
  --ciuser root --cipassword "$PASS" \
  --ipconfig0 ip=dhcp
# 修复 openEuler 默认禁止 root 密码 SSH 登录（历史坑）
if [ -f "$SNIPPET" ]; then
  qm set $VMID --cicustom "user=local:snippets/openeuler-sshd.yaml"
  echo "    → 已挂载 sshd 修复 snippet"
else
  echo "    ⚠️ 无 snippet ${SNIPPET}，启动后需手工执行:"
  echo "       sed -i 's/^#PermitRootLogin yes/PermitRootLogin yes/' /etc/ssh/sshd_config"
  echo "       systemctl restart sshd"
fi

echo "==> 5/6 启动"
qm start $VMID

echo "==> 6/6 等待启动并定位 IP（guest agent 优先，ARP 兜底）"
sleep 30
IP=""
for i in $(seq 1 12); do
  # 优先: qemu-guest-agent（cloud-init 安装需 1-2 分钟）
  IP=$(qm guest cmd $VMID network-get-interfaces 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for iface in d.get('return',[]):
        for addr in iface.get('ip-addresses',[]):
            a=addr.get('ip-address','')
            if addr.get('ip-address-type')=='ipv4' and not a.startswith('127.'):
                print(a); sys.exit()
except Exception: pass
" 2>/dev/null | head -1)
  [ -n "$IP" ] && break
  # 兜底: ARP 按 MAC 匹配
  MAC=$(qm config $VMID | awk '/net0:/{print $2}' | cut -d= -f2)
  IP=$(ip neigh | grep -i "$MAC" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  [ -n "$IP" ] && break
  sleep 10
done
[ -n "$IP" ] && echo "✅ VM $VMID 就绪: $IP (root，密码见 OPENEULER_PASS)" || echo "⚠️ 未定位 IP，请到 PVE Web 控制台查看"

cat <<'EOF'
──────────────────────────────────────────────
后续（VM 内）:
  1. 数据盘初始化（mkfs 需在 VM 内执行）:
       echo -e "n\np\n1\n\n\nw\n" | fdisk /dev/sdb
       mkfs.xfs /dev/sdb1
       mkdir -p /data && mount /dev/sdb1 /data
       echo "UUID=$(blkid -s UUID -o value /dev/sdb1) /data xfs defaults 0 0" >> /etc/fstab
  2. 安装 PanaLog Ultra（见 README.md 注意事项）
──────────────────────────────────────────────
EOF
