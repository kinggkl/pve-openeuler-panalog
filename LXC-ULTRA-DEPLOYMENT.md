# Panalog Ultra 在 LXC 容器上的部署验证（2026-08-09 实测）

> 定位：**部署形态研究文档**。验证 Panalog Ultra（独立安装包）能否运行在 LXC 容器（Ubuntu / openEuler）中，以及 LXC 是否可作为超轻部署形态。
> 依据：PVE localpve（172.16.128.116）上 LXC 300（Ubuntu 24.04）与 LXC 301（openEuler 24.03 LTS-SP4）全流程实测，2026-08-09。
> 结论：**LXC 形态成立**——安装流程完整通过，7/7 服务运行，HTTPS web 界面可用；panaos（数据面）依赖宿主 hugepage，当前宿主配置只支持单实例。

---

## 一、结论摘要

| 验证项 | Ubuntu 24.04 LXC | openEuler 24.03 LXC |
|---|---|---|
| install.sh 安装流程 | ✅ 完整通过 | ✅ 完整通过 |
| 7/7 服务（ultradb/insert_db/panaos/httpd/msgsync/taskdispatcher/monitor） | ✅ Running | ✅ Running |
| panaos 就绪（floweye cfgload=1） | ✅ | ✅ |
| HTTPS 443 / UltraDB 8123 | 200 / Ok. | 200 / Ok. |
| 开机自启 | ⚠️ 需手动处理 rc-local | ✅ 自动（rc.local→rc.d/rc.local） |

**前提条件**：PVE 宿主必须分配 2M hugepage（≥72 页 = 144M），且**同一时刻只能运行一个 Panalog LXC 实例**（大页被占满后 panaos PANIC）。

---

## 二、为什么验证 LXC

- 官方路线是"独立安装包 + 标准发行版"（openEuler 已验证）；LXC 是比 VM 更轻的容器形态（共享宿主内核、秒级启动）
- 关键问题：Panalog 数据面 panaos 需要 hugepage（2M 大页 71+ 页），LXC 容器内 `/sys` 只读无法自行分配——验证宿主分配后容器内是否可用
- 顺带验证了发行版无关性：install.sh 含 Ubuntu 分支（lib64 拷贝 + rc-local 逻辑），openEuler 走 RPM 系路径

## 三、环境

| 项 | 值 |
|---|---|
| PVE | localpve，宿主内核 7.0.12-1-pve |
| LXC 300 | Ubuntu 24.04 standard 模板，特权容器（unprivileged=0），4 核/8G/16G |
| LXC 301 | openEuler 24.03 LTS-SP4（手工模板，见第四节），特权容器，4 核/8G/16G |
| 安装包 | PanalogUltra_JIUZHANG r1p4 Linux5 install.tar.gz（319M，与 VM 110 同源） |
| 数据盘 | 选 `/`（LXC 无块设备；install.sh `all_disks` 初始含 `/`） |

## 四、openEuler LXC 模板制作（复现路径）

PVE 官方模板源无 openEuler，从官方 docker 镜像转制：

```bash
# 1. 下载官方 docker 镜像（44M）
wget https://repo.openeuler.org/openEuler-24.03-LTS-SP4/docker_img/x86_64/openEuler-docker.x86_64.tar.xz

# 2. 解出 layer 作为 rootfs（单层镜像，manifest.json 确认）
xz -dk openEuler-docker.x86_64.tar.xz
tar xf oe-docker.tar <layer-hash>.tar && tar xf <layer-hash>.tar -C oe-rootfs

# 3. chroot 装 systemd 与运行依赖（docker 镜像无 systemd；需注入 resolv.conf）
docker run --rm --privileged -v /tmp/oe-rootfs:/rootfs debian:bullseye-slim bash -c '
  cp /etc/resolv.conf /rootfs/etc/resolv.conf
  mount --bind /proc /rootfs/proc && mount --bind /sys /rootfs/sys && mount --bind /dev /rootfs/dev
  chroot /rootfs /bin/bash -c "dnf install -y systemd chrony cronie net-tools xfsprogs tar"
'

# 4. 补 /etc/redhat-release（PVE post_create_hook 硬依赖，缺失报错）
echo "openEuler release 24.03 (LTS-SP4)" > oe-rootfs/etc/redhat-release

# 5. 打包（需 root 权限读 shadow 等 0600 文件，用容器内 root 打包）
docker run --rm -v /tmp:/out debian:bullseye-slim bash -c 'tar czf /out/oe-lxc-rootfs.tar.gz -C /out/oe-rootfs .'

# 6. 上传并创建容器
#    PVE 侧：scp 到 /var/lib/vz/template/cache/ → pct create
pct create 301 local:vztmpl/oe-lxc-rootfs.tar.gz \
  --hostname oe-panalog-test --storage local \
  --memory 8192 --cores 4 \
  --net0 name=eth0,bridge=vmbr0,ip=172.16.128.120/24,gw=172.16.128.1 \
  --unprivileged 0 --features nesting=1 --rootfs local:16 --onboot 0
```

