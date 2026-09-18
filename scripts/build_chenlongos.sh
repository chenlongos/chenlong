#!/bin/bash
#
# chenlongos.sh - cv1812-edu SD 卡镜像构建脚本
#
# 前置条件 (完整下载):
#   ./scripts/repo_clone.sh --gitclone scripts/subtree_chenlongos.xml
#   ./scripts/apply_patch.sh
#
# 用法：
#   cd chenlong
#   ./scripts/build_chenlongos.sh [clean|all]
#
# 最小权限：脚本在需要 mount/losetup 等特权操作时自动 sudo，
#           其余编译/拷贝/下载等均以普通用户运行。
#

set -eo pipefail  # 出错即停；ERR trap 会捕获并清理资源

shopt -s nullglob

# ============================================================
# 自包含路径推导
# ============================================================
# TOP_DIR = 脚本所在目录的上一级
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ============================================================
declare -A PACK_MOUNTED   # 记录已完成的 mount，cleanup 时反挂
declare -A PACK_LOOPS     # 记录 losetup -fP --show 得到的 loop 设备，cleanup 时解绑


# 工具链路径（riscv64 musl）
CROSS_COMPILE_PATH="${TOP_DIR}/host-tools/gcc/riscv64-linux-musl-x86_64"
CROSS_COMPILE_PREFIX="riscv64-unknown-linux-musl-"

# ramdisk 路径
RAMDISK_PATH="${TOP_DIR}/ramdisk"
SYSROOT_PATH="${RAMDISK_PATH}/sysroot/sysroot-musl-riscv64"
INITRAMFS_PATH="${RAMDISK_PATH}/initramfs/musl_riscv64"
ROOTFS_BASE="${RAMDISK_PATH}/rootfs/common_musl_riscv64"

# buildroot 路径（用于编译 usr/sbin）
BR_DIR="${TOP_DIR}/buildroot-2021.05"
BR_BOARD="cvitek_CV181X_musl_riscv64"
BR_DEFCONFIG="${BR_BOARD}_defconfig"

# 输出路径
CHENLONGOS_DIR="${TOP_DIR}/chenlongos_output"
ROOTFS_DIR="${CHENLONGOS_DIR}/rootfs"
FAT_DIR="${CHENLONGOS_DIR}/fat"
RAW_DIR="${CHENLONGOS_DIR}/rawimages"
BR_OUTPUT_DIR="${BR_DIR}/output"

# 分区大小
FAT_SIZE_MB=60
EXT4_SIZE_MB=100

# TPU SDK 下载信息
TPU_SDK_URL="https://github.com/chenlongos/chenlong/releases/download/tar/cvitek_tpu_sdk_cv181x_musl_riscv64_rvv.tar.gz"
TPU_SDK_DIR="${TOP_DIR}/dependency/cvitek_tpu_sdk"

# StarryOS 内核源码
TGOSKITS_DIR="${TOP_DIR}/tgoskits-chenlong"
TGOSKITS_BRANCH="chenlong"
TGOSKITS_DOCKER_IMAGE="ghcr.io/rcore-os/tgoskits-container:latest"
TGOSKITS_DOCKER_NAME="tgoskits"
KERNEL_DEFCONFIG="aka-00-sg2002"
KERNEL_UIMG_REL="target/riscv64gc-unknown-none-elf/release/starryos.uimg"
KERNEL_DTB_REL="os/StarryOS/configs/board/aka-00-sg2002.dtb"

# ============================================================
# 辅助函数
# ============================================================
log() { printf "\033[1;36m[chenlongos]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[chenlongos]\033[0m WARNING: %s\n" "$*"; }
err()  { printf "\033[1;31m[chenlongos]\033[0m ERROR: %s\n" "$*"; }

# 最小权限：默认普通用户，仅特权命令用 sudo
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

# ============================================================
# 检查必要的目录和工具
# ============================================================
check_env() {
    local missing=0

    # buildroot/rootfs 构建依赖
    for dir in "${RAMDISK_PATH}" "${CROSS_COMPILE_PATH}" "${BR_DIR}"; do
        if [ ! -d "${dir}" ]; then
            err "缺少必要目录: ${dir}"
            missing=1
        fi
    done

    # fip.bin 构建依赖 (build + fsbl + opensbi + u-boot)
    for dir in \
        "${TOP_DIR}/build" \
        "${TOP_DIR}/fsbl" \
        "${TOP_DIR}/opensbi" \
        "${TOP_DIR}/u-boot-2021.10"; do
        if [ ! -d "${dir}" ]; then
            err "缺少 fip.bin 构建依赖目录: ${dir}"
            missing=1
        fi
    done

    if [ ${missing} -eq 1 ]; then
        echo ""
        echo "请先执行完整下载："
        echo "  ./scripts/repo_clone.sh --gitclone scripts/subtree_chenlongos.xml"
        echo "  cp sdk_patch/* . -rpf"
        exit 1
    fi

    # 检查普通工具（编译阶段需要）
    for tool in gcc make dd python3 docker; do
        if ! command -v "${tool}" &>/dev/null; then
            err "缺少工具: ${tool}"
            exit 1
        fi
    done
}

