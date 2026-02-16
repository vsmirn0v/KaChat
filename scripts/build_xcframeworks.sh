#!/bin/bash
#
# build_xcframeworks.sh — Build precompiled xcframeworks from SPM dependencies
#
# Harvests compiled .o and .swiftmodule artifacts from Xcode's build output,
# merges them into 3 static xcframeworks:
#   - GRPCAll.xcframework    (GRPC + all 16 transitive deps merged)
#   - SwiftProtobuf.xcframework
#   - P256K.xcframework      (P256K + libsecp256k1)
#
# Platform slices: ios-arm64, ios-arm64_x86_64-simulator, ios-arm64_x86_64-maccatalyst
# Uses binary .swiftmodule (not .swiftinterface) — must rebuild after Xcode updates.
#
# Usage: bash scripts/build_xcframeworks.sh
# Resume: XCFW_BUILD_ROOT=/tmp/kachat-xcfw-build bash scripts/build_xcframeworks.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/KaChat.xcodeproj"
SCHEME="KaChat"
CONFIG="Release"
BUILD_ROOT="${XCFW_BUILD_ROOT:-/tmp/kachat-xcfw-build}"
STAGE="$BUILD_ROOT/stage"
OUTPUT="$PROJECT_DIR/Frameworks"

echo "============================================"
echo "  KaChat XCFramework Builder"
echo "============================================"
echo "Xcode:   $(xcodebuild -version | head -1)"
echo "Config:  $CONFIG"
echo "Build:   $BUILD_ROOT"
echo "Output:  $OUTPUT"
echo ""

# ── Module lists ────────────────────────────────────────────────

# GRPCAll: all .o names (Swift + C modules)
GRPC_OBJECTS="GRPC NIOCore NIOPosix NIO NIOEmbedded NIOFoundationCompat \
NIOTLS NIOConcurrencyHelpers NIOExtras NIOHPACK NIOHTTP1 NIOHTTP2 NIOSSL \
NIOTransportServices _NIOBase64 _NIODataStructures Atomics DequeModule \
InternalCollectionsUtilities Logging CGRPCZlib CNIOAtomics CNIOBoringSSL \
CNIOBoringSSLShims CNIODarwin CNIOLLHTTP CNIOLinux CNIOOpenBSD CNIOPosix \
CNIOWASI CNIOWindows _AtomicsShims"

# GRPCAll: Swift modules only (have .swiftmodule dirs)
GRPC_MODULES="GRPC NIOCore NIOPosix NIO NIOEmbedded NIOFoundationCompat \
NIOTLS NIOConcurrencyHelpers NIOExtras NIOHPACK NIOHTTP1 NIOHTTP2 NIOSSL \
NIOTransportServices _NIOBase64 _NIODataStructures Atomics DequeModule \
InternalCollectionsUtilities Logging"

PB_OBJECTS="SwiftProtobuf"
PB_MODULES="SwiftProtobuf"

P256K_OBJECTS="P256K libsecp256k1"
P256K_MODULES="P256K"

# ── Step 1: Build for 5 platform/arch combos ────────────────────
echo "=== Step 1/4: Building for all platforms ==="
echo "(Each build compiles all SPM from source — be patient)"
echo ""

mkdir -p "$BUILD_ROOT"

do_build() {
  local label="$1" dest="$2" arch="$3"
  local dd="$BUILD_ROOT/$label"
  local marker="$dd/.build_done"

  if [[ -f "$marker" ]]; then
    echo "[$label] Skipping (already built)"
    return 0
  fi

  echo "[$label] Building ($arch)..."
  local start=$SECONDS

  # Build; tolerate link failures (e.g. YbridOpus lacks arm64 sim slice).
  # SPM module .o files are produced before linking, so we just need compilation.
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$dest" \
    -derivedDataPath "$dd" \
    ARCHS="$arch" \
    ONLY_ACTIVE_ARCH=YES \
    -quiet 2>&1 || true

  local elapsed=$(( SECONDS - start ))

  # Verify SPM artifacts exist (compilation succeeded even if linking failed)
  local subdir
  case "$dest" in
    *"platform=iOS Simulator"*) subdir="${CONFIG}-iphonesimulator" ;;
    *"variant=Mac Catalyst"*)   subdir="${CONFIG}-maccatalyst" ;;
    *)                          subdir="${CONFIG}-iphoneos" ;;
  esac
  if [[ ! -f "$dd/Build/Products/$subdir/GRPC.o" ]]; then
    echo "[$label] ERROR: GRPC.o not found — compilation may have failed"
    exit 1
  fi

  echo "[$label] Done in ${elapsed}s"
  touch "$marker"
}

do_build device-arm64    "generic/platform=iOS"                         arm64
do_build sim-arm64       "generic/platform=iOS Simulator"               arm64
do_build sim-x86_64      "generic/platform=iOS Simulator"               x86_64
do_build catalyst-arm64  "generic/platform=macOS,variant=Mac Catalyst"  arm64
do_build catalyst-x86_64 "generic/platform=macOS,variant=Mac Catalyst"  x86_64

