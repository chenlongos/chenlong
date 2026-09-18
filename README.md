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
| `rootfs/` | ~15M | 精简后的 rootfs 目录（调试用） |
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
│   └── repo_clone tgoskits 仓库 (分支: chenlong)
│       → 启动/复用 Docker 容器 ghcr.io/rcore-os/tgoskits-container
│       → apt install u-boot-tools (仅首次)
│       → cargo starry defconfig aka-00-sg2002
│       → cargo starry build
│       → 产物 starryos.uimg + aka-00-sg2002.dtb → FAT_DIR
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
├── Step 5-10  rootfs 组装
│   ├── create_rootfs_structure   (目录骨架)
│   ├── simplify_bin              (busybox + 软链接)
│   ├── simplify_sbin             (rootfs/common_musl_riscv64/sbin)
│   ├── simplify_usr_bin          (同上 + busybox-full + zcip.script)
│   ├── extract_usr_sbin          (从 buildroot rootfs 提取)
│   └── build_lib                 (libc / libgcc / libstdc++ / TPU libs / OpenCV)
│
└── Step 11  pack 镜像 (自动 sudo)
    ├── pack_ext4    (losetup -fP --show 动态分配 loop)
    ├── pack_fat     (同上)
    └── pack_sd_image(同上，附加分区表 + p1/p2)
```

---

## 最小权限设计

脚本整体以 **普通用户** 运行，仅在真正需要 root 的操作时自动 `sudo`：

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
| **mount / umount loopdev** | **✅** | loop 设备属 root |
| **losetup / partprobe** | **✅** | loop 设备管理 |

退出码自动 `exit 1`，Ctrl+C / 崩溃时全局 cleanup trap 自动卸载 mount、解绑 loop 设备，不残留脏状态。

---

## 资源复用与跳过

| 场景 | 行为 | 强制重编 |
|---|---|---|
| `fip.bin` 已在 install/ 下 | 跳过 Step 1 | `FORCE=1` |
| starryos.uimg + dtb 已在 FAT_DIR | 跳过 Step 2 | `FORCE=1` |
| buildroot rootfs.tar.xz 已存在 | 跳过 Step 3 | 删除 buildroot-2021.05/output 或 `FORCE=1` |
| .config 已是当前 defconfig | 跳过 `make defconfig` | — |
| mkimage 已在容器内 | 跳过 apt install | — |

---

## 环境依赖

- **OS**: Linux (测试于 Ubuntu 24.04)
- **工具**: git, curl/wget, gcc, make, dd, python3, fdisk, mkfs.ext4, mkfs.vfat, losetup, mount, sudo
- **Docker**: 用于 StarryOS 内核编译（ghcr.io/rcore-os/tgoskits-container:latest）
- **磁盘空间**: 约 5–10 GB（buildroot 输出 + TPU SDK + tgoskits 源码）
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

- **TPU 功能是可选的**：如果不下载 TPU SDK，镜像仍可正常构建，只是缺少 TPU OpenCV 相关库。
- **Docker loopback 端口 2222**：tgoskits-container 默认使用 2222，如果冲突请修改脚本开头的 `TGOSKITS_DOCKER_NAME`（容器名）或 `docker run -p` 参数。
