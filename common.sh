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
        # sha256sums 以二进制模式生成时文件名带 * 前缀，需去掉后比较。
        expected_hash=$(awk -v fn="${FN}" '{ f=$2; sub(/^\*/,"",f); if (f==fn) { print $1; exit } }' "${SHA256SUMS}")
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
# sha256sums 以二进制模式生成时文件名带 * 前缀，需去掉后比较。
resolve_pkg_file() {
    local sha=$1 prefix=$2
    awk -v p="${prefix}" '{ f=$2; sub(/^\*/,"",f); if (index(f,p)==1) { print f; exit } }' "${sha}"
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

# prepare_sdk_env SDK_ROOT —— 为包构建准备 SDK：安装 feeds、生成 .config
# 环境变量:
#   INSTALL_FEEDS  1=安装 feeds（默认）；0=跳过
#   FEEDS          feed 列表（逗号分隔，默认 luci；填 all 表示全部 -a）
prepare_sdk_env() {
    local sdk=$1
    local FEEDS=${FEEDS:-luci}

    if [ "${INSTALL_FEEDS:-1}" = "1" ]; then
        local marker="${sdk}/.feeds.done" need=1 prev
        if [ -e "${marker}" ]; then
            prev=$(cat "${marker}" 2>/dev/null || true)
            [ "${prev}" = "${FEEDS}" ] && need=0
        fi
        if [ "${need}" = "1" ]; then
            echo "  安装 feeds（FEEDS=${FEEDS}，首次较慢，之后缓存）"
            pushd "${sdk}" >/dev/null
                if [ "${FEEDS}" = "all" ]; then
                    ./scripts/feeds update -a
                    ./scripts/feeds install -a
                else
                    local _feeds=()
                    IFS=',' read -ra _feeds <<<"${FEEDS}"
                    ./scripts/feeds update "${_feeds[@]}"
                    ./scripts/feeds install "${_feeds[@]}"
                fi
                printf '%s' "${FEEDS}" > "${marker}"
            popd >/dev/null
        fi
    fi

    # 生成/刷新 .config（非交互），避免 package/X/compile 回退到 menuconfig（需 TTY）
    echo "  生成 .config (make defconfig)"
    pushd "${sdk}" >/dev/null
        make defconfig
    popd >/dev/null
}

# build_package_list SDK_ROOT LIST_FILE OUTPUT_DIR
# 逐条构建清单中的源码包，仅复制本包（同名前缀）产物到 OUTPUT_DIR，避免跨架构污染。
# 依赖：SDK 已由 prepare_sdk_env 准备好。
build_package_list() {
    local sdk=$1 list=$2 out=$3
    local JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
    mkdir -p "${out}"

    while read -r url ref pkgpath <&3; do
        [ -z "${url}" ] && continue
        case "${url}" in \#*) continue ;; esac
        [ -z "${pkgpath}" ] && pkgpath=$(basename "${url}" | sed 's/\.git$//')

        echo "---- 构建源码包: ${pkgpath} <${url}@${ref:-默认分支}> ----"
        local dest=${sdk}/package/${pkgpath}
        rm -rf "${dest}"
        if [ -z "${ref}" ]; then
            git clone --depth 1 "${url}" "${dest}"
        elif printf '%s' "${ref}" | grep -qE '^[0-9a-f]{7,40}$'; then
            echo "  (按 commit 检出，需完整克隆)"
            git clone "${url}" "${dest}"
            git -C "${dest}" checkout "${ref}" --detach
        else
            git clone --depth 1 --branch "${ref}" "${url}" "${dest}"
        fi

        pushd "${sdk}" >/dev/null
            # 软件包产物一定在 SDK 的 bin/packages 下（包括重编译覆盖官方预装版本的场景）。
            mkdir -p bin/packages
            if ! make "package/${pkgpath}/compile" V=s -j"${JOBS}"; then
                popd >/dev/null
                echo "错误: 编译失败 ${pkgpath}" >&2
                echo "提示: 若该包依赖 luci.mk，请确认 feeds 已安装（INSTALL_FEEDS=1）。" >&2
                return 1
            fi

            # 按包名前缀精确定位本包产物（不扫描整个 bin，不依赖路径差异）。
            local n=0 f
            while IFS= read -r f; do
                cp -f "${sdk}/${f}" "${out}/"
                echo "  产物 -> ${out##*/}/$(basename "${f}")"
                n=$((n+1))
            done < <(find bin/packages -type f \( -name "${pkgpath}-*.apk" -o -name "${pkgpath}-*.ipk" \) 2>/dev/null | sort)
            if [ "${n}" -eq 0 ]; then
                echo "  警告: 未在 bin/packages 找到 ${pkgpath}-*.apk 产物" >&2
            fi
        popd >/dev/null
    done 3< "${list}"
}