# Product directory shortcuts
DEV="$BUILD_ROOT/device-arm64/Build/Products/${CONFIG}-iphoneos"
SIM_A="$BUILD_ROOT/sim-arm64/Build/Products/${CONFIG}-iphonesimulator"
SIM_X="$BUILD_ROOT/sim-x86_64/Build/Products/${CONFIG}-iphonesimulator"
CAT_A="$BUILD_ROOT/catalyst-arm64/Build/Products/${CONFIG}-maccatalyst"
CAT_X="$BUILD_ROOT/catalyst-x86_64/Build/Products/${CONFIG}-maccatalyst"

# Verify key artifacts
echo ""
echo "Verifying build artifacts..."
for d in "$DEV" "$SIM_A" "$SIM_X" "$CAT_A" "$CAT_X"; do
  if [[ ! -f "$d/GRPC.o" ]]; then
    echo "ERROR: GRPC.o not found in $d"
    exit 1
  fi
done
echo "All build artifacts present."

# ── Step 2: Create framework slices ─────────────────────────────
echo ""
echo "=== Step 2/4: Creating framework slices ==="

rm -rf "$STAGE"

write_plist() {
  local fw_dir="$1" name="$2"
  cat > "$fw_dir/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$name</string>
  <key>CFBundleIdentifier</key>
  <string>com.kachat.frameworks.$name</string>
  <key>CFBundleName</key>
  <string>$name</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>MinimumOSVersion</key>
  <string>17.0</string>
</dict>
</plist>
PLIST
}

# make_thin_slice: single-arch framework slice (device)
make_thin_slice() {
  local name="$1" slice="$2" products="$3" objects="$4" modules="$5"
  local fw="$STAGE/$name/$slice/$name.framework"
  mkdir -p "$fw/Modules"

  # Collect .o files and create static library
  local objs=()
  for m in $objects; do
    [[ -f "$products/$m.o" ]] && objs+=("$products/$m.o")
  done
  libtool -static -o "$fw/$name" "${objs[@]}" 2>/dev/null

  # Copy .swiftmodule directories
  for m in $modules; do
    [[ -d "$products/$m.swiftmodule" ]] && cp -R "$products/$m.swiftmodule" "$fw/Modules/"
  done

  write_plist "$fw" "$name"
  echo "  $name/$slice ($(lipo -archs "$fw/$name" 2>/dev/null))"
}

# make_fat_slice: multi-arch (universal) framework slice (sim, catalyst)
make_fat_slice() {
  local name="$1" slice="$2" p1="$3" p2="$4" objects="$5" modules="$6"
  local fw="$STAGE/$name/$slice/$name.framework"
  mkdir -p "$fw/Modules"

  # libtool per arch, then lipo
  local objs1=() objs2=()
  for m in $objects; do
    [[ -f "$p1/$m.o" ]] && objs1+=("$p1/$m.o")
    [[ -f "$p2/$m.o" ]] && objs2+=("$p2/$m.o")
  done

  local tmp1="$STAGE/$name/$slice/_arch1.a"
  local tmp2="$STAGE/$name/$slice/_arch2.a"
  libtool -static -o "$tmp1" "${objs1[@]}" 2>/dev/null
  libtool -static -o "$tmp2" "${objs2[@]}" 2>/dev/null
  lipo -create "$tmp1" "$tmp2" -output "$fw/$name"
  rm -f "$tmp1" "$tmp2"

  # Merge .swiftmodule dirs from both archs
  for m in $modules; do
    local dst="$fw/Modules/$m.swiftmodule"
    mkdir -p "$dst/Project"
    for src in "$p1/$m.swiftmodule" "$p2/$m.swiftmodule"; do
      [[ -d "$src" ]] || continue
      cp -f "$src/"*.swiftmodule "$dst/" 2>/dev/null || true
      cp -f "$src/"*.swiftdoc    "$dst/" 2>/dev/null || true
      cp -f "$src/"*.abi.json    "$dst/" 2>/dev/null || true
      [[ -d "$src/Project" ]] && \
        cp -f "$src/Project/"* "$dst/Project/" 2>/dev/null || true
    done
  done

  write_plist "$fw" "$name"
  echo "  $name/$slice ($(lipo -archs "$fw/$name" 2>/dev/null))"
}

# -- GRPCAll --
make_thin_slice GRPCAll ios-arm64                    "$DEV"              "$GRPC_OBJECTS" "$GRPC_MODULES"
make_fat_slice  GRPCAll ios-arm64_x86_64-simulator   "$SIM_A" "$SIM_X"  "$GRPC_OBJECTS" "$GRPC_MODULES"
make_fat_slice  GRPCAll ios-arm64_x86_64-maccatalyst "$CAT_A" "$CAT_X"  "$GRPC_OBJECTS" "$GRPC_MODULES"

