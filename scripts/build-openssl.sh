#!/usr/bin/env bash
# 构建并安装 iOS (device arm64) 的 OpenSSL 3.3.2 静态库与头文件。
# 供 CI（.github/workflows/build.yml）与本地构建共用：
#   bash scripts/build-openssl.sh
# 输出到 <repo>/Vendor/openssl/{include,lib}（xcodegen 生成的工程依赖这些产物）。
#
# 约束（与 CI 完全一致，勿改动）：
#   - OpenSSL 3.3.2 固定版本，静态库（no-shared）；
#   - 不启用 legacy provider、不 include 未安装的 providers.h；
#   - 仅构建 iOS 真机 arm64（ios64-xcrun），不构建模拟器；
#   - 测试/示例/应用全部禁用（no-tests no-apps），no-unit-test 在 3.x 已并入 no-tests。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENSSL_VERSION="3.3.2"
# P1-9: 优先使用 openssl.org 官方源，其次回退到 GitHub Release 与 openssl-library.org 镜像
# 官方（含 openssl-library.org）与 GitHub Release 自 3.3.x 起已统一由 GitHub 分发，SHA256 一致
TARBALL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
TARBALL_URL_FALLBACK="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
TARBALL_URL_FALLBACK2="https://openssl-library.org/source/old/3.3/openssl-${OPENSSL_VERSION}.tar.gz"

WORK="/tmp/ossl_src"
OUTDIR="$REPO_ROOT/build/openssl-out"
DEVICE_OUT="$OUTDIR/device"
VENDOR_LIB="$REPO_ROOT/Vendor/openssl/lib"
VENDOR_INC="$REPO_ROOT/Vendor/openssl/include"

echo "==> 下载 OpenSSL ${OPENSSL_VERSION} (优先官网 https://www.openssl.org/source/，失败回退 GitHub/openssl-library.org)"
mkdir -p "$WORK"
# 依次尝试：官网 -> GitHub Release -> openssl-library.org 镜像；全部失败则退出
if ! curl -fL --retry 3 -o "$WORK/openssl.tar.gz" "$TARBALL_URL"; then
  echo "官网 $TARBALL_URL 下载失败，尝试 GitHub 备用 $TARBALL_URL_FALLBACK"
  if ! curl -fL --retry 3 -o "$WORK/openssl.tar.gz" "$TARBALL_URL_FALLBACK"; then
    echo "GitHub 备用失败，尝试镜像 $TARBALL_URL_FALLBACK2"
    curl -fL --retry 3 -o "$WORK/openssl.tar.gz" "$TARBALL_URL_FALLBACK2" || { echo "全部下载源失败"; exit 1; }
  fi
fi
# GPG 校验说明（可选增强，供 CI 手动验证完整性）：
# 官方提供 .asc 签名文件：https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz.asc
# 校验步骤：
#   curl -fL -o "$WORK/openssl.tar.gz.asc" "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz.asc"
#   curl -fL -o "$WORK/openssl.tar.gz.sha256" "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz.sha256"
#   gpg --verify "$WORK/openssl.tar.gz.asc" "$WORK/openssl.tar.gz"
# 需预先导入 OpenSSL 官方公钥（https://www.openssl.org/source/gpgkey-*.asc）到可信环
# 当前脚本保留 SHA256 校验作为最低保障；.asc/.sha256 可作为补充校验
#
# 校验 sha256（openssl-3.3.2 官方 SHA256，与 GitHub Release 一致）：
#   SHA256=2e8a40b01979afe8be0bbfb3de5dc1c6709fedb46d6c89c10da114ab5fc3d281
#   SHA1  = b7ca08f2d49c10d772c5ec6cf2de6e08e69002b3（见 https://www.openssl.org/news/openssl-3.3.2-notes.html）
# 注意：旧版脚本注释称 GitHub 与 openssl.org 哈希不同，实测 3.3.2 已统一，此处保留单哈希校验兼容全部源
echo "2e8a40b01979afe8be0bbfb3de5dc1c6709fedb46d6c89c10da114ab5fc3d281  $WORK/openssl.tar.gz" \
  | shasum -a 256 -c - || { echo "OpenSSL 源码校验失败"; exit 1; }
cd "$WORK"
tar -xzf openssl.tar.gz
cd "openssl-${OPENSSL_VERSION}"

echo "==> Configure (ios64-xcrun, 静态库)"
mkdir -p "$DEVICE_OUT"
./Configure ios64-xcrun \
  --prefix="$DEVICE_OUT" \
  --openssldir="$DEVICE_OUT" \
  -D__IPHONE_OS_VERSION_MIN_REQUIRED=160000 \
  no-shared no-tests no-apps

echo "==> 编译静态库"
# 仅构建 libcrypto：全库无任何 SSL_*/TLS_* 调用（签名只走 PKCS12/X509/EVP），
# libssl 纯属白构建+白拷贝+白链接（约省 25-30% OpenSSL 编译时间）。
# 注意：3.x 的 Makefile 没有 build_libcrypto 目标（只有 build_libs / 具体库名），
# 且 install_dev 会因 libssl.a 缺失而失败——直接构建 libcrypto.a 并手动安装。
# 另外 libcrypto.a 目标不携带 build_libs 的 build_generated 依赖，需先显式
# 生成 opensslv.h 等派生头文件，否则所有 .o 编译报 "openssl/opensslv.h not found"。
make -j"$(sysctl -n hw.ncpu)" build_generated
make -j"$(sysctl -n hw.ncpu)" libcrypto.a || make libcrypto.a

echo "==> 安装到 $DEVICE_OUT（libcrypto-only 手动安装）"
mkdir -p "$DEVICE_OUT/include" "$DEVICE_OUT/lib"
rm -rf "$DEVICE_OUT/include/openssl"
# 3.x 起生成的头文件（opensslconf.h/configuration.h 等）就在源码树 include/openssl 内，
# 与 install_dev 的复制来源一致
cp -R "include/openssl" "$DEVICE_OUT/include/openssl"
cp libcrypto.a "$DEVICE_OUT/lib/libcrypto.a"

echo "==> 复制产物到 Vendor/openssl"
mkdir -p "$VENDOR_INC" "$VENDOR_LIB"
# 先清掉旧头文件目录再复制：本地重复运行时 BSD cp -R 会把 include/openssl
# 嵌套成 include/openssl/openssl，HEADER_SEARCH_PATHS 随之失效（CI 全新
# checkout 无此问题，本地复跑会踩）
rm -rf "$VENDOR_INC/openssl"
cp -R "$DEVICE_OUT/include/openssl" "$VENDOR_INC/openssl"
cp "$DEVICE_OUT/lib/libcrypto.a" "$VENDOR_LIB/libcrypto-device.a"
echo "==> OpenSSL 产物就绪: $VENDOR_LIB"