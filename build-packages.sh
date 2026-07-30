#!/bin/bash
set -euo pipefail

# build-packages.sh —— 用 OpenWrt SDK 从源码构建 package.list 中的第三方软件包，
#                     产物（仅本包，不含附带运行时库）复制到 packages/<target>/<subtarget>/，
#                     按架构隔离，供 build.sh --arch 注入对应架构镜像。
#                     也可单独运行（此时会自行准备 SDK 环境）。
#
# 用法:
#   ./build-packages.sh [TARGET] [SUB_TARGET] [DIST]
#   默认: mediatek filogic 25.12.5
#
# 环境变量:
#   INSTALL_FEEDS   1=安装 SDK feeds（默认，首次较慢，之后缓存）；0=跳过
#   FEEDS           feed 列表（逗号分隔，默认 luci；填 all 表示全部 -a）
#   OPENWRT_PKG_MIRROR 镜像源（见 common.sh）
#   JOBS            make 并发数，默认 CPU 核数
#
# 清单 package.list 每行: <git_url> [<ref>] [<package_path>]
#   ref 支持分支/标签，也支持 commit hash（将完整克隆后检出，较慢但可固定版本）。
#
# 注意: OpenWrt SDK 为 Linux-x86_64 自包含交叉编译环境，需在 Linux 主机上运行。

SCRIPT_DIR=$(cd "$(dirname "${0}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

OPENWRT_TARGET=${1:-mediatek}
OPENWRT_SUB_TARGET=${2:-filogic}
OPENWRT_DIST=${3:-25.12.5}

PACKAGE_LIST=${CWD}/package.list
OUTPUT_DIR=${CWD}/packages/${OPENWRT_TARGET}/${OPENWRT_SUB_TARGET}

[ -f "${PACKAGE_LIST}" ] || { echo "错误: 未找到清单 ${PACKAGE_LIST}" >&2; exit 1; }
grep -qE '^[[:space:]]*[^#[:space:]]' "${PACKAGE_LIST}" || { echo "清单为空（无有效条目）"; exit 0; }

echo "==== 准备 OpenWrt SDK (${OPENWRT_TARGET}/${OPENWRT_SUB_TARGET}, ${OPENWRT_DIST}) ===="
prepare_component "${OPENWRT_DIST}" "${OPENWRT_TARGET}" "${OPENWRT_SUB_TARGET}" sdk
SDK_ROOT=${COMP_ROOT}

echo "==== 准备 SDK 构建环境 ===="
prepare_sdk_env "${SDK_ROOT}"

echo "==== 构建 package.list ===="
build_package_list "${SDK_ROOT}" "${PACKAGE_LIST}" "${OUTPUT_DIR}"

echo "==== 源码包构建完成，产物位于 ${OUTPUT_DIR} ===="