# 打包阶段额外需要的特权工具（mount/losetup 等需要 sudo）
check_priv_tools() {
    local missing=0
    for tool in mkfs.ext4 mkfs.vfat fdisk losetup mount umount; do
        if ! command -v "${tool}" &>/dev/null; then
            err "打包阶段缺少工具: ${tool}"
            missing=1
        fi
    done
    if [ ${missing} -eq 1 ]; then
        err "打包阶段缺少必要工具，已退出"
        exit 1
    fi
}

# ============================================================
# Clean
# ============================================================
do_clean() {
    log "清理 chenlongos 输出目录..."
    rm -rf "${CHENLONGOS_DIR}"
    rm -rf "${TPU_SDK_DIR}"

    # 在 Docker 容器内 cargo clean 清理内核编译产物（不删除源码和容器）
    if docker ps -a --format '{{.Names}}' | grep -q "^${TGOSKITS_DOCKER_NAME}$"; then
        log "在容器 ${TGOSKITS_DOCKER_NAME} 内执行 cargo clean ..."
        local was_running=1
        docker ps --format '{{.Names}}' | grep -q "^${TGOSKITS_DOCKER_NAME}$" || was_running=0
        [ ${was_running} -eq 0 ] && docker start "${TGOSKITS_DOCKER_NAME}" >/dev/null 2>&1 || true
        docker exec -w "/workspace/tgoskits-chenlong" "${TGOSKITS_DOCKER_NAME}" cargo clean
        [ ${was_running} -eq 0 ] && docker stop "${TGOSKITS_DOCKER_NAME}" >/dev/null 2>&1 || true
    else
        log "Docker 容器 ${TGOSKITS_DOCKER_NAME} 不存在，跳过 cargo clean"
    fi

    log "清理完成"
}

# ============================================================
# 编译 fip.bin (依赖: u-boot → opensbi → fsbl)
# ============================================================
build_fip_bin() {
    log "编译 fip.bin ..."

    local fip_bin="${TOP_DIR}/install/soc_cv1812cp_licheerv_nano_sd/fip.bin"

    # 已有产物则跳过（可设 FORCE=1 强制重编）
    if [ "${FORCE}" != "1" ] && [ -f "${fip_bin}" ]; then
        log "fip.bin 已存在，跳过编译 (FORCE=1 可强制重编)"
        mkdir -p "${FAT_DIR}"
        cp -a "${fip_bin}" "${FAT_DIR}/"
        return 0
    fi

    # build_fsbl() 是 cvisetup.sh 定义的函数，内部会正确导出
    # IMGTOOL_PATH / FLASH_PARTITION_XML / UBOOT_OUTPUT_FOLDER 等变量
    # 然后 cd build && make fsbl-build
    log "  source build/cvisetup.sh + defconfig ..."
    cd "${TOP_DIR}"
    # shellcheck disable=SC1091
    source build/cvisetup.sh
    if [ $? -ne 0 ]; then
        err "source build/cvisetup.sh 失败"
        return 1
    fi
    defconfig cv1812cp_licheerv_nano_sd
    if [ $? -ne 0 ]; then
        err "defconfig cv1812cp_licheerv_nano_sd 失败"
        return 1
    fi

    # 不编译 FreeRTOS（跳过 freertos 仓库）
    sed -i 's/^CONFIG_ENABLE_FREERTOS=y/CONFIG_ENABLE_FREERTOS=n/' "${TOP_DIR}/build/.config" "${TOP_DIR}/build/.defconfig"

    log "  build_fsbl (u-boot → opensbi → fsbl → fip.bin) ..."
    build_fsbl
    local rc=$?

    if [ ${rc} -ne 0 ]; then
        err "build_fsbl 失败 (退出码=${rc})"
        return 1
    fi

    if [ ! -f "${fip_bin}" ]; then
        err "fip.bin 编译失败，未找到: ${fip_bin}"
        return 1
    fi

    # 复制到 chenlongos_output/fat/
    mkdir -p "${FAT_DIR}"
    cp -a "${fip_bin}" "${FAT_DIR}/"

    log "fip.bin 编译完成: ${fip_bin}"
}

