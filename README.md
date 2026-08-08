# PVE 快速构建 openEuler 标准镜像 —— PanaLog Ultra 部署方案

> 适用：localpve（172.16.128.116，pve-manager 9.2.4）· 2026-08-09
> 定位：**方法说明文档**。不提供任何镜像下载；按本文步骤在你的 PVE 上生成自己的标准镜像（母盘），之后重复使用。
> 依据：VM 110 实测验证（2026-08-09 全流程跑通），VM 102 经验作为对比基线

## 〇、思路（先看懂再动手）

```
官方云镜像（openEuler 24.03 SP4 qcow2）
    │  ① 建一台 VM，配置到"开箱即用"状态：
    │     装 qemu-guest-agent + 修 root SSH + 生成 host key
    ▼  ② 关机
标准镜像（母盘）── 你自己的模板，存放在你的 PVE
    │  ③ 每次需要新机器：从母盘克隆（importdisk）
    ▼
新的 openEuler VM（自带 agent + SSH，可直接用）
```

为什么要先做母盘：openEuler 云镜像**没有 cloud-init**（实测 `rpm -q cloud-init` → not installed），无法在首次启动时自动配置；而代理安装（装 agent）、SSH 修复这些操作每台都做一遍太慢。做一次母盘，之后全部秒级克隆。

---

## 一、制作标准镜像（母盘）

以下命令全部在你的 PVE 上执行。核心是三步：**建 VM → 配置 → 导出**。

### 1.1 建 VM（从官方云镜像）

```bash
VMID=110
NAME=openeuler-standard-build     # 母盘制作机，名字随意
TEMPLATE=/var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-x86_64.qcow2

# 官方 openEuler 24.03 SP4 云镜像下载地址（华为云镜像站）：
# https://mirrors.huaweicloud.com/openeuler/openEuler-24.03-LTS-SP4/virtual_machine_img/x86_64/

qm create $VMID --name "$NAME" --memory 8192 --cores 4 --cpu host \
  --ostype l26 --scsihw virtio-scsi-pci \
  --net0 virtio,bridge=vmbr0 --serial0 socket --vga qxl \
  --agent enabled=1 \
  --boot order=scsi0

# 导入系统盘（--format=qcow2 必须显式指定，否则导入为 raw 路径不匹配）
qm importdisk $VMID "$TEMPLATE" local --format=qcow2
qm set $VMID --scsi0 local:$VMID/vm-$VMID-disk-0.qcow2
qm start $VMID
```

### 1.2 配置 VM（装 agent + 修 SSH + host key）

VM 内执行（控制台或串口登录，root 密码为云镜像模板预置值）：

```bash
# ① 安装并启用 qemu-guest-agent（需软件源可达）
dnf install -y qemu-guest-agent
systemctl enable --now qemu-guest-agent

# ② 修复 root 密码 SSH 登录（openEuler 默认 #PermitRootLogin yes 注释态）
sed -i 's/^#PermitRootLogin yes/PermitRootLogin yes/' /etc/ssh/sshd_config
ssh-keygen -A        # 生成缺失的 host key
systemctl restart sshd

# ③ 验证
systemctl is-active qemu-guest-agent sshd   # 应输出 active active
grep '^PermitRootLogin' /etc/ssh/sshd_config # 应输出 PermitRootLogin yes
```

> 可选自动化：这步可通过 SSH/expect 脚本自动化；本验证中用串口执行。

### 1.3 导出为标准镜像

```bash
# 优雅关机（agent 就绪后可走 qm shutdown）
qm shutdown $VMID --timeout 30

# 复制系统盘为标准镜像（文件名自定，存到模板目录）
cp /var/lib/vz/images/$VMID/vm-$VMID-disk-0.qcow2 \
   /var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-standard.qcow2
```

**母盘完成。** 以后所有新 VM 从它克隆（见下一节）。

---

## 二、从标准镜像快速建 VM（一键脚本）

```bash
bash build-openeuler-panalog.sh 110 40 100
# 参数: VMID / 系统盘G / 数据盘G
```

脚本做的事：

1. `qm create` — cpu host、virtio-scsi-pci、virtio 网卡 bridge=vmbr0、serial0 socket、`--agent enabled=1`、boot order=scsi0
2. `qm importdisk <标准镜像> local --format=qcow2` + `qm resize` 按需扩容
3. `qm set --scsi1 local:100G` 数据盘（virtio-scsi 支持运行中热插拔）
4. `qm start` 后经 guest agent 自动定位 IP（`qm guest cmd network-get-interfaces`）

