#!/bin/bash
set -euo pipefail

# build-packages.sh —— 读取 packages.list，用 OpenWrt SDK 从源码构建第三方软件包，
#                     并把产物（.apk/.ipk）复制到工程根的 packages/ 目录，
#                     供 build.sh 注入到镜像中。
#
# 用法:
#   ./build-packages.sh [TARGET] [SUB_TARGET] [DIST]
#   默认: mediatek filogic 25.12.4
#
# 环境变量:
#   INSTALL_FEEDS   1=安装 SDK feeds（默认，首次较慢，之后缓存）；0=跳过
#   FEEDS           逗号分隔的 feed 列表（如 luci,routing），只装这些以加速；留空=全部(-a)
#   OPENWRT_PKG_MIRROR 镜像源（见 common.sh）
#   JOBS            make 并发数，默认 CPU 核数
#
# 清单 packages.list 每行: <git_url> [<ref>] [<package_path>]
#   ref 支持分支/标签，也支持 commit hash（将完整克隆后检出，较慢但可固定版本）。
#
# 注意: OpenWrt SDK 为 Linux-x86_64 自包含交叉编译环境，需在 Linux 主机上运行。

SCRIPT_DIR=$(cd "$(dirname "${0}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

OPENWRT_TARGET=${1:-mediatek}
OPENWRT_SUB_TARGET=${2:-filogic}
OPENWRT_DIST=${3:-25.12.4}

PACKAGES_LIST=${CWD}/packages.list
OUTPUT_DIR=${CWD}/packages

JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

[ -f "${PACKAGES_LIST}" ] || { echo "错误: 未找到清单 ${PACKAGES_LIST}" >&2; exit 1; }
grep -qE '^[[:space:]]*[^#[:space:]]' "${PACKAGES_LIST}" || { echo "清单为空（无有效条目）"; exit 0; }

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

echo "==== 准备 OpenWrt SDK (${OPENWRT_TARGET}/${OPENWRT_SUB_TARGET}, ${OPENWRT_DIST}) ===="
prepare_component "${OPENWRT_DIST}" "${OPENWRT_TARGET}" "${OPENWRT_SUB_TARGET}" sdk
SDK_ROOT=${COMP_ROOT}

# feeds：第三方 luci-app 等包常依赖 luci.mk，需安装 feeds；首次较慢，之后缓存复用。
# FEEDS：逗号分隔的 feed 列表（如 luci,routing），只装这些以加速；留空=全部(-a)。
FEEDS=${FEEDS:-}
if [ "${INSTALL_FEEDS:-1}" = "1" ]; then
    marker="${SDK_ROOT}/.feeds.done"
    need=1
    if [ -e "${marker}" ]; then
        prev=$(cat "${marker}" 2>/dev/null || true)
        [ "${prev}" = "${FEEDS}" ] && need=0
    fi
    if [ "${need}" = "1" ]; then
        echo "==> 安装 feeds（FEEDS=${FEEDS:--a}，首次较慢，之后缓存）"
        pushd "${SDK_ROOT}" >/dev/null
            if [ -n "${FEEDS}" ]; then
                IFS=',' read -ra _feeds <<<"${FEEDS}"
                ./scripts/feeds update "${_feeds[@]}"
                ./scripts/feeds install "${_feeds[@]}"
            else
                ./scripts/feeds update -a
                ./scripts/feeds install -a
            fi
            printf '%s' "${FEEDS}" > "${marker}"
        popd >/dev/null
    fi
fi

build_one() {
    local url=$1 ref=$2 pkgpath=$3
    local dest=${SDK_ROOT}/package/${pkgpath}
    local snap=${WORK_DIR}/.pkg-snap.tmp

    echo "---- 构建源码包: ${pkgpath} <${url}@${ref:-默认分支}> ----"
    rm -rf "${dest}"
    if [ -z "${ref}" ]; then
        git clone --depth 1 "${url}" "${dest}"
    elif printf '%s' "${ref}" | grep -qE '^[0-9a-f]{7,40}$'; then
        # ref 是 commit：浅克隆不支持任意 commit，做完整克隆后检出
        echo "  (按 commit 检出，需完整克隆)"
        git clone "${url}" "${dest}"
        git -C "${dest}" checkout "${ref}" --detach
    else
        git clone --depth 1 --branch "${ref}" "${url}" "${dest}"
    fi

    pushd "${SDK_ROOT}" >/dev/null
        find bin -type f \( -name "*.apk" -o -name "*.ipk" \) 2>/dev/null | sort > "${snap}.before"

        if ! make "package/${pkgpath}/compile" V=s -j"${JOBS}"; then
            rm -f "${snap}.before" "${snap}.after"
            popd >/dev/null
            echo "错误: 编译失败 ${pkgpath}" >&2
            echo "提示: 若该包依赖 luci.mk，请确认 feeds 已安装（INSTALL_FEEDS=1 默认开启）。" >&2
            return 1
        fi

        find bin -type f \( -name "*.apk" -o -name "*.ipk" \) 2>/dev/null | sort > "${snap}.after"
        # 仅复制本次编译新增的产物
        comm -13 "${snap}.before" "${snap}.after" | while IFS= read -r f; do
            cp -f "${SDK_ROOT}/${f}" "${OUTPUT_DIR}/"
            echo "  产物 -> packages/$(basename "${f}")"
        done
        if ! comm -13 "${snap}.before" "${snap}.after" | grep -q .; then
            echo "  警告: 未检测到新增产物（可能产物已存在或包无需重新生成）"
        fi
        rm -f "${snap}.before" "${snap}.after"
    popd >/dev/null
}

echo "==== 读取清单并构建 ===="
while read -r url ref pkgpath <&3; do
    [ -z "${url}" ] && continue
    case "${url}" in \#*) continue ;; esac
    [ -z "${pkgpath}" ] && pkgpath=$(basename "${url}" | sed 's/\.git$//')
    build_one "${url}" "${ref}" "${pkgpath}"
done 3< "${PACKAGES_LIST}"

echo "==== 源码包构建完成，产物位于 ${OUTPUT_DIR} ===="
