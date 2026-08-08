# PVE 快速构建 openEuler VM —— PanaLog Ultra 部署方案

> 适用：localpve（172.16.128.116，pve-manager 9.2.4）· 2026-08-09
> 依据：VM 110 实测验证（金镜像方案），此前 VM 102 经验作为对比基线

## 一、方案总览

| 项 | 值 |
|---|---|
| 系统 | openEuler 24.03 LTS SP4（内核 6.6.0-159.4.3.154.oe2403sp4） |
| **金镜像模板** | `/var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-agent.qcow2`（虚拟 40G/实际 2.5G） |
| 模板内容 | 已固化：**qemu-guest-agent 已装并启用** + **root SSH 密码登录已修复** + host key 已生成 |
| 构建方式 | `qm create` + `qm importdisk --format=qcow2`（PVE 原生，无 cloud-init 依赖） |
| 建议规格 | 4 核 / 8G 内存 / 系统 40G + 数据盘 100G |
| 凭据 | root，密码为金镜像模板预置值（构建脚本不接收密码参数） |
| Guest Agent | 模板自带，`--agent enabled=1` 即通 |

一键执行（在 PVE 上）：

```bash
bash build-openeuler-panalog.sh 110 40 100
```

## 二、构建步骤（脚本内容说明）

1. **骨架**：`qm create` — cpu host、virtio-scsi-pci、virtio 网卡 bridge=vmbr0、serial0 socket（串口排障用）、`--agent enabled=1`、boot order=scsi0
2. **系统盘**：`qm importdisk <vmid> <金镜像> local --format=qcow2`（**必须显式 --format=qcow2**，否则导入为 raw 导致路径不匹配），`qm resize` 按需扩容
3. **数据盘**：`qm set --scsi1 local:100,format=qcow2` — virtio-scsi 支持运行中热插拔
4. **启动**后 guest agent 自动就绪，脚本通过 `qm guest cmd network-get-interfaces` 定位 IP

## 三、验证结果（2026-08-09 实测，VM 110）

| 验证项 | 结果 |
|---|---|
| 构建全流程 | ✅ 1-5 步无报错（importdisk qcow2 / 数据盘 / 启动） |
| SSH root 密码登录 | ✅ `SSH_LOGIN_OK`（模板已修 PermitRootLogin） |
| guest agent | ✅ `qm guest cmd network-get-interfaces` 返回 IP 172.16.128.118 |
| 数据盘 | ✅ 100G 出现（VM 110 中为 sda；VM 102 中为 sdb — **盘序不固定，以 lsblk 为准**） |
| 优雅关机 | ✅ `qm shutdown` 走 agent 通道成功 |

## 四、已有经验 / 坑（全部实测）

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 1 | **openEuler 默认禁止 root 密码 SSH** | `#PermitRootLogin yes` 注释态 → SSH `Permission denied`，串口正常 | 模板固化：`sed -i 's/^#PermitRootLogin yes/PermitRootLogin yes/' /etc/ssh/sshd_config` + 重启 sshd（金镜像已含） |
| 2 | **openEuler cloud 镜像无 cloud-init** | `rpm -q cloud-init` → not installed；依赖 cloud-init 装包/注入全部无效 | 放弃 cloud-init 路线，改**金镜像**（实例内 dnf 装好 → 关机 → 导出模板） |
| 3 | **qm importdisk 默认导入 raw** | 生成 `vm-XXX-disk-0.raw`，脚本指向 `.qcow2` → `volume does not exist` | `qm importdisk ... --format=qcow2` 显式指定 |
| 4 | **qm guest cmd 返回顶层数组** | 解析 `{"return": [...]}` 失败（实际是 `[...]`） | 直接遍历顶层数组取 ipv4 非回环 |
| 5 | **盘序不固定** | VM 110 数据盘=sda/系统=sdb；VM 102 相反 | 脚本/文档一律"以 lsblk 为准"，不用固定 /dev/sdX |
| 6 | **virtio-scsi 热插拔** | 运行中 `qm set --scsi1` 后 VM 内立即出现新盘 | 使用 `scsihw: virtio-scsi-pci`，无需重启 |
| 7 | **mkfs 属不可代理操作** | Hermes 终端安全策略硬性阻止 `mkfs` | 数据盘格式化必须在 VM 内手动执行（脚本末尾已附命令） |
| 8 | **guest agent 安装依赖源** | `dnf install qemu-guest-agent` 需 openEuler 软件源 | 金镜像制作时源需可达（本环境 repo.openeuler.org 已验证） |
| 9 | **网络可达性** | sz-hermes 直连 172.16.128.0/24 不通 | 经 `ts-sz-secondary` 容器转发（`docker run --network container:ts-sz-secondary`） |

## 五、金镜像再制作（模板更新流程）

```bash
# 1. 在一台已构建的 VM 内完成修复/升级（如装新版 agent、改密码）
# 2. 优雅关机
qm shutdown <vmid>
# 3. 导出系统盘为新模板
cp /var/lib/vz/images/<vmid>/vm-<vmid>-disk-0.qcow2 \
   /var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-agent.qcow2
# 4. 脚本 TEMPLATE 变量指向新模板
```

## 六、PanaLog Ultra 部署注意事项（基于 7 月分析）

- `PanalogUltra_JIUZHANGr1p5` 是 **App 层升级包**（PHP + MySQL + 模块），此前分析结论：依赖 Panabit OS 基础（`/usr/ramdisk`、`/usr/panabit`、UltraDB/nginx/PHP/Fluent Bit）
- **风险提示**：若 Ultra 包要求 Panabit OS 运行环境，直接装 openEuler 需适配基础环境；若确认有欧拉可用的安装路径，数据盘挂 `/data` 已就绪
- 备选路径（历史已验证）：VM 201 `panalog-r7p6t-bios`（Panalog JUPITER ISO 原生安装，BIOS 模式）
- 内存建议 8G（UltraDB + PHP + nginx + Fluent Bit 同机运行）

## 七、验证清单

```bash
qm status <vmid>                          # running
qm guest cmd <vmid> network-get-interfaces   # agent 直接拿 IP
ssh root@<IP>                             # 密码登录成功（模板已修复）
lsblk                                     # 系统盘 + 100G 数据盘（盘符以实际为准）
df -h /data                               # 数据盘已挂载
reboot && 重新登录                          # fstab 持久化验证
```

## 八、文件

```
build-openeuler-panalog.sh     一键构建脚本（金镜像模式，VMID 可参数化）
README.md                      本文档
```
