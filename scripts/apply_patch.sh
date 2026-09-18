#!/bin/bash
#
# apply_patch.sh — 把 sdk_patch/ 下的改动应用到仓库根目录
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_PATCH="${SCRIPT_DIR}/../sdk_patch"
TOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ ! -d "${SDK_PATCH}" ]; then
    echo "ERROR: sdk_patch 目录不存在: ${SDK_PATCH}"
    exit 1
fi

cd "${TOP_DIR}"

applied=0
skipped=0

# 遍历 sdk_patch 下每个顶层子目录（每个子目录对应一个仓库）
for patch_repo in "${SDK_PATCH}"/*/; do
    repo_name="$(basename "${patch_repo}")"
    target_repo="${TOP_DIR}/${repo_name}"

    if [ ! -d "${target_repo}" ]; then
        echo "SKIP: ${repo_name} 仓库未下载，跳过补丁"
        skipped=$((skipped + 1))
        continue
    fi

    echo "---- 处理仓库: ${repo_name} ----"

    # 找出该仓库下的 symlink vs directory 冲突
    conflicts=()
    while IFS= read -r -d '' link; do
        rel="${link#${patch_repo}}"
        target="${target_repo}/${rel}"
        if [ -d "${target}" ] && [ ! -L "${target}" ]; then
            conflicts+=("${target}")
        fi
    done < <(find "${patch_repo}" -type l -print0)

    if [ ${#conflicts[@]} -gt 0 ]; then
        echo "  发现 ${#conflicts[@]} 个 symlink vs directory 冲突，先删除目标目录:"
        for c in "${conflicts[@]}"; do
            echo "    rm -rf ${c#${TOP_DIR}/}"
            rm -rf "${c}"
        done
    fi

    # 执行复制
    echo "  应用补丁..."
    cp -a "${patch_repo}"* "${target_repo}/"

    applied=$((applied + 1))
done

echo
echo "完成: 已应用 ${applied} 个仓库的补丁，跳过 ${skipped} 个未下载的仓库"