# ============================================================
# 编译 StarryOS 内核 (依赖: Docker + cargo + tgoskits 仓库)
# ============================================================
build_kernel() {
    log "编译 StarryOS 内核..."

    local kernel_uimg="${TGOSKITS_DIR}/${KERNEL_UIMG_REL}"
    local kernel_dtb="${TGOSKITS_DIR}/${KERNEL_DTB_REL}"
    local fat_uimg="${FAT_DIR}/starryos.uimg"
    local fat_dtb="${FAT_DIR}/aka-00-sg2002.dtb"

    # 已有产物则跳过（可设 FORCE=1 强制重编）
    if [ "${FORCE}" != "1" ] && [ -f "${fat_uimg}" ] && [ -f "${fat_dtb}" ]; then
        log "starryos.uimg + dtb 已存在，跳过内核编译 (FORCE=1 可强制重编)"
        return 0
    fi

    # ---- Step 1: clone tgoskits-chenlong (使用 repo_clone.sh + 临时 manifest) ----
    if [ ! -d "${TGOSKITS_DIR}" ]; then
        log "  通过 repo_clone.sh 克隆 tgoskits 仓库 (分支=${TGOSKITS_BRANCH})..."
        local tmp_manifest
        tmp_manifest=$(mktemp)
        cat > "${tmp_manifest}" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
    <remote name="chenlongos" fetch="https://github.com/chenlongos/"/>
    <default revision="${TGOSKITS_BRANCH}" remote="chenlongos"/>
    <project name="tgoskits" path="tgoskits-chenlong"/>
</manifest>
XMLEOF
        (cd "${TOP_DIR}" && bash "${SCRIPT_DIR}/repo_clone.sh" --gitclone "${tmp_manifest}")
        local rc=$?
        rm -f "${tmp_manifest}"
        if [ ${rc} -ne 0 ]; then
            err "repo_clone.sh 克隆 tgoskits 仓库失败"
            return 1
        fi
    else
        log "  tgoskits-chenlong 已存在，跳过 clone"
    fi

    # ---- Step 2: 确保 Docker 镜像就绪 ----
    if ! docker image inspect "${TGOSKITS_DOCKER_IMAGE}" &>/dev/null; then
        log "  拉取 Docker 镜像 ${TGOSKITS_DOCKER_IMAGE}..."
        docker pull "${TGOSKITS_DOCKER_IMAGE}"
        if [ $? -ne 0 ]; then
            err "拉取 Docker 镜像失败"
            return 1
        fi
    fi

    # ---- Step 3: 确保 Docker 容器就绪 ----
    local container_running=0
    local container_exists=0

    if docker ps --format '{{.Names}}' | grep -q "^${TGOSKITS_DOCKER_NAME}$"; then
        container_running=1
        container_exists=1
    elif docker ps -a --format '{{.Names}}' | grep -q "^${TGOSKITS_DOCKER_NAME}$"; then
        container_exists=1
    fi

    if [ ${container_running} -eq 0 ]; then
        if [ ${container_exists} -eq 1 ]; then
            log "  启动已有 Docker 容器 ${TGOSKITS_DOCKER_NAME}..."
            docker start "${TGOSKITS_DOCKER_NAME}"
        else
            log "  创建 Docker 容器 ${TGOSKITS_DOCKER_NAME} (镜像=${TGOSKITS_DOCKER_IMAGE})..."
            # 创建但不交互，挂载工作目录
            docker run --name "${TGOSKITS_DOCKER_NAME}" \
                -p 2222:22 \
                -v "${TOP_DIR}:/workspace" \
                -w /workspace \
                -d "${TGOSKITS_DOCKER_IMAGE}" \
                sleep infinity >/dev/null
            if [ $? -ne 0 ]; then
                err "创建 Docker 容器失败"
                return 1
            fi
        fi
    fi

    # ---- Step 4: 容器内安装依赖 + cargo build ----
    # 检查容器内是否已有 mkimage（u-boot-tools 提供），没有才 apt install
    if docker exec "${TGOSKITS_DOCKER_NAME}" sh -c "command -v mkimage >/dev/null 2>&1"; then
        log "  容器内已有 u-boot-tools (mkimage 已就绪)，跳过安装"
    else
        log "  容器内安装 u-boot-tools (提供 mkimage)..."
        docker exec "${TGOSKITS_DOCKER_NAME}" sh -c "apt update -qq && apt install -y -qq u-boot-tools >/dev/null"
        if [ $? -ne 0 ]; then
            err "容器内安装 u-boot-tools 失败"
            return 1
        fi
    fi

    # FORCE=1 时先清理编译产物
    if [ "${FORCE}" = "1" ]; then
        log "  FORCE=1, 执行 cargo clean ..."
        docker exec -w "/workspace/tgoskits-chenlong" "${TGOSKITS_DOCKER_NAME}" cargo clean
    fi

    log "  cargo starry defconfig ${KERNEL_DEFCONFIG}..."
    docker exec -w "/workspace/tgoskits-chenlong" "${TGOSKITS_DOCKER_NAME}" \
        cargo starry defconfig "${KERNEL_DEFCONFIG}"
    if [ $? -ne 0 ]; then
        err "cargo starry defconfig 失败"
        return 1
    fi

    log "  cargo starry build (首次编译较慢)..."
    docker exec -w "/workspace/tgoskits-chenlong" "${TGOSKITS_DOCKER_NAME}" \
        cargo starry build
    if [ $? -ne 0 ]; then
        err "cargo starry build 失败"
        return 1
    fi

    # ---- Step 5: 拷贝产物到 FAT_DIR ----
    if [ ! -f "${kernel_uimg}" ]; then
        err "内核镜像不存在: ${kernel_uimg}"
        return 1
    fi
    if [ ! -f "${kernel_dtb}" ]; then
        err "内核 dtb 不存在: ${kernel_dtb}"
        return 1
    fi

    mkdir -p "${FAT_DIR}"
    cp -a "${kernel_uimg}" "${fat_uimg}"
    cp -a "${kernel_dtb}" "${fat_dtb}"

    log "内核编译完成:"
    log "  starryos.uimg → ${fat_uimg}"
    log "  aka-00-sg2002.dtb → ${fat_dtb}"
}

