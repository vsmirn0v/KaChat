#!/bin/sh
#
# Xcode Cloud runs this right before xcodebuild. For archives it stamps every target's
# CURRENT_PROJECT_VERSION with the build number the repo says (KaChat/Version.xcconfig), so the
# build settings agree with what a local archive would use.
#
# This does NOT decide the shipped build number on Xcode Cloud, and neither does the explicit
# CFBundleVersion = $(KACHAT_BUILD_NUMBER) in every Info.plist: Cloud rewrites CFBundleVersion
# inside the archived bundles afterwards with its own per-product counter, which only counts
# up. Both approaches were tried on 2026-09-15 and both archives came out with the long
# number. Kept so Cloud and local builds at least start from the same settings; the number
# that ships from Cloud is Cloud's.
#
# Requires VERSIONING_SYSTEM = apple-generic (set in KaChat/Version.xcconfig, shared by every
# target) - without it, agvtool fails with "not using Apple Generic Versioning".

set -e

if [ "$CI_XCODEBUILD_ACTION" = "archive" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    BUILD_NUMBER=$(sed -n 's/^CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' KaChat/Version.xcconfig | head -n 1)
    if [ -z "$BUILD_NUMBER" ]; then
        echo "ci_pre_xcodebuild: CURRENT_PROJECT_VERSION not found in KaChat/Version.xcconfig" >&2
        exit 1
    fi
    agvtool new-version -all "$BUILD_NUMBER"
    echo "ci_pre_xcodebuild: stamped every target with build $BUILD_NUMBER from Version.xcconfig (Xcode Cloud's CI_BUILD_NUMBER=$CI_BUILD_NUMBER ignored)"
fi
