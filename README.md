# PVE 快速构建 openEuler VM —— PanaLog Ultra 部署方案

> 适用：localpve（172.16.128.116，pve-manager 9.2.4）· 2026-08-09
> 依据：VM 102（openEuler-2403-SP4）实际构建与调测经验，已实测核实

## 一、方案总览

| 项 | 值 |
|---|---|
| 系统 | openEuler 24.03 LTS SP4（内核 6.6.0-159.4.3.154.oe2403sp4） |
| 模板 | `/var/lib/vz/template/qcow2/openEuler-24.03-LTS-SP4-x86_64.qcow2`（虚拟 40G/实际 2.27G，带 cloud-init） |
| 构建方式 | `qm create` + `qm importdisk` + cloud-init（PVE 原生，无需外部工具） |
| 建议规格 | 4 核 / 8G 内存 / 系统 40G + 数据盘 100G |
| 凭据 | root，密码由环境变量 `OPENEULER_PASS` 传入（构建时必填，不入库） |
| **Guest Agent** | **已集成**（cloud-init 自动安装 qemu-guest-agent + PVE `--agent enabled=1`） |

一键执行（在 PVE 上）：

```bash
OPENEULER_PASS='<你的密码>' bash build-openeuler-panalog.sh 110 40 100
```

## 二、构建步骤（脚本内容说明）

1. **骨架**：`qm create` — cpu host、virtio-scsi-pci、virtio 网卡 bridge=vmbr0、serial0 socket（串口排障用）、`--agent enabled=1`（guest agent 通道）、boot order=scsi0
2. **系统盘**：`qm importdisk <vmid> <模板> local` 导入模板（保留虚拟 40G），`qm resize` 按需扩容
3. **数据盘**：`qm set --scsi1 local:100,format=qcow2` — virtio-scsi 支持**运行中热插拔**，无需重启
4. **cloud-init**：`--ide2 local:cloudinit --ciuser root --cipassword ... --ipconfig0 ip=dhcp`
5. **初始化 snippet**（见下方坑 #1、#7）：`--cicustom user=local:snippets/openeuler-init.yaml` — 修复 SSH + 安装启用 qemu-guest-agent
6. 启动后 IP 定位：**guest agent 优先**（`qm guest cmd network-get-interfaces`），ARP 按 MAC 兜底

## 三、已有经验 / 坑（全部实测）

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 1 | **openEuler 默认禁止 root 密码 SSH** | `#PermitRootLogin yes` 处于注释态 → SSH `Permission denied`，但串口正常 | 模板或 cloud-init `runcmd` 执行 `sed -i 's/^#PermitRootLogin yes/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl restart sshd` |
| 2 | **cloud-init 需 PVE 原生驱动** | — | 模板带 cloud-init（已核实 `CLOUD_INIT_YES`），用 `--ide2 local:cloudinit` 即可，PVE 自动生成 NoCloud 种子 |
| 3 | **virtio-scsi 热插拔** | 运行中 `qm set --scsi1` 后 VM 内立即出现 sdb | 使用 `scsihw: virtio-scsi-pci`，新增盘无需重启 |
| 4 | **mkfs 属不可代理操作** | Hermes 终端安全策略硬性阻止 `mkfs` | 数据盘格式化必须在 VM 内手动执行（脚本末尾已附命令） |
| 5 | **guest agent 集成**（已解决） | 之前 VM 102 无 agent，`qm guest cmd` 不可用 | cloud-init `packages: [qemu-guest-agent]` + `--agent enabled=1`；agent 就绪后 IP/状态/优雅关机全可用（首次安装需 1-2 分钟，脚本已做轮询等待） |
| 6 | **网络可达性** | sz-hermes 直连 172.16.128.0/24 不通 | 经 `ts-sz-secondary` 容器转发（`docker run --network container:ts-sz-secondary`） |
| 7 | **guest agent 安装依赖源** | cloud-init 装包需访问 openEuler 软件源 | VM 走 DHCP + 默认路由，源需可达；若离线环境则需模板内预装或手动 rpm |

## 四、PanaLog Ultra 部署注意事项（基于 7 月分析）

- `PanalogUltra_JIUZHANGr1p5` 是 **App 层升级包**（PHP + MySQL + 模块），此前分析结论：依赖 Panabit OS 基础（`/usr/ramdisk`、`/usr/panabit`、UltraDB/nginx/PHP/Fluent Bit）
- **风险提示**：若 Ultra 包要求 Panabit OS 运行环境，直接装 openEuler 需适配基础环境；若确认有欧拉可用的安装路径，数据盘挂 `/data` 已就绪
- 备选路径（历史已验证）：VM 201 `panalog-r7p6t-bios`（Panalog JUPITER ISO 原生安装，BIOS 模式）
- 内存建议 8G（UltraDB + PHP + nginx + Fluent Bit 同机运行）

## 五、验证清单

```bash
qm status 110                          # running
ssh root@<IP>                          # 密码登录成功（坑#1 修复后，密码用 OPENEULER_PASS 设置值）
lsblk                                  # sda 40G + sdb 100G
df -h /data                            # 数据盘已挂载
reboot && 重新登录                      # fstab 持久化验证
```

## 六、文件

```
build-openeuler-panalog.sh     一键构建脚本（VMID 可参数化）
openeuler-init.yaml            cloud-init snippet（root SSH 修复 + qemu-guest-agent 集成）
README.md                      本文档
```