**ostype 必须显式设为 `unmanaged`**：PVE 枚举不识别 openEuler（报 `value 'openeuler' does not have a value in the enumeration`），会导致 pct config 校验失败、PVE 不应用系统特定默认设置。

## 五、安装流程与坑（LXC 特有）

```bash
# 容器内预装依赖（Ubuntu：apt；openEuler：dnf）
#   chrony cron net-tools xfsprogs tar（openEuler 另需 iproute iputils——最小镜像无 ss/ip/ping）

# 预补 libssl（关键坑，见下）
# 安装（数据盘选 /，预喂交互输入）
printf "Y\n/\nN\n" | bash install.sh eth0 <IP> 255.255.255.0 172.16.128.1
```

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 1 | **宿主内核 ≥7 触发 install.sh 非 6.x 分支** | `uname -r` 显示宿主 7.0.12 → `KERNEL_MAJOR=="6"` 走 else → **删除 package 自带 libssl/libcrypto** → 依赖 `libssl.so.1.1` 的二进制（curl 等）起不来 | 安装前从已装实例预拷贝 `libssl.so.1.1.1k` + `libcrypto.so.1.1.1k` 到 `/lib64/`（RPM 系）/ `/lib/x86_64-linux-gnu/`（Debian 系）并 ldconfig。**真实 6.x 内核 VM 不触发** |
| 2 | **LXC 无 DHCP 客户端**（手工 rootfs） | eth0 无 IP，dnf 下载失败 | `pct set --net0 ...ip=静态IP/24,gw=...`（PVE/LXC 层 netlink 直接配置，不依赖容器内工具） |
| 3 | **hugepage 必须宿主分配** | panaos `PANIC: at least 71 superpage(2M) need` | 宿主 `echo 96 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages`（192M，可回滚 echo 0） |
| 4 | **大页冲突：单实例限制** | monitor 服务自动拉起 panaos 占满全部大页；第二个实例启动时 0 free → PANIC | 同一时刻仅运行一个 Panalog LXC；切换实例前先停旧实例 |
| 5 | **数据盘只能选 `/`** | 无 `/dev/sd*` 块设备 | install.sh 支持 `/`（`all_disks` 初始含 `/`，走 "Use root directory storage."） |
| 6 | openEuler 缺 `/etc/redhat-release` | `pct create` 报 `can't open '/etc/redhat-release'` | 模板 rootfs 补该文件 |
| 7 | openEuler 最小镜像缺工具 | `ss`/`ip`/`ping` 不存在（install.sh 检查 ss） | `dnf install iproute iputils`（openEuler 包名是 **iproute**，不是 iproute2） |

## 六、开机自启差异

- **openEuler LXC**：`/etc/rc.local -> rc.d/rc.local`（系统符号链接），install.sh 通过链接写入 `ipectrl start`；openEuler rc-local 服务（enabled-runtime）开机执行 → **重启后自动运行**（实测 301 重启后 panaos 自动就绪）
- **Ubuntu LXC**：install.sh Ubuntu 分支启用 rc-local 服务；但 PVE Ubuntu 模板的 `/etc/rc.local` 可能是符号链接，需确认写入路径

## 七、收益对比与判定

| 形态 | 系统占用 | 多实例 | 特点 |
|---|---|---|---|
| openEuler VM（金镜像，精简后） | ~3.1G | ✅ | 官方验证、独立内核 |
| openEuler LXC | ~2.5G（清安装包后） | ❌（大页冲突） | 共享宿主内核、启动秒级、管理轻 |

**判定**：LXC 未带来数量级缩小（Panalog 本体 + 数据面约 2G+），且单实例受限。**生产首选仍为 VM 形态**；LXC 适合资源紧张的单一实例场景或快速验证环境。

## 八、时间线（2026-08-09）

| 时间 | 事件 |
|---|---|
| 19:35-19:47 | LXC 300（Ubuntu 24.04）创建、依赖、传包、install.sh 安装完成 |
| 19:47-19:55 | Ubuntu LXC 服务启动验证；panaos 失败 → 根因定位 hugepage |
| 19:55 | 宿主分配 72 页 2M hugepage → Ubuntu LXC panaos READY，7/7 服务 + web 200 |
| 20:00-20:05 | openEuler docker 镜像转 LXC 模板（systemd/redhat-release/打包上传） |
| 20:05-20:12 | LXC 301 创建（ostype unmanaged、静态 IP）、安装完成 |
| 20:12+ | openEuler LXC panaos 验证（大页冲突排查：300 monitor 自动拉起占满大页 → 停 300 → 增至 96 页）→ 7/7 服务 + web 200 + 开机自启确认 |

## 九、风险与遗留

- 风险：LXC 内数据面（panaos）未做流量压测，veth 网卡吞吐能力未验证；宿主大页为物理内存预留（192M），长期保留需评估
- 遗留：宿主大页 96 页与测试容器 300/301 保留状态待定；Ubuntu LXC 的 rc.local 自启未做重启验证（301 已确认）
- 后续可选：LXC 形态 + 数据盘（宿主挂载/loop 设备）压测；多实例方案（增大宿主大页至 2×72+ 页并验证 monitor 行为）
