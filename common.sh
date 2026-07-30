# common.sh —— build.sh / build-packages.sh 共享逻辑
# 本文件供调用者 source，不自行 set -e（由调用者统一 set -euo pipefail）。

OPENWRT_PKG_MIRROR=${OPENWRT_PKG_MIRROR:-https://downloads.openwrt.org}
# 如需使用阿里云镜像：
#   export OPENWRT_PKG_MIRROR=https://mirrors.aliyun.com/openwrt
# 并取消各脚本里 repositories.conf 的 sed 注释，使内部软件源同步切换。

# 工程根目录（common.sh 所在目录）
COMMON_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CWD=${CWD:-${COMMON_DIR}}
WORK_DIR=${WORK_DIR:-${CWD}/build}

# download() 通过此变量回传结果：skip（缓存命中）/ downloaded（新下载）
DOWNLOAD_RESULT=""

# ===== 带校验的断点续传下载 =====
download() {
    local URL=${1}
    local TGT=${2}
    local SHA256SUMS=${3}
    local FN=$(basename "${TGT}")

    if [ -e "${TGT}" ]
    then
        local expected_hash actual_hash
        # 用 awk 精确匹配文件名字段，避免 grep 子串误匹配
        expected_hash=$(awk -v fn="${FN}" '$2==fn{print $1; exit}' "${SHA256SUMS}")
        if [ -n "${expected_hash}" ]
        then
            actual_hash=$(sha256sum "${TGT}" 2>/dev/null | awk '{print $1}')
            if [ "${expected_hash}" = "${actual_hash}" ]
            then
                echo "  缓存命中，校验通过: ${FN}"
                DOWNLOAD_RESULT="skip"
                return 0
            fi
            echo "  校验失败，重新下载: ${FN}"
        else
            echo "  警告: sha256sums 中未找到 ${FN}，重新下载"
        fi
        unlink "${TGT}"
    fi
    curl -fL --retry 10 "${URL}" -C - -o "${TGT}"
    DOWNLOAD_RESULT="downloaded"
}

# 从 sha256sums 文件中按前缀取出真实包文件名（兼容 .tar.zst/.tar.xz 等）
resolve_pkg_file() {
    local sha=$1 prefix=$2
    awk -v p="${prefix}" 'index($2,p)==1{print $2; exit}' "${sha}"
}

# 按扩展名解压到 WORK_DIR
extract_pkg() {
    local pkg=$1
    case "$pkg" in
        *.tar.zst) tar --zstd -xvf "$pkg" -C "${WORK_DIR}" ;;
        *.tar.xz|*.txz) tar -xJvf "$pkg" -C "${WORK_DIR}" ;;
        *.tar.gz|*.tgz) tar -xzvf "$pkg" -C "${WORK_DIR}" ;;
        *.tar.bz2|*.tbz) tar -xjvf "$pkg" -C "${WORK_DIR}" ;;
        *) tar -xvf "$pkg" -C "${WORK_DIR}" ;;
    esac
}

# prepare_component DIST TARGET SUB_TARGET COMPONENT
# 下载并解压 imagebuilder 或 sdk；结果目录写入全局 COMP_ROOT。
# COMPONENT: imagebuilder | sdk
prepare_component() {
    local dist=$1 target=$2 sub=$3 comp=$4
    local base mirror
    case "$comp" in
        imagebuilder) base=openwrt-imagebuilder ;;
        sdk)          base=openwrt-sdk ;;
        *) echo "错误: 未知组件 ${comp}" >&2; return 1 ;;
    esac
    if [ "$dist" != "snapshots" ]; then
        mirror=${OPENWRT_PKG_MIRROR}/releases
    else
        mirror=${OPENWRT_PKG_MIRROR}
    fi

    test -e "${WORK_DIR}" || mkdir -p "${WORK_DIR}"

    local sha_file=${WORK_DIR}/${target}_${sub}.sha256sums
    local sha_url=${mirror}/${dist}/targets/${target}/${sub}/sha256sums

    echo "==> [${comp}] 获取 sha256sums"
    curl -fL "${sha_url}" -o "${sha_file}"

    local pkg_file
    pkg_file=$(resolve_pkg_file "${sha_file}" "${base}-")
    if [ -z "${pkg_file}" ]; then
        echo "错误: sha256sums 中未找到 ${base}- 开头的包" >&2
        return 1
    fi
    local pkg_name=${pkg_file%.tar.*}
    local pkg_url=${mirror}/${dist}/targets/${target}/${sub}/${pkg_file}

    echo "==> [${comp}] 下载 ${pkg_file}"
    DOWNLOAD_RESULT=""
    download "${pkg_url}" "${WORK_DIR}/${pkg_file}" "${sha_file}"

    # 仅当本次真正下载了新包时，才删除旧的解压目录并重新解压
    if [ "${DOWNLOAD_RESULT}" = "downloaded" ]; then
        test -e "${WORK_DIR}/${pkg_name}" && rm -rf "${WORK_DIR}/${pkg_name}"
    fi
    test -e "${WORK_DIR}/${pkg_name}" || extract_pkg "${WORK_DIR}/${pkg_file}"

    COMP_ROOT=${WORK_DIR}/${pkg_name}
}