# ============================================================
# 编译 buildroot rootfs（获取 usr/sbin 等）
# ============================================================
build_buildroot() {
    log "编译 buildroot（仅获取 rootfs 中的 usr/sbin 程序）..."

    local br_rootfs="${BR_OUTPUT_DIR}/images/rootfs.tar.xz"

    # 如果已经编译过，跳过
    if [ -f "${br_rootfs}" ]; then
        log "buildroot rootfs 已存在，跳过编译"
        return 0
    fi

    # defconfig — 只有 .config 不存在或 BR2_DEFCONFIG 不匹配才重跑
    cd "${BR_DIR}"
    local need_defconfig=0
    if [ ! -f ".config" ]; then
        need_defconfig=1
    else
        local cur_defconfig
        cur_defconfig=$(grep '^BR2_DEFCONFIG=' .config 2>/dev/null | cut -d'"' -f2 || true)
        if [ "${cur_defconfig}" != "${BR_DEFCONFIG}" ]; then
            need_defconfig=1
        fi
    fi

    if [ ${need_defconfig} -eq 1 ]; then
        log "  配置 buildroot defconfig (${BR_DEFCONFIG})..."
        make "${BR_DEFCONFIG}" BR2_TOOLCHAIN_EXTERNAL_PATH="${CROSS_COMPILE_PATH}" \
            || { err "make defconfig 失败"; return 1; }
    else
        log "  跳过 defconfig (.config 已是 ${BR_DEFCONFIG})"
    fi

    # 清空 ROOTFS_OVERLAY — buildroot 仓库只有 CV180X/overlay，
    # 而 defconfig 引用的是 CV181X/overlay（不存在），跳过即可
    if grep -q '^BR2_ROOTFS_OVERLAY=' .config; then
        sed -i 's|^BR2_ROOTFS_OVERLAY=.*|BR2_ROOTFS_OVERLAY=""|' .config
    fi

    # 编译
    log "  编译 buildroot (可能需要几分钟)..."
    make -j"$(nproc)" \
        || { err "buildroot make 失败"; return 1; }

    if [ ! -f "${br_rootfs}" ]; then
        err "buildroot rootfs 编译失败，未找到 ${br_rootfs}"
        return 1
    fi

    log "buildroot 编译完成: ${br_rootfs}"
}

# ============================================================
# 从 buildroot rootfs 中提取 usr/sbin
# ============================================================
extract_usr_sbin() {
    log "从 buildroot rootfs 提取 /usr/sbin ..."

    local br_rootfs="${BR_OUTPUT_DIR}/images/rootfs.tar.xz"

    if [ ! -f "${br_rootfs}" ]; then
        warn "未找到 buildroot rootfs: ${br_rootfs}"
        warn "将跳过 /usr/sbin，只保留 busybox 软链接"
        return 0
    fi

    mkdir -p "${ROOTFS_DIR}/usr/sbin"

    # 解压 rootfs.tar.xz 中的 usr/sbin 到临时目录
    local tmpdir=$(mktemp -d)
    tar -xf "${br_rootfs}" -C "${tmpdir}" ./usr/sbin 2>/dev/null || true

    if [ -d "${tmpdir}/usr/sbin" ]; then
        cp -a "${tmpdir}/usr/sbin/"* "${ROOTFS_DIR}/usr/sbin/" 2>/dev/null || true
        log "  + $(find "${ROOTFS_DIR}/usr/sbin" -maxdepth 1 -type f | wc -l) 个程序"
    fi

    rm -rf "${tmpdir}"
}

# ============================================================
# 下载 TPU SDK 预编译包
# ============================================================
download_tpu_sdk() {
    local dep_dir="${TOP_DIR}/dependency"
    local tarball="${dep_dir}/cvitek_tpu_sdk.tar.gz"

    if [ -d "${TPU_SDK_DIR}" ] && [ -f "${TPU_SDK_DIR}/lib/libcvimath.so" ]; then
        log "TPU SDK 已存在，跳过下载"
        return 0
    fi

    mkdir -p "${dep_dir}"

    # 如果已有 tarball，先验证是否完整
    if [ -f "${tarball}" ]; then
        log "发现已有 cvitek_tpu_sdk.tar.gz ($(du -h "${tarball}" | cut -f1))，验证完整性..."
        if gzip -t "${tarball}" 2>/dev/null; then
            log "  gzip 校验通过，无需重新下载"
        else
            warn "  文件损坏（gzip 校验失败），删除重新下载..."
            rm -f "${tarball}"
        fi
    fi

    if [ ! -f "${tarball}" ]; then
        log "下载 cvitek_tpu_sdk ..."
        log "  ${TPU_SDK_URL}"

        # 优先 curl，fallback 到 wget
        local downloaded=0
        if curl -fL --connect-timeout 15 --max-time 600 -# \
            "${TPU_SDK_URL}" -o "${tarball}" 2>&1; then
            downloaded=1
        elif wget -q --show-progress --timeout=600 \
            "${TPU_SDK_URL}" -O "${tarball}" 2>&1; then
            downloaded=1
        fi

        if [ ${downloaded} -eq 0 ] || [ ! -f "${tarball}" ] || [ ! -s "${tarball}" ]; then
            warn "TPU SDK 自动下载失败"
            warn "请手动下载并放入 ${tarball}"
            warn "  ${TPU_SDK_URL}"
            return 1
        fi

        if ! gzip -t "${tarball}" 2>/dev/null; then
            warn "下载到的文件损坏（gzip 校验失败）"
            rm -f "${tarball}"
            return 1
        fi

        log "下载成功: $(du -h "${tarball}" | cut -f1)"
    fi

    log "解压 cvitek_tpu_sdk..."
    if ! tar -xf "${tarball}" -C "${dep_dir}"; then
        warn "解压失败，可能文件已损坏"
        rm -f "${tarball}"
        return 1
    fi

    # 确保目录名为 cvitek_tpu_sdk
    if [ ! -d "${TPU_SDK_DIR}" ]; then
        local extracted
        extracted=$(ls "${dep_dir}" | grep -v '.tar.gz' | head -1)
        if [ -n "${extracted}" ] && [ -d "${dep_dir}/${extracted}" ]; then
            mv "${dep_dir}/${extracted}" "${TPU_SDK_DIR}"
        fi
    fi

    rm -f "${tarball}"

    if [ ! -d "${TPU_SDK_DIR}" ]; then
        warn "解压后未找到 cvitek_tpu_sdk 目录"
        return 1
    fi

    log "TPU SDK 准备完成: ${TPU_SDK_DIR}"
    return 0
}

