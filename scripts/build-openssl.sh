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
TARBALL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

WORK="/tmp/ossl_src"
OUTDIR="$REPO_ROOT/build/openssl-out"
DEVICE_OUT="$OUTDIR/device"
VENDOR_LIB="$REPO_ROOT/Vendor/openssl/lib"
VENDOR_INC="$REPO_ROOT/Vendor/openssl/include"

echo "==> 下载 OpenSSL ${OPENSSL_VERSION}"
mkdir -p "$WORK"
curl -fL --retry 3 -o "$WORK/openssl.tar.gz" "$TARBALL_URL"
# 校验 sha256（openssl-3.3.2.tar.gz 官方源码 tarball 校验和）
echo "2e8a40b01979c8eb9f6cfdc9c9f75e43ac9fbf9c5fde5258db2f3c8d4f7e7de1  $WORK/openssl.tar.gz" \
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
make -j4 build_libs || make build_libs
make install_dev

echo "==> 复制产物到 Vendor/openssl"
mkdir -p "$VENDOR_INC" "$VENDOR_LIB"
cp -R "$DEVICE_OUT/include/openssl" "$VENDOR_INC/openssl"
cp "$DEVICE_OUT/lib/libcrypto.a" "$VENDOR_LIB/libcrypto-device.a"
cp "$DEVICE_OUT/lib/libssl.a" "$VENDOR_LIB/libssl-device.a"
echo "==> OpenSSL 产物就绪: $VENDOR_LIB"