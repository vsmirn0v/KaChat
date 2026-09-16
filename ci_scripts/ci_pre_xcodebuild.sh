#!/bin/sh
#
# Xcode Cloud runs this right before xcodebuild. For archives it stamps every target (main
# app, KaChatNotificationService, KaChatShareExtension, widgets) with the build number the
# REPO says - CURRENT_PROJECT_VERSION in KaChat/Version.xcconfig - so a Cloud archive carries
# exactly what a local archive would: 5.0 (1), 5.0 (2), ...
#
# Why not Xcode Cloud's own $CI_BUILD_NUMBER, as ci_post_clone.sh used to stamp: that counter
# is per product, shared by every workflow, and can only ever go UP (App Store Connect refuses
# to lower it). An early date-stamp script pushed it to 202607032479, so every beta from Cloud
# was going to read 5.0 (202607032480) forever. Taking the number from the repo instead makes
# the build number a deliberate, reviewable value again.
#
# The cost: the number has to be bumped in Version.xcconfig for every beta that goes to
# TestFlight. App Store Connect rejects an upload whose build number is not higher than the
# last one in the same marketing version, so a forgotten bump fails loudly at upload time
# rather than shipping a duplicate.
#
# Runs at the last possible moment (pre-xcodebuild rather than post-clone) so nothing Xcode
# Cloud does to the project between clone and build can put its own number back.
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
