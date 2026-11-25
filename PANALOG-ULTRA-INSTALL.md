# Panalog Ultra（Panalog2.0）在 openEuler 上的安装实录

> 实测日期：2026-08-09 · VM 110（openEuler 24.03 SP4，4核/8G/40G系统+100G数据盘）
> 结论：**Panalog2.0 = Panalog Ultra，官方提供独立 install 包，可直接全新安装在 openEuler 上**（不需要 Panabit OS 基础）

## 一、软件包

| 包 | 说明 |
|---|---|
| `PanalogUltra_JIUZHANGr1p4_20260519_Linux5_install.tar.gz`（319M） | **全新安装包**（自带 nginx/php-fpm/fluent-bit/UltraDB 完整运行时 + install.sh） |
| `PanalogUltra_JIUZHANGr1p6_20260807_Linux5.tar.gz`（30.76M） | 升级包（仅用于已装 Ultra 的系统在线升级，**不能全新安装**） |

> install 包不在官网公开下载中心（升级包/安装包/APP/周边文件分类均无），需通过官方渠道获取。
> 最新升级包：Panabit 官网下载中心 → 升级包 → Panalog → `PanalogUltra_JIUZHANGr1p6_20260807_Linux5.tar.gz`（2026-08-07）。

## 二、openEuler 前置依赖（实测必装）

```bash
dnf install -y tar xfsprogs net-tools cronie chrony
```

| 包 | 必要性 | 实测情况 |
|---|---|---|
| `tar` | 必装 | openEuler 最小化默认无 tar，无法解包 |
| `xfsprogs` | **必装（最坑）** | install.sh 前置检查**漏检** mkfs.xfs，装到一半才报 `mkfs.xfs: command not found`；必须先装 |
| `net-tools` | 检查项 | openEuler 24.03 SP4 默认已带 |
| `cronie` | 检查项 | 默认已带（cron active） |
| `chrony` | 检查项 | **默认缺失**，需装并 `systemctl enable --now chronyd` |

硬件要求（install.sh 检查）：root 用户、Linux、**≥4 物理核**、ss 命令。

## 三、安装流程

```bash
# 1. 上传到 /root，解压
cd /root && tar xzf PanalogUltra_JIUZHANGr1p4_20260519_Linux5_install.tar.gz

# 2. 执行（4 参数 = 网卡/IP/掩码/网关，免网络交互）
sh install.sh ens18 198.51.100.11 255.255.255.0 198.51.100.1

# 3. 交互项：数据盘选择
#    "Please select a disk for data: " → 输入数据盘（如 /dev/sdb）
#    脚本自动：dd 清签名 → mkfs.xfs → 挂载 /logdata → 写 fstab
#    若 /logdata 已挂载则跳过此交互；也可选 "/" 用根分区存储
#    ⚠️ 数据盘完全由 install.sh 处理（挂 /logdata）——建机脚本里的 /data 手动挂载步骤
#       仅适用于非 Ultra 通用场景，装 Panalog Ultra 时跳过

# 4. 装完提示重启（Y/N），建议先 N 检查输出，再重启验证自启动
```

> 自动化交互：用 expect 脚本处理（数据盘选择 + 重启询问），比 pty 直通可靠。

## 四、安装产物

| 路径 | 内容 |
|---|---|
| `/etc/PG.conf` | PGPATH=/usr/panabit、DATAPATH=/logdata、ADMIN_PORT、CPULIST |
| `/conf/ifadmin.conf` | ADMIN_IP / ADMIN_MASK / GATEWAY |
| `/usr/panabit/bin/ipectrl` | 启停控制（`ipectrl start/stop`） |
| `/etc/rc.local` | 自启动 `ipectrl start` |
| `/usr/local/ultradb/` | UltraDB（ClickHouse 系） |
| `/usr/local/nginx`、`/usr/local/php` | Web 管理（HTTPS 443） |
| `/logdata` | 数据存储（100G 数据盘，fstab 持久化） |
| `/conf/web/account/` | 默认管理账号（密码为哈希，需官方说明确认） |

## 五、验证结果（实测）

```bash
# 重启后自启动
ps aux | grep -E "ultradb|nginx|php-fpm"   # 全部运行
ss -tlnp | grep -E ":443|:8123|:9000"      # nginx 443 + ultradb 8123/9000

# Web 界面
curl -sk https://<IP>/ -o /dev/null -w "%{http_code}"   # 200

# UltraDB 健康
curl -s http://127.0.0.1:8123/ping                      # Ok.

df -h /logdata                                          # 数据盘挂载
```

## 六、已知坑

1. **xfsprogs 漏检**：install.sh 前置检查不含 mkfs.xfs，openEuler 必须先装，否则中途报错（重跑即可，数据盘会被重新初始化）
2. **line 524 `warning` 函数未定义**：SELinux 禁用分支的瑕疵，报 `command not found` 但无害
3. **盘序不固定**：重启后 sdX 可能互换（实测 sda/sdb 反转），数据盘选择以 `lsblk` 为准
4. **默认账号密码为哈希**：`/conf/web/account/user_*` 内 pass 字段，需从官方说明获取默认值
5. **交互自动化**：install.sh 的 `read` 在管道/pty 直通下可能丢失输入，用 expect 最稳