# -- SwiftProtobuf --
make_thin_slice SwiftProtobuf ios-arm64                    "$DEV"              "$PB_OBJECTS" "$PB_MODULES"
make_fat_slice  SwiftProtobuf ios-arm64_x86_64-simulator   "$SIM_A" "$SIM_X"  "$PB_OBJECTS" "$PB_MODULES"
make_fat_slice  SwiftProtobuf ios-arm64_x86_64-maccatalyst "$CAT_A" "$CAT_X"  "$PB_OBJECTS" "$PB_MODULES"

# -- P256K --
make_thin_slice P256K ios-arm64                    "$DEV"              "$P256K_OBJECTS" "$P256K_MODULES"
make_fat_slice  P256K ios-arm64_x86_64-simulator   "$SIM_A" "$SIM_X"  "$P256K_OBJECTS" "$P256K_MODULES"
make_fat_slice  P256K ios-arm64_x86_64-maccatalyst "$CAT_A" "$CAT_X"  "$P256K_OBJECTS" "$P256K_MODULES"

# ── Step 3: Assemble xcframeworks ───────────────────────────────
# NOTE: We manually assemble xcframeworks instead of using xcodebuild -create-xcframework,
# because the latter requires .swiftinterface files when the framework name matches a module
# name. Since we use binary .swiftmodule (not BUILD_LIBRARY_FOR_DISTRIBUTION), we create
# the xcframework structure directly.
echo ""
echo "=== Step 3/4: Assembling xcframeworks ==="

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

write_xcfw_plist() {
  local name="$1" out="$2"
  cat > "$out/Info.plist" << XCPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>$name.framework/$name</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>$name.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
		<dict>
			<key>BinaryPath</key>
			<string>$name.framework/$name</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64_x86_64-simulator</string>
			<key>LibraryPath</key>
			<string>$name.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>simulator</string>
		</dict>
		<dict>
			<key>BinaryPath</key>
			<string>$name.framework/$name</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64_x86_64-maccatalyst</string>
			<key>LibraryPath</key>
			<string>$name.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>maccatalyst</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
XCPLIST
}

for name in GRPCAll SwiftProtobuf P256K; do
  echo "  Creating $name.xcframework..."
  xcfw="$OUTPUT/$name.xcframework"
  mkdir -p "$xcfw"
  for slice in ios-arm64 ios-arm64_x86_64-simulator ios-arm64_x86_64-maccatalyst; do
    mkdir -p "$xcfw/$slice"
    cp -a "$STAGE/$name/$slice/$name.framework" "$xcfw/$slice/"
  done
  write_xcfw_plist "$name" "$xcfw"
done

# Write C module declarations for GRPCAll.
# Binary .swiftmodule files record dependencies on C modules (CNIOPosix, etc.).
# The actual C code is linked into GRPCAll's static library, but the compiler
# still needs modulemap declarations to satisfy the module dependency graph.
echo "  Writing C module declarations for GRPCAll..."
for slice in ios-arm64 ios-arm64_x86_64-simulator ios-arm64_x86_64-maccatalyst; do
  cat > "$OUTPUT/GRPCAll.xcframework/$slice/GRPCAll.framework/Modules/module.modulemap" << 'MODMAP'
module CGRPCZlib {
}
module CNIOAtomics {
}
module CNIOBoringSSL {
}
module CNIOBoringSSLShims {
}
module CNIODarwin {
}
module CNIOLLHTTP {
}
module CNIOLinux {
}
module CNIOOpenBSD {
}
module CNIOPosix {
}
module CNIOWASI {
}
module CNIOWindows {
}
module _AtomicsShims {
}
MODMAP
done

# ── Step 4: VERSIONS file ──────────────────────────────────────
echo ""
echo "=== Step 4/4: Recording versions ==="

RESOLVED="$PROJECT_DIR/KaChat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

{
  echo "# Prebuilt XCFramework Versions"
  echo "# Regenerate with: bash scripts/build_xcframeworks.sh"
  echo ""
  echo "Build date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Xcode: $(xcodebuild -version | head -1) ($(xcodebuild -version | tail -1))"
  echo "Swift: $(swift --version 2>&1 | head -1)"
  echo "macOS: $(sw_vers -productVersion) ($(uname -m))"
  echo ""
  echo "# SPM Package Versions"
  if [[ -f "$RESOLVED" ]]; then
    python3 -c "
import json
with open('$RESOLVED') as f:
    d = json.load(f)
for p in sorted(d['pins'], key=lambda x: x['identity']):
    v = p['state'].get('version', p['state'].get('revision','?')[:12])
    print(f\"{p['identity']}: {v}\")
"
  else
    echo "(Package.resolved not found)"
  fi
} > "$OUTPUT/VERSIONS"

echo ""
echo "============================================"
echo "  Done!"
echo "============================================"
echo ""
echo "Output:"
ls -lh "$OUTPUT/"*.xcframework 2>/dev/null || true
echo ""
cat "$OUTPUT/VERSIONS"
echo ""
echo "Next steps:"
echo "  1. Modify KaChat.xcodeproj to reference xcframeworks instead of SPM"
echo "  2. Add SWIFT_INCLUDE_PATHS for GRPCAll modules"
echo "  3. Clean build and verify"
