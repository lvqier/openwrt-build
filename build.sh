#!/bin/bash
set -euo pipefail

# build.sh —— 对 OpenWrt release 包做二次打包（基于官方 ImageBuilder）。
#
# 构建流程（按架构独立执行，互不污染）:
#   阶段1 确定构建目标   解析参数 / device.list，得到 (target,subtarget,profile) 列表与 dist
#   阶段2 准备构建环境   为每个架构下载/解压 imagebuilder + SDK（安装 feeds、make defconfig）
#   阶段3 构建 package.list  用本架构 SDK 编译 package.list（按架构分别构建，支持架构相关包）
#   阶段4 构建目标 image  为每个 profile 注入本架构源码包 + 手动包，并 make image
#   阶段5 整理产物        用精确路径把固件/源码包拷到 dist/（固件取自 imagebuilder 的 bin/targets/<t>/<s>/）
#
# 用法:
#   ./build.sh --all [DIST]                             遍历 device.list，按架构依次构建
#   ./build.sh --arch <TARGET> <SUB_TARGET> [DIST]      只构建指定架构（CI 并行单元）
#   ./build.sh [TARGET] [SUB_TARGET] [PROFILE] [DIST]   打包单个设备
#   默认: mediatek filogic jdcloud_re-cp-03 25.12.5
#
# 环境变量:
#   BUILD_PACKAGES      1=执行阶段3从源码构建 package.list 中的包（默认）；0=跳过
#   INSTALL_FEEDS       传给 prepare_sdk_env（见 common.sh）
#   FEEDS               传给 prepare_sdk_env（见 common.sh）
#   OPENWRT_PKG_MIRROR  镜像源（见 common.sh）
#
# 产物布局:
#   packages/<target>/<subtarget>/   源码构建产物（按架构隔离，避免跨架构冲突）
#   packages/*.apk                   手动放入的架构无关包（注入到所有架构镜像）