# ============================================================
# 创建 rootfs 目录结构
# ============================================================
create_rootfs_structure() {
    log "创建 rootfs 目录结构..."

    rm -rf "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}"

    # 顶层目录（chenlongos.md: 其他目录只创建空目录）
    mkdir -p "${ROOTFS_DIR}"/{bin,sbin,usr/bin,usr/sbin,usr/lib,lib,dev,etc,home,mnt,proc,root,sys,tmp,var,run,opt}

    # /usr/lib64v0p7_xthead -> lib (musl 兼容)
    ln -sf lib "${ROOTFS_DIR}/usr/lib64v0p7_xthead"
    ln -sf lib "${ROOTFS_DIR}/usr/lib64"

    log "目录结构创建完成"
}

# ============================================================
#  /bin: busybox 本体 + 软链接
# ============================================================
simplify_bin() {
    log " /bin ..."

    cp -a "${INITRAMFS_PATH}/bin/busybox" "${ROOTFS_DIR}/bin/"
    for f in "${INITRAMFS_PATH}/bin/"*; do
        local name=$(basename "$f")
        if [ "${name}" = "busybox" ]; then continue; fi
        if [ -L "$f" ]; then cp -a "$f" "${ROOTFS_DIR}/bin/"; fi
    done

    log "/bin: busybox + $(find "${ROOTFS_DIR}/bin" -maxdepth 1 -type l | wc -l) 个软链接"
}

# ============================================================
#  /sbin: busybox 软链接
# ============================================================
simplify_sbin() {
    log " /sbin ..."

    cp -a "${ROOTFS_BASE}/sbin/"* "${ROOTFS_DIR}/sbin/"

    log "/sbin: $(find "${ROOTFS_DIR}/sbin" -maxdepth 1 -type l | wc -l) 个软链接"
}

# ============================================================
#  /usr/bin: busybox 软链接 + busybox-full + zcip.script
# ============================================================
simplify_usr_bin() {
    log " /usr/bin ..."

    cp -a "${ROOTFS_BASE}/usr/bin/"* "${ROOTFS_DIR}/usr/bin/"
    touch "${ROOTFS_DIR}/usr/bin/busybox-full"

    if [ -f "${RAMDISK_PATH}/rootfs/public/busybox-full/musl_riscv64/usr/libexec/zcip.script" ]; then
        mkdir -p "${ROOTFS_DIR}/usr/libexec"
        cp -a "${RAMDISK_PATH}/rootfs/public/busybox-full/musl_riscv64/usr/libexec/zcip.script" "${ROOTFS_DIR}/usr/libexec/"
    fi

    log "/usr/bin: $(find "${ROOTFS_DIR}/usr/bin" -maxdepth 1 -type l | wc -l) 个软链接 + busybox-full"
}

