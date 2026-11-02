# chenlongos — cv1812-edu SD 卡镜像

目标板：**cv1812_edu_sd** (RISC-V musl, sg2002 SoC)

---

## 快速开始

```bash
# Step 1: 克隆 chenlongos SDK
git clone -b cv1812-edu https://github.com/chenlongos/chenlong.git chenlong
cd chenlong

# Step 2: 下载依赖
./scripts/repo_clone.sh --gitclone scripts/subtree_chenlongos.xml

# Step 3: 应用 sdk_patch（修正 u-boot / buildroot 配置）
./scripts/apply_patch.sh

# Step 4: 一键构建（最小权限 — 普通用户运行，mount 时自动 sudo）
./scripts/build_chenlongos.sh

```

---

## 输出产物

构建完成后，所有产物在 `chenlongos_output/` 下：

| 文件 | 大小 | 说明 |
|------|------|------|
| `chenlongos.img` | ~164M | 完整 SD 卡镜像（fdisk 分区表 + FAT + ext4） |
| `rawimages/boot.fat` | 60M | FAT32 分区镜像（fip.bin + starryos.uimg + dtb） |
| `rawimages/rootfs.ext4` | 100M | ext4 精简 rootfs 分区镜像 |
| `rootfs/` | ~53M | 精简后的 rootfs 目录（含 AKA-00 30M + akars/cvimodel，调试用） |
| `fat/` | — | FAT 分区文件（debug 用） |

---

## 构建链路

```
./scripts/build_chenlongos.sh
│
├── Step 1  build_fip_bin
│   └── source build/cvisetup.sh → defconfig cv1812cp_licheerv_nano_sd
│       → sed 关闭 CONFIG_ENABLE_FREERTOS
│       → build_fsbl  (u-boot → opensbi → fsbl → fip.bin)
│
├── Step 2  build_kernel  (StarryOS, Docker 内编译)
│   └── repo_clone tgoskits 仓库 (分支: chenlong-dev；已存在则校验并切换分支)
│       → 启动/复用 Docker 容器 ghcr.io/rcore-os/tgoskits-container
│       → apt install u-boot-tools (仅首次)
│       → cargo starry defconfig aka-00-sg2002
│       → cargo starry build
│       → 产物 target/riscv64gc-unknown-linux-musl/release/starryos.uimg
│          + os/StarryOS/configs/board/aka-00-sg2002.dtb → FAT_DIR
│          (其他 target 目录下的历史 uimg 不会被误拷，见 build_kernel Step 5 回退逻辑)
│
├── Step 3  build_buildroot (仅获取 usr/sbin)
│   └── make defconfig cvitek_CV181X_musl_riscv64_defconfig (按需，已配置则跳过)
│       → make -j$(nproc)
│       → 清空 BR2_ROOTFS_OVERLAY (CV181X/overlay 不存在)
│
├── Step 4  download_tpu_sdk
│   └── curl GitHub Release cvitek_tpu_sdk_cv181x_musl_riscv64_rvv.tar.gz
│       → 解压到 dependency/cvitek_tpu_sdk/
│
├── Step 5  build_apps  (板端应用，host-tools riscv64 musl 交叉编译)
│   ├── wifi_switch   tgoskits apps/starry/picoclaw-cli/wifi_switch.c → /usr/bin
│   ├── pinmux_tool   AKA-00 utils/pinmux-tool            → /usr/bin
│   ├── AKA-00        AKA-00 cpp/ (make package) → /root/AKA-00
│   └── akars         akars race 分支 (cargo build, Xuantie V3.4.0) → /root/akars
│
├── Step 6-11  rootfs 组装
│   ├── create_rootfs_structure   (目录骨架)
│   ├── simplify_bin              (busybox + 软链接)
│   ├── simplify_sbin             (rootfs/common_musl_riscv64/sbin)
│   ├── simplify_usr_bin          (同上 + busybox-full + zcip.script)
│   ├── extract_usr_sbin          (从 buildroot rootfs 提取)
│   └── build_lib                 (libc / libgcc / libstdc++ / TPU libs / OpenCV)
│
└── Step 12-13  安装与打包
    ├── install_rootfs_overlay (rootfs_overlay/ + 应用产物 → /etc/init.d、/usr/bin、/root)
    └── pack 镜像 (有免密 sudo 时用 loop+mount，否则自动降级为纯用户态)
        ├── pack_ext4    (sudo: losetup + mount ／ 免 root: mke2fs -d + fakeroot 属主)
        ├── pack_fat     (sudo: losetup + mount ／ 免 root: mcopy)
        └── pack_sd_image(sudo: loop 上建两个分区 ／ 免 root: dd 按分区偏移拼接)
```

