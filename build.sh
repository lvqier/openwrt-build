#!/bin/bash
set -euo pipefail

# build.sh —— 对 OpenWrt release 包做二次打包（基于官方 ImageBuilder）。
#
# 用法:
#   ./build.sh [TARGET] [SUB_TARGET] [PROFILE] [DIST]   打包单个设备
#   ./build.sh --all [DIST]                             遍历 devices.list 批量打包
#   默认: mediatek filogic jdcloud_re-cp-03 25.12.4
#
# 环境变量:
#   BUILD_PACKAGES      1=打包前从源码构建 packages.list 中的第三方包（默认）；0=跳过
#   INSTALL_FEEDS       传给 build-packages.sh（见 build-packages.sh）
#   OPENWRT_PKG_MIRROR  镜像源（见 common.sh）

SCRIPT_DIR=$(cd "$(dirname "${0}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# 需要在官方镜像基础上增减的软件包（- 前缀表示移除）
PACKAGES="luci openssh-sftp-server tcpdump ethtool telnet-bsd luci-proto-relay wpad-mbedtls -wpad-basic-mbedtls luci-app-usteer hostapd-utils luci-proto-wireguard dnsmasq-full -dnsmasq luci-app-dnsmasq-ipset luci-app-ddns ddns-scripts-dnspod-v3"

# 单设备打包流程
build_image() {
    local OPENWRT_TARGET=${1}
    local OPENWRT_SUB_TARGET=${2}
    local OPENWRT_PROFILE=${3}
    local OPENWRT_DIST=${4}

    echo "==== 打包设备: ${OPENWRT_TARGET} ${OPENWRT_SUB_TARGET} ${OPENWRT_PROFILE} (${OPENWRT_DIST}) ===="
    prepare_component "${OPENWRT_DIST}" "${OPENWRT_TARGET}" "${OPENWRT_SUB_TARGET}" imagebuilder
    local IB=${COMP_ROOT}

    # 切换 imagebuilder 内部软件源（可选）
    # sed -i 's/downloads.openwrt.org/mirrors.aliyun.com\/openwrt/g' "${IB}/repositories.conf"

    echo "==> [${OPENWRT_PROFILE}] 注入自定义软件包"
    shopt -s nullglob
    local PKG
    for PKG in "${CWD}/packages/"*.apk
    do
        cp -f "${PKG}" "${IB}/packages/"
    done
    shopt -u nullglob

    echo "==> [${OPENWRT_PROFILE}] 生成镜像"
    # FILES 必须用绝对路径，否则会指向 imagebuilder 自身目录而非工程根的 files/
    local FILES_ARG=""
    [ -d "${CWD}/files" ] && FILES_ARG="FILES=${CWD}/files/"
    pushd "${IB}" >/dev/null
        if ! make image PROFILE="${OPENWRT_PROFILE}" ${FILES_ARG} PACKAGES="${PACKAGES}"
        then
            echo "错误: make image 失败 (profile=${OPENWRT_PROFILE})" >&2
            exit 1
        fi
    popd >/dev/null
}

# 打包前从源码构建第三方包（按架构构建一次，供同架构所有设备复用）
run_build_packages() {
    local t=$1 s=$2 d=$3
    [ "${BUILD_PACKAGES:-1}" = "1" ] || return 0
    [ -f "${CWD}/packages.list" ] || return 0
    grep -qE '^[[:space:]]*[^#[:space:]]' "${CWD}/packages.list" || return 0
    echo "==== 从源码构建第三方包 ===="
    bash "${CWD}/build-packages.sh" "${t}" "${s}" "${d}"
}

# ===== 主流程 =====
if [ "${1:-}" = "--all" ]
then
    OPENWRT_DIST=${2:-25.12.4}
    # 取 devices.list 第一行非注释的 target/subtarget，用于构建源码包（假设同架构）
    first_t=$(awk '/^[[:space:]]*[^#[:space:]]/{print $1; exit}' "${CWD}/devices.list")
    first_s=$(awk '/^[[:space:]]*[^#[:space:]]/{print $2; exit}' "${CWD}/devices.list")
    if [ -n "${first_t:-}" ] && [ -n "${first_s:-}" ]; then
        run_build_packages "${first_t}" "${first_s}" "${OPENWRT_DIST}"
    fi
    while read -r TGT SUB PROFILE _ <&3
    do
        [ -z "${PROFILE:-}" ] && continue
        build_image "${TGT}" "${SUB}" "${PROFILE}" "${OPENWRT_DIST}"
    done 3< "${CWD}/devices.list"
else
    OPENWRT_TARGET=${1:-mediatek}
    OPENWRT_SUB_TARGET=${2:-filogic}
    OPENWRT_PROFILE=${3:-jdcloud_re-cp-03}
    OPENWRT_DIST=${4:-25.12.4}
    run_build_packages "${OPENWRT_TARGET}" "${OPENWRT_SUB_TARGET}" "${OPENWRT_DIST}"
    build_image "${OPENWRT_TARGET}" "${OPENWRT_SUB_TARGET}" "${OPENWRT_PROFILE}" "${OPENWRT_DIST}"
fi
