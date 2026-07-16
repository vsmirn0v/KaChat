#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/opus"
SRC_DIR="$BUILD_DIR/opus-src"
OUT_DIR="$ROOT_DIR/external/opus"
XCFRAMEWORK_DIR="$OUT_DIR/Opus.xcframework"
OPUS_VERSION="1.5.2"

MACOS_MIN=13.0
CATALYST_MIN=16.0
IOS_MIN=16.0

mkdir -p "$BUILD_DIR" "$OUT_DIR"

if [ ! -d "$SRC_DIR" ]; then
  echo "Downloading libopus ${OPUS_VERSION}..."
  TARBALL="$BUILD_DIR/opus.tar.gz"
  URLS=(
    "https://archive.mozilla.org/pub/opus/opus-${OPUS_VERSION}.tar.gz"
    "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
    "https://ftp.osuosl.org/pub/xiph/releases/opus/opus-${OPUS_VERSION}.tar.gz"
  )
  downloaded=0
  for url in "${URLS[@]}"; do
    if curl -L --fail "$url" -o "$TARBALL"; then
      downloaded=1
      break
    fi
  done
  if [ "$downloaded" -ne 1 ]; then
    echo "Failed to download libopus from all mirrors." >&2
    exit 1
  fi
  tar -xzf "$TARBALL" -C "$BUILD_DIR"
  mv "$BUILD_DIR/opus-${OPUS_VERSION}" "$SRC_DIR"
fi

SDK_MACOS="$(xcrun --sdk macosx --show-sdk-path)"
SDK_IOS="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_IOS_SIM="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

build_opus() {
  local arch="$1"
  local target="$2"
  local build_subdir="$3"
  local sdk_path="$4"

  local build_path="$BUILD_DIR/$build_subdir"
  rm -rf "$build_path"
  mkdir -p "$build_path"

  pushd "$build_path" >/dev/null

  local cflags="-arch ${arch} -isysroot ${sdk_path} -target ${target}"
  local ldflags="-arch ${arch} -isysroot ${sdk_path} -target ${target}"

  "$SRC_DIR/configure" \
    --disable-shared \
    --enable-static \
    --disable-extra-programs \
    --host="${arch}-apple-darwin" \
    CC="$CLANG" \
    CFLAGS="$cflags" \
    LDFLAGS="$ldflags"

  make -j"$(sysctl -n hw.ncpu)"
  popd >/dev/null
}

# iOS builds
build_opus "arm64" "arm64-apple-ios${IOS_MIN}" "ios-arm64" "$SDK_IOS"

# iOS simulator builds
build_opus "arm64" "arm64-apple-ios${IOS_MIN}-simulator" "iossim-arm64" "$SDK_IOS_SIM"
build_opus "x86_64" "x86_64-apple-ios${IOS_MIN}-simulator" "iossim-x86_64" "$SDK_IOS_SIM"

# macOS builds
build_opus "arm64" "arm64-apple-macos${MACOS_MIN}" "macos-arm64" "$SDK_MACOS"
build_opus "x86_64" "x86_64-apple-macos${MACOS_MIN}" "macos-x86_64" "$SDK_MACOS"

# Mac Catalyst builds (macabi)
build_opus "arm64" "arm64-apple-ios${CATALYST_MIN}-macabi" "maccatalyst-arm64" "$SDK_MACOS"
build_opus "x86_64" "x86_64-apple-ios${CATALYST_MIN}-macabi" "maccatalyst-x86_64" "$SDK_MACOS"

# Create universal static libraries
IOS_LIB="$BUILD_DIR/libopus-ios.a"
IOS_SIM_LIB="$BUILD_DIR/libopus-iossim.a"
MACOS_LIB="$BUILD_DIR/libopus-macos.a"
CATALYST_LIB="$BUILD_DIR/libopus-maccatalyst.a"

cp "$BUILD_DIR/ios-arm64/.libs/libopus.a" "$IOS_LIB"

lipo -create \
  "$BUILD_DIR/iossim-arm64/.libs/libopus.a" \
  "$BUILD_DIR/iossim-x86_64/.libs/libopus.a" \
  -output "$IOS_SIM_LIB"

lipo -create \
  "$BUILD_DIR/macos-arm64/.libs/libopus.a" \
  "$BUILD_DIR/macos-x86_64/.libs/libopus.a" \
  -output "$MACOS_LIB"

lipo -create \
  "$BUILD_DIR/maccatalyst-arm64/.libs/libopus.a" \
  "$BUILD_DIR/maccatalyst-x86_64/.libs/libopus.a" \
  -output "$CATALYST_LIB"

# Prepare headers
HEADERS_DIR="$BUILD_DIR/headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp -R "$SRC_DIR/include/"* "$HEADERS_DIR/"

# Build XCFramework
rm -rf "$XCFRAMEWORK_DIR"
xcodebuild -create-xcframework \
  -library "$IOS_LIB" -headers "$HEADERS_DIR" \
  -library "$IOS_SIM_LIB" -headers "$HEADERS_DIR" \
  -library "$MACOS_LIB" -headers "$HEADERS_DIR" \
  -library "$CATALYST_LIB" -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK_DIR"

echo "Created $XCFRAMEWORK_DIR"