---

## 板端应用与开机初始化

镜像 ext4 分区内的定制内容（静态部分在源码库 [rootfs_overlay/](rootfs_overlay/)，二进制由构建脚本编入）：

| 路径 | 来源 | 说明 |
|---|---|---|
| `/root/AKA-00/` | `AKA-00` 仓库 `chenlongos` 分支 `cpp/` | aka-capp 部署目录（含 config.toml / static / tools / demo 模型） |
| `/root/akars` + `akars.toml` + `yolov8n_tennis_v4.cvimodel` | `akars` 仓库 `race` 分支 | TPU 推理 + 底盘/机械臂控制应用 |
| `/usr/bin/wifi_switch` | `tgoskits` `apps/starry/picoclaw-cli/wifi_switch.c` | Station / SoftAP 运行时切换 |
| `/usr/bin/pinmux_tool` | `AKA-00` `utils/pinmux-tool/` | 把 UART1/UART2 引脚路由到 `/dev/ttyS1`、`/dev/ttyS2` |
| `/usr/bin/starry-run-case-tests` | `rootfs_overlay/usr/bin/` | 开机初始化入口（见下） |
| `/usr/bin/sync-daemon.sh` | `rootfs_overlay/usr/bin/` | 周期性 `sync` 守护（内核无周期回写） |
| `/etc/init.d/starry-{pinmux,sync,akars}` | `rootfs_overlay/etc/init.d/` | 三个幂等的初始化服务 |

`chenlong-dev` 分支的 StarryOS `init.sh` 会在登录 shell 之前同步执行 `/usr/bin/starry-run-case-tests`，该脚本依次调用
`starry-pinmux`（`exec /usr/bin/pinmux_tool`）→ `starry-sync`（后台 `sync-daemon`）→ `starry-akars`
（`cd /root` 后 `setsid nohup ./akars yolov8n_tennis_v4.cvimodel --motor /dev/ttyS1 --arm /dev/ttyS2`，日志 `/run/akars.log`，pidfile `/run/akars.pid`）。
因此每个服务脚本都必须立即返回，否则进不了登录 shell。

---

## 最小权限设计

脚本整体以 **普通用户** 运行，仅在真正需要 root 的操作时自动 `sudo`；若当前环境
拿不到免密 sudo（无人值守/CI/无 tty 输密码），打包阶段会自动降级为完全不需要 root 的路径。

| 阶段 | 是否 sudo | 原因 |
|---|---|---|
| repo_clone / git clone | ❌ | — |
| fip.bin 编译 | ❌ | user 权限即可 |
| Docker cargo build | ❌ | Docker daemon 自行处理 |
| buildroot 编译 | ❌ | user 权限即可 |
| TPU SDK 下载 | ❌ | 普通 curl |
| rootfs 组装 | ❌ | 普通文件操作 |
| dd 创空文件 | ❌ | 普通文件 |
| mkfs.ext4 / mkfs.vfat 普通文件 | ❌ | — |
| **mount / umount loopdev** | **✅**（无 sudo 时跳过） | loop 设备属 root |
| **losetup / partprobe** | **✅**（无 sudo 时跳过） | loop 设备管理 |

免 root 打包等价的用户态路径（差异仅在打包方式，产物一致）：

| 分区 | 有 sudo | 无免密 sudo |
|---|---|---|
| ext4 | `losetup` + `mount` + `cp -a` | `mke2fs -d` 直填目录树 |
| FAT | `losetup` + `mount` + `cp -a` | `mcopy -s -m -o` |
| 整卡 | loop 上重建 p1/p2 再填充 | `dd ... seek=<分区起始扇区> conv=notrunc` 拼接 |