SCRIPT_DIR=$(cd "$(dirname "${0}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# 基础软件包（- 前缀表示移除）。package.list 中声明的源码包名会自动追加（见下）。
PACKAGES="luci openssh-sftp-server tcpdump ethtool telnet-bsd luci-proto-relay wpad-mbedtls -wpad-basic-mbedtls luci-app-usteer hostapd-utils luci-proto-wireguard dnsmasq-full -dnsmasq luci-app-ddns ddns-scripts-dnspod-v3"

# 从 package.list 自动提取要安装的源码包名，追加到 PACKAGES（单一来源，无需在两处维护）。
if [ -f "${CWD}/package.list" ]; then
    SOURCE_PKGS=$(awk '/^[[:space:]]*[^#[:space:]]/{url=$1;pp=$3;if(pp==""){n=split(url,a,"/");pp=a[n];sub(/\.git$/,"",pp)}print pp}' "${CWD}/package.list" | tr '\n' ' ')
    PACKAGES="${PACKAGES} ${SOURCE_PKGS}"
fi

# 待打包目标列表：每项为 "target subtarget profile"
PROFILES=()
# 涉及的架构列表：每项为 "target|subtarget"
ARCHES=()
DIST=""

# ============ 阶段1: 确定构建目标 ============
phase1_determine() {
    echo "==== 阶段1: 确定构建目标 ===="
    local mode="single" arg_t="" arg_s="" arg_p=""
    if [ "${1:-}" = "--all" ]; then
        mode="all"; DIST=${2:-25.12.5}
    elif [ "${1:-}" = "--arch" ]; then
        mode="arch"; arg_t=${2:-}; arg_s=${3:-}; DIST=${4:-25.12.5}
        [ -n "${arg_t}" ] && [ -n "${arg_s}" ] || { echo "错误: --arch 需要 <target> <subtarget>" >&2; exit 1; }
    else
        mode="single"; arg_t=${1:-mediatek}; arg_s=${2:-filogic}; arg_p=${3:-jdcloud_re-cp-03}; DIST=${4:-25.12.5}
    fi

    if [ "${mode}" = "single" ]; then
        PROFILES+=("${arg_t} ${arg_s} ${arg_p}")
    else
        local t s p
        while read -r t s p _ <&3; do
            [ -z "${t:-}" ] && continue
            case "${t}" in \#*) continue ;; esac
            [ -z "${p:-}" ] && continue
            if [ "${mode}" = "arch" ]; then
                [ "${t}" = "${arg_t}" ] && [ "${s}" = "${arg_s}" ] || continue
            fi
            PROFILES+=("${t} ${s} ${p}")
        done 3< "${CWD}/device.list"
    fi

    [ ${#PROFILES[@]} -gt 0 ] || { echo "错误: 未指定任何构建目标" >&2; exit 1; }

    # 汇总唯一架构
    local prof t s key seen=""
    for prof in "${PROFILES[@]}"; do
        read -r t s _ <<<"${prof}"
        key="${t}|${s}"
        case " ${seen} " in *" ${key} "*) continue ;; esac
        seen="${seen} ${key}"
        ARCHES+=("${key}")
    done

    echo "  共 ${#PROFILES[@]} 个目标，${#ARCHES[@]} 个架构，DIST=${DIST}"
    local p
    for p in "${PROFILES[@]}"; do echo "    - ${p}"; done

    # 清理上次残留的产物目录，本次重新生成
    rm -rf "${CWD}/dist"
}

# ============ 单架构构建（阶段2+3+4）============
build_arch() {
    local key=$1
    local t=${key%|*} s=${key#*|}
    echo "==== 架构: ${t}/${s} ===="

    # ---- 阶段2: 准备构建环境 ----
    echo "-- 阶段2: 准备构建环境 (${t}/${s}) --"
    prepare_component "${DIST}" "${t}" "${s}" imagebuilder
    local ib=${COMP_ROOT}
    local sdk=""
    if [ "${BUILD_PACKAGES:-1}" = "1" ] && [ -f "${CWD}/package.list" ] && grep -qE '^[[:space:]]*[^#[:space:]]' "${CWD}/package.list"; then
        prepare_component "${DIST}" "${t}" "${s}" sdk
        sdk=${COMP_ROOT}
        prepare_sdk_env "${sdk}"
    fi

    # ---- 阶段3: 构建 package.list ----
    echo "-- 阶段3: 构建 package.list (${t}/${s}) --"
    local outd=${CWD}/packages/${t}/${s}
    if [ -n "${sdk}" ]; then
        build_package_list "${sdk}" "${CWD}/package.list" "${outd}"
    else
        echo "  (跳过：未启用源码包构建)"
    fi

    # ---- 阶段4: 构建目标 image ----
    echo "-- 阶段4: 构建目标 image (${t}/${s}) --"
    local prof pt ps p
    for prof in "${PROFILES[@]}"; do
        read -r pt ps p <<<"${prof}"
        [ "${pt}" = "${t}" ] && [ "${ps}" = "${s}" ] || continue
        echo "---- 打包: ${t}/${s} ${p} ----"

        # 注入：手动架构无关包 (packages/*.apk) + 本架构源码构建包 (packages/<t>/<s>/*.apk)
        echo "  注入自定义软件包"
        shopt -s nullglob
        local f
        for f in "${CWD}/packages/"*.apk; do cp -f "${f}" "${ib}/packages/"; done
        for f in "${CWD}/packages/${t}/${s}/"*.apk; do cp -f "${f}" "${ib}/packages/"; done
        shopt -u nullglob

        echo "  生成镜像"
        local FILES_ARG=""
        [ -d "${CWD}/files" ] && FILES_ARG="FILES=${CWD}/files/"
        pushd "${ib}" >/dev/null
            # 校验 profile 是否存在（捕获式校验，避免 grep -q 的 SIGPIPE 误判）。
            local ib_info
            ib_info=$(make info 2>/dev/null) || true
            if ! printf '%s\n' "${ib_info}" | grep -E "^${p}:" >/dev/null; then
                echo "错误: profile '${p}' 在 ${ib##*/} 中不存在。" >&2
                echo "可用 profile（make info）：" >&2
                printf '%s\n' "${ib_info}" | grep -E ':$' | sed 's/^/    /' >&2
                popd >/dev/null
                exit 1
            fi
            if ! make image PROFILE="${p}" ${FILES_ARG} PACKAGES="${PACKAGES}"; then
                echo "错误: make image 失败 (profile=${p})" >&2
                popd >/dev/null
                exit 1
            fi
        popd >/dev/null

        # ---- 阶段5: 整理该 profile 产物到 dist/<profile>/（精确路径，按 profile 分包） ----
        # 固件(rom) 一定在 imagebuilder 的 bin/targets/<t>/<s>/ 下，文件名含 profile；
        # 软件包 来自 packages/<t>/<s>/（由 build_package_list 从 SDK 的 bin 复制而来）。
        local fwin=${ib}/bin/targets/${t}/${s}
        local pdir=${CWD}/dist/${p}
        local fwout=${pdir}/targets/${t}/${s}
        local pkout=${pdir}/packages/${t}/${s}
        mkdir -p "${fwout}" "${pkout}"
        echo "  整理产物 -> dist/${p}/"
        shopt -s nullglob
        local f
        if [ -d "${fwin}" ]; then
            for f in "${fwin}"/*-"${p}"-*; do cp -f "${f}" "${fwout}/"; done      # 固件镜像（sysupgrade/factory/rootfs/kernel 等）
            for f in "${fwin}"/*-"${p}".manifest; do cp -f "${f}" "${fwout}/"; done  # manifest
        else
            echo "  警告: 未找到固件目录 ${fwin}" >&2
        fi
        for f in "${outd}"/*.apk; do cp -f "${f}" "${pkout}/"; done
        shopt -u nullglob
        echo "    固件 $(find "${fwout}" -maxdepth 1 -type f | wc -l)，软件包 $(find "${pkout}" -maxdepth 1 -type f | wc -l)"
    done
}

# ===== 主流程 =====
phase1_determine "$@"
for key in "${ARCHES[@]}"; do build_arch "${key}"; done
echo "==== 全部完成 ===="
