#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="${PROJECT:-KaChat.xcodeproj}"
SCHEME="${SCHEME:-KaChat}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData-CI}"
ACTION="${ACTION:-build}"

echo "Resolving Swift packages for ${PROJECT}/${SCHEME}..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -resolvePackageDependencies

echo "Running xcodebuild (${ACTION}) with CI performance flags..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -disableAutomaticPackageResolution \
  COMPILER_INDEX_STORE_ENABLE=NO \
  "$ACTION"