# ============================================================
# 构建 /lib: 库文件 + 软链接
# ============================================================
build_lib() {
    log "构建 /lib ..."

    local lib_dir="${ROOTFS_DIR}/lib"
    rm -f "${lib_dir}"/*

    # ---- musl libc ----
    local libc_src="${SYSROOT_PATH}/usr/lib64v0p7_xthead/lp64d/libc.so"
    if [ -f "${libc_src}" ]; then
        cp -a "${libc_src}" "${lib_dir}/libc.so"
        log "  + libc.so"
    elif [ -f "${SYSROOT_PATH}/libc.so" ]; then
        cp -a "${SYSROOT_PATH}/libc.so" "${lib_dir}/libc.so"
        log "  + libc.so (fallback)"
    else
        err "未找到 libc.so"
        return 1
    fi

    # 动态链接器软链接（musl 下它们就是指向 libc.so 的软链接）
    ln -sf libc.so "${lib_dir}/ld-musl-riscv64-sf.so.1"
    ln -sf libc.so "${lib_dir}/ld-musl-riscv64v0p7_xthead.so.1"

    # ---- 运行时库（从 host-tools sysroot 或 rootfs base 获取）----
    local sysroot_xt="${CROSS_COMPILE_PATH}/../riscv64-linux-musl-x86_64/sysroot/lib64v0p7_xthead/lp64d"

    # libgcc_s.so.1 — 从 rootfs base 或 host-tools
    if [ -f "${ROOTFS_BASE}/lib/libgcc_s.so.1" ]; then
        cp -a "${ROOTFS_BASE}/lib/libgcc_s.so.1" "${lib_dir}/"
    else
        find "${CROSS_COMPILE_PATH}/.." -name "libgcc_s.so.1" -exec cp -a {} "${lib_dir}/" \; -quit 2>/dev/null || true
    fi
    [ -f "${lib_dir}/libgcc_s.so.1" ] && log "  + libgcc_s.so.1" || warn "未找到 libgcc_s.so.1"

    # libatomic.so.1.2.0
    local found_atomic=""
    for candidate in \
        "${ROOTFS_BASE}/lib/libatomic.so.1.2.0" \
        "${sysroot_xt}/libatomic.so.1.2.0"; do
        if [ -f "${candidate}" ]; then
            cp -a "${candidate}" "${lib_dir}/libatomic.so.1.2.0"
            found_atomic="yes"
            break
        fi
    done
    [ -n "${found_atomic}" ] && log "  + libatomic.so.1.2.0" || warn "未找到 libatomic.so.1.2.0"

    # libstdc++.so.6.0.28
    local found_std=""
    for candidate in \
        "${ROOTFS_BASE}/lib/libstdc++.so.6.0.28" \
        "${sysroot_xt}/libstdc++.so.6.0.28"; do
        if [ -f "${candidate}" ]; then
            cp -a "${candidate}" "${lib_dir}/libstdc++.so.6.0.28"
            found_std="yes"
            break
        fi
    done
    [ -n "${found_std}" ] && log "  + libstdc++.so.6.0.28" || warn "未找到 libstdc++.so.6.0.28"

    # ---- TPU SDK 库 ----
    if [ -d "${TPU_SDK_DIR}" ]; then
        for lib in libcvimath.so libcvikernel.so libcviruntime.so; do
            if [ -f "${TPU_SDK_DIR}/lib/${lib}" ]; then
                cp -a "${TPU_SDK_DIR}/lib/${lib}" "${lib_dir}/"
                log "  + ${lib}"
            fi
        done

        for lib in libopencv_core.so.3.2.0 libopencv_imgproc.so.3.2.0 libopencv_imgcodecs.so.3.2.0; do
            if [ -f "${TPU_SDK_DIR}/opencv/lib/${lib}" ]; then
                cp -a "${TPU_SDK_DIR}/opencv/lib/${lib}" "${lib_dir}/"
                log "  + ${lib}"
            fi
        done
    fi

    # ---- 创建 SONAME 软链接 ----
    ln -sf libstdc++.so.6.0.28    "${lib_dir}/libstdc++.so.6"
    ln -sf libopencv_core.so.3.2.0      "${lib_dir}/libopencv_core.so.3.2"
    ln -sf libopencv_imgproc.so.3.2.0   "${lib_dir}/libopencv_imgproc.so.3.2"
    ln -sf libopencv_imgcodecs.so.3.2.0 "${lib_dir}/libopencv_imgcodecs.so.3.2"
    ln -sf libatomic.so.1.2.0      "${lib_dir}/libatomic.so.1"

    log "/lib 构建完成 ($(find "${lib_dir}" -maxdepth 1 -type f | wc -l) 个真实文件 + $(find "${lib_dir}" -maxdepth 1 -type l | wc -l) 个软链接)"
}

# ============================================================
# 生成 ext4 分区镜像
# ============================================================
pack_ext4() {
    log "生成 ext4 分区镜像 (${EXT4_SIZE_MB}M)..."

    mkdir -p "${RAW_DIR}"
    local ext4_img="${RAW_DIR}/rootfs.ext4"
    rm -f "${ext4_img}"

    dd if=/dev/zero of="${ext4_img}" bs=1M count="${EXT4_SIZE_MB}"
    mkfs.ext4 -F -L rootfs "${ext4_img}"

    local loop_dev
    loop_dev=$(${SUDO} losetup -fP --show "${ext4_img}") \
        || { err "losetup ${ext4_img} 失败"; return 1; }
    PACK_LOOPS["${loop_dev}"]=1

    local mount_point=$(mktemp -d)
    PACK_MOUNTED["${mount_point}"]=1
    ${SUDO} mount "${loop_dev}" "${mount_point}" \
        || { err "mount ext4 失败"; return 1; }

    ${SUDO} cp -a "${ROOTFS_DIR}"/* "${mount_point}/"
    ${SUDO} chmod 1777 "${mount_point}/tmp" 2>/dev/null || true
    ${SUDO} chmod 1777 "${mount_point}/var/tmp" 2>/dev/null || true
    ${SUDO} chown -R "$(id -u):$(id -g)" "${mount_point}" 2>/dev/null || true
    sync
    ${SUDO} umount "${mount_point}"
    unset 'PACK_MOUNTED["${mount_point}"]'
    ${SUDO} losetup -d "${loop_dev}"
    unset 'PACK_LOOPS["${loop_dev}"]'

    log "ext4 镜像: ${ext4_img} ($(du -h "${ext4_img}" | cut -f1))"
}

# ============================================================
# 生成 FAT 分区镜像（fip.bin + starryos.uimg + dtb 自动编译好）
# ============================================================
pack_fat() {
    log "生成 FAT32 分区镜像 (${FAT_SIZE_MB}M)..."

    mkdir -p "${RAW_DIR}"
    local fat_img="${RAW_DIR}/boot.fat"
    rm -f "${fat_img}"

    dd if=/dev/zero of="${fat_img}" bs=1M count="${FAT_SIZE_MB}"
    mkfs.vfat -F 32 -n BOOT "${fat_img}"

    local loop_dev
    loop_dev=$(${SUDO} losetup -fP --show "${fat_img}") \
        || { err "losetup ${fat_img} 失败"; return 1; }
    PACK_LOOPS["${loop_dev}"]=1

    local mp=$(mktemp -d)
    PACK_MOUNTED["${mp}"]=1
    # FAT 不支持权限位，mount 时指定 uid/gid 为当前用户，后续 cp 无需 sudo
    ${SUDO} mount -t vfat -o uid="$(id -u)",gid="$(id -g)" "${loop_dev}" "${mp}" \
        || { err "mount FAT 失败"; return 1; }

    local count=0
    for item in "${FAT_DIR}"/*; do
        [ -e "${item}" ] || continue
        cp -a "${item}" "${mp}/"
        log "  + $(basename "${item}")"
        count=$((count + 1))
    done

    sync
    ${SUDO} umount "${mp}"
    unset 'PACK_MOUNTED["${mp}"]'
    ${SUDO} losetup -d "${loop_dev}"
    unset 'PACK_LOOPS["${loop_dev}"]'

    if [ ${count} -eq 0 ]; then
        warn "FAT_DIR 为空，FAT 分区没有任何文件"
    fi

    log "FAT32 镜像: ${fat_img} ($count 个文件)"
}

# ============================================================
# 合成完整 SD 卡镜像
# ============================================================
pack_sd_image() {
    log "合成完整 SD 卡镜像..."

    local sd_img="${CHENLONGOS_DIR}/chenlongos.img"
    local fat_kb=$((FAT_SIZE_MB * 1024))
    local ext4_kb=$((EXT4_SIZE_MB * 1024))
    local total_kb=$((fat_kb + ext4_kb + 4096))

    rm -f "${sd_img}"
    dd if=/dev/zero of="${sd_img}" bs=1024 count="${total_kb}"

    # fdisk 操作普通文件，无需 sudo
    fdisk "${sd_img}" << EOF >/dev/null 2>&1
o
n
p
1

+${fat_kb}K
t
c
n
p
2

+${ext4_kb}K
t
2
83
w
EOF

    # 分配第一个空闲 loop → 附加 → 触发分区扫描 → 打印设备名
    local loop_dev
    loop_dev=$(${SUDO} losetup -fP --show "${sd_img}") \
        || { err "losetup ${sd_img} 失败"; return 1; }
    PACK_LOOPS["${loop_dev}"]=1

    if [ ! -b "${loop_dev}p1" ] || [ ! -b "${loop_dev}p2" ]; then
        err "内核未扫描到 ${loop_dev} 分区 (p1/p2)"
        return 1
    fi

    ${SUDO} mkfs.vfat -F 32 -n BOOT "${loop_dev}p1"
    ${SUDO} mkfs.ext4 -F -L rootfs "${loop_dev}p2"

    local fat_mount=$(mktemp -d)
    local ext4_mount=$(mktemp -d)
    PACK_MOUNTED["${fat_mount}"]=1
    PACK_MOUNTED["${ext4_mount}"]=1

    # FAT 分区用 uid/gid 选项，cp 无需 sudo
    ${SUDO} mount -t vfat -o uid="$(id -u)",gid="$(id -g)" "${loop_dev}p1" "${fat_mount}"
    ${SUDO} mount -t ext4 "${loop_dev}p2" "${ext4_mount}"

    # FAT 分区：FAT_DIR 下所有文件
    for item in "${FAT_DIR}"/*; do
        [ -e "${item}" ] || continue
        cp -a "${item}" "${fat_mount}/"
    done

    # ext4 分区：rootfs 所有文件（需 sudo，因为 mount 点属 root）
    ${SUDO} cp -a "${ROOTFS_DIR}"/* "${ext4_mount}/" 2>/dev/null || true
    ${SUDO} chmod 1777 "${ext4_mount}/tmp" 2>/dev/null || true
    ${SUDO} chmod 1777 "${ext4_mount}/var/tmp" 2>/dev/null || true

    sync
    ${SUDO} umount "${fat_mount}" "${ext4_mount}"
    unset 'PACK_MOUNTED["${fat_mount}"]' 'PACK_MOUNTED["${ext4_mount}"]'
    ${SUDO} losetup -d "${loop_dev}"
    unset 'PACK_LOOPS["${loop_dev}"]'

    log "SD 卡镜像: ${sd_img} ($(du -h "${sd_img}" | cut -f1))"
}

# ============================================================
# 打印报告
# ============================================================
print_report() {
    echo ""
    echo "=============================================="
    echo "  chenlongos 镜像构建完成"
    echo "=============================================="
    echo ""
    echo "  输出目录: ${CHENLONGOS_DIR}"
    echo ""
    echo "  FAT 分区镜像 (${FAT_SIZE_MB}M):"
    echo "    ${RAW_DIR}/boot.fat"
    echo ""
    echo "  ext4 分区镜像 (${EXT4_SIZE_MB}M):"
    echo "    ${RAW_DIR}/rootfs.ext4"
    echo ""
    echo "  完整 SD 卡镜像:"
    echo "    ${CHENLONGOS_DIR}/chenlongos.img"
    echo ""
    echo "  rootfs 大小: $(du -sh "${ROOTFS_DIR}" | cut -f1)"
    echo "  /bin: $(find "${ROOTFS_DIR}/bin" -maxdepth 1 | wc -l) 项"
    echo "  /sbin: $(find "${ROOTFS_DIR}/sbin" -maxdepth 1 | wc -l) 项"
    echo "  /usr/bin: $(find "${ROOTFS_DIR}/usr/bin" -maxdepth 1 | wc -l) 项"
    echo "  /usr/sbin: $(find "${ROOTFS_DIR}/usr/sbin" -maxdepth 1 | wc -l) 项"
    echo "  /lib: $(find "${ROOTFS_DIR}/lib" -maxdepth 1 -type f | wc -l) 个文件 + $(find "${ROOTFS_DIR}/lib" -maxdepth 1 -type l | wc -l) 个软链接"
    echo ""
    echo "  FAT 目录 (自动生成):"
    echo "    fip.bin"
    echo "    starryos.uimg"
    echo "    aka-00-sg2002.dtb"
    echo ""
    echo "=============================================="
}

# ============================================================
# 全局 cleanup — pack_* 函数中途出错/被 Ctrl+C 时自动清理残留资源
#   触发时机：EXIT（正常结束或 set -e 崩溃）、INT（Ctrl+C）、TERM
# ============================================================
pack_cleanup() {
    local exit_code=$?

    # 1. 卸载所有在 PACK_MOUNTED 中登记的 mount 点
    for mp in "${!PACK_MOUNTED[@]}"; do
        if mountpoint -q "${mp}" 2>/dev/null; then
            warn "cleanup: 卸载残留 mount ${mp}"
            ${SUDO} umount -f "${mp}" 2>/dev/null || true
        fi
        if [ -d "${mp}" ]; then
            rmdir "${mp}" 2>/dev/null || true
        fi
    done
    PACK_MOUNTED=()

    # 2. 解绑自己创建的 loop 设备
    local dev
    for dev in "${!PACK_LOOPS[@]}"; do
        if [ -b "${dev}" ]; then
            ${SUDO} losetup -d "${dev}" 2>/dev/null || true
        fi
    done
    PACK_LOOPS=()

    if [ ${exit_code} -ne 0 ] && [ ${exit_code} -ne 130 ] && [ ${exit_code} -ne 143 ]; then
        err "脚本异常退出 (exit=${exit_code})，cleanup 已执行"
    fi
}
trap pack_cleanup EXIT INT TERM

# ============================================================
# 主流程
# ============================================================
main() {
    local action="${1:-all}"

    if [ "${action}" = "clean" ]; then
        do_clean
        exit 0
    fi

    echo ""
    echo "=============================================="
    echo "  chenlongos 镜像构建"
    echo "=============================================="
    echo "  TOP_DIR: ${TOP_DIR}"
    echo "  分区: FAT ${FAT_SIZE_MB}M + ext4 ${EXT4_SIZE_MB}M"
    echo "=============================================="
    echo ""

    check_env

    # Step 1: 编译 fip.bin (u-boot → opensbi → fsbl)
    build_fip_bin || { err "fip.bin 编译失败，中止"; exit 1; }

    # Step 2: 编译 StarryOS 内核 (Docker 内 cargo build, 产物拷贝到 FAT_DIR)
    build_kernel || { err "内核编译失败，中止"; exit 1; }

    # Step 3: 编译 buildroot (获取 usr/sbin)
    build_buildroot || { err "buildroot 编译失败，中止"; exit 1; }

    # Step 4: 下载 TPU SDK（失败不阻塞流程，build_lib 会自动跳过 TPU 库）
    download_tpu_sdk || warn "TPU SDK 下载失败，将跳过 TPU 相关库"

    # Step 5: 创建 rootfs 目录结构
    create_rootfs_structure

    # Step 6:  /bin
    simplify_bin

    # Step 7:  /sbin
    simplify_sbin

    # Step 8:  /usr/bin
    simplify_usr_bin

    # Step 9: 从 buildroot rootfs 提取 usr/sbin
    extract_usr_sbin

    # Step 10: 构建 /lib
    build_lib

    # Step 11: 生成镜像（脚本内部按需自动 sudo 提升最小权限）
    check_priv_tools
    pack_ext4
    pack_fat
    pack_sd_image

    print_report
}

main "$@"