镜像内文件属主统一为 `root:root`（免 root 路径用 `fakeroot` 虚拟 `chown -R 0:0`，未安装 fakeroot 时会 `warn`）。`/tmp` 强制 `1777`。

退出码自动 `exit 1`，Ctrl+C / 崩溃时全局 cleanup trap 自动卸载 mount、解绑 loop 设备，不残留脏状态。

---

## 资源复用与跳过

| 场景 | 行为 | 强制重编 |
|---|---|---|
| `fip.bin` 已在 install/ 下 | 跳过 Step 1 | `FORCE=1` |
| starryos.uimg + dtb 已在 FAT_DIR | 跳过 Step 2 | `FORCE=1` |
| buildroot rootfs.tar.xz 已存在 | 跳过 Step 3 | 删除 buildroot-2021.05/output 或 `FORCE=1` |
| akars / AKA-00 / 两个工具的产物已存在 | 跳过对应应用编译 | `FORCE=1` |
| .config 已是当前 defconfig | 跳过 `make defconfig` | — |
| mkimage 已在容器内 | 跳过 apt install | — |

---

## 环境依赖

- **OS**: Linux (测试于 Ubuntu 24.04)
- **工具**: git, curl/wget, gcc, make, dd, python3, fdisk, mkfs.ext4, mkfs.vfat, losetup, mount, sudo
- **打包（无 sudo 时的免 root 路径）**: mke2fs (e2fsprogs ≥ 1.43，需 `-d`)、mkfs.vfat、mcopy (mtools)、sfdisk、fakeroot
- **Docker**: 用于 StarryOS 内核编译（ghcr.io/rcore-os/tgoskits-container:latest）
- **Rust**: cargo + rustup；target/工具链由 akars 自己的 `rust-toolchain.toml` + `scripts/setup.sh` 管理（稳定版 `stable` + `riscv64gc-unknown-linux-musl`）
- **cmake**: AKA-00 交叉编译 mbedTLS 需要
- **磁盘空间**: 约 5–10 GB（buildroot 输出 + TPU SDK + tgoskits 源码 + 板端应用）
- **内存**: 建议 ≥ 4 GB（buildroot 和 cargo build 并行编译）

---

## 清理

```bash
# 只清 chenlongos 产出物（保留已下载仓库和 Docker 容器）
./scripts/build_chenlongos.sh clean

# 或手动
rm -rf chenlongos_output/ dependency/
docker rm -f tgoskits          # 连容器一起删（下次会重建）
```

---

## 已知限制

- **TPU 功能是可选的**：如果不下载 TPU SDK，镜像仍可正常构建，只是缺少 TPU OpenCV 相关库，且 AKA-00 会退化 `WITH_TPU=0` 编译、akars 会被跳过。
- **AKA-00 首次编译需联网**：交叉编译 libjpeg（ijg.org）与 mbedTLS（GitHub clone）依赖网络；失败时只告警，镜像照常产出（仅缺 `/root/AKA-00`）。
- **应用源码与产物**：`akars-race/`、`AKA-00-chenlongos/` 由构建脚本自行克隆（`.gitignore` 已排除），无需 `repo_clone.sh` 预下载。
- **akars 必须用它自带的 Xuantie V3.4.0 工具链**：仓库里的 `host-tools`（gcc 10.2 + 旧 binutils）无法链接 Rust 1.9x 的 rlib（报 `Invalid or unknown z ISA extension: 'zifencei'`）。首次构建时脚本会自动跑 `akars/scripts/setup.sh` 下载并校验该工具链（约 210MB，需联网）；已安装则跳过。
- **ext4 分区容量**：`install_rootfs_overlay` 会在 rootfs 超过 `EXT4_SIZE_MB` 的 90% 时报错，按提示调大 `EXT4_SIZE_MB` 即可。
- **Docker loopback 端口 2222**：tgoskits-container 默认使用 2222，如果冲突请修改脚本开头的 `TGOSKITS_DOCKER_NAME`（容器名）或 `docker run -p` 参数。