脚本顶部 `TEMPLATE=` 变量指向你自己的标准镜像路径（默认 `openEuler-24.03-LTS-SP4-standard.qcow2`）。

---

## 三、验证结果（2026-08-09 实测，VM 110）

| 验证项 | 结果 |
|---|---|
| 构建全流程 | ✅ 无报错（importdisk qcow2 / 数据盘 / 启动） |
| SSH root 密码登录 | ✅ `SSH_LOGIN_OK`（母盘已修 PermitRootLogin） |
| guest agent | ✅ `qm guest cmd network-get-interfaces` 返回 IP 172.16.128.118 |
| 数据盘 | ✅ 100G 出现（VM 110 中为 sda；VM 102 中为 sdb — **盘序不固定，以 lsblk 为准**） |
| 重启持久化 | ✅ agent + SSH 重启后均正常 |
| 优雅关机 | ✅ `qm shutdown` 走 agent 通道成功 |

---

## 四、已有经验 / 坑（全部实测）

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 1 | **openEuler 默认禁止 root 密码 SSH** | `#PermitRootLogin yes` 注释态 → SSH `Permission denied`，串口正常 | 母盘固化：`sed -i 's/^#PermitRootLogin yes/PermitRootLogin yes/' /etc/ssh/sshd_config` + 重启 sshd |
| 2 | **openEuler 云镜像无 cloud-init** | `rpm -q cloud-init` → not installed；依赖 cloud-init 装包/注入全部无效 | 放弃 cloud-init 路线，改**标准镜像（母盘）**：实例内配置好 → 关机 → 导出模板 |
| 3 | **qm importdisk 默认导入 raw** | 生成 `vm-XXX-disk-0.raw`，脚本指向 `.qcow2` → `volume does not exist` | `qm importdisk ... --format=qcow2` 显式指定 |
| 4 | **qm guest cmd 返回顶层数组** | 解析 `{"return": [...]}` 失败（实际是 `[...]`） | 直接遍历顶层数组取 ipv4 非回环 |
| 5 | **盘序不固定** | VM 110 数据盘=sda/系统=sdb；VM 102 相反 | 脚本/文档一律"以 lsblk 为准"，不用固定 /dev/sdX |
| 6 | **virtio-scsi 热插拔** | 运行中 `qm set --scsi1` 后 VM 内立即出现新盘 | 使用 `scsihw: virtio-scsi-pci`，无需重启 |
| 7 | **mkfs 属不可代理操作** | Hermes 终端安全策略硬性阻止 `mkfs` | 数据盘格式化必须在 VM 内手动执行（脚本末尾已附命令） |
| 8 | **guest agent 安装依赖源** | `dnf install qemu-guest-agent` 需 openEuler 软件源 | 制作母盘时源需可达（本环境 repo.openeuler.org 已验证） |
| 9 | **网络可达性** | sz-hermes 直连 172.16.128.0/24 不通 | 经 `ts-sz-secondary` 容器转发（`docker run --network container:ts-sz-secondary`） |

---

## 五、PanaLog Ultra 部署注意事项（基于 7 月分析）

- `PanalogUltra_JIUZHANGr1p5` 是 **App 层升级包**（PHP + MySQL + 模块），此前分析结论：依赖 Panabit OS 基础（`/usr/ramdisk`、`/usr/panabit`、UltraDB/nginx/PHP/Fluent Bit）
- **风险提示**：若 Ultra 包要求 Panabit OS 运行环境，直接装 openEuler 需适配基础环境；若确认有欧拉可用的安装路径，数据盘挂 `/data` 已就绪
- 备选路径（历史已验证）：VM 201 `panalog-r7p6t-bios`（Panalog JUPITER ISO 原生安装，BIOS 模式）
- 内存建议 8G（UltraDB + PHP + nginx + Fluent Bit 同机运行）

---

## 六、验证清单（新 VM 建好后）

```bash
qm status <vmid>                          # running
qm guest cmd <vmid> network-get-interfaces   # agent 直接拿 IP
ssh root@<IP>                             # 密码登录成功（母盘已修复）
lsblk                                     # 系统盘 + 100G 数据盘（盘符以实际为准）
df -h /data                               # 数据盘已挂载
reboot && 重新登录                          # fstab 持久化验证
```

## 七、文件

```
build-openeuler-panalog.sh     一键建机脚本（从你的标准镜像克隆，VMID 可参数化）
README.md                      本文档（含母盘制作流程）
```
