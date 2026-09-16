#!/bin/sh
#
# Xcode Cloud runs this after cloning the repo, before the build starts.
#
# Build numbers are NOT set here any more. This script used to stamp every target with Xcode
# Cloud's $CI_BUILD_NUMBER so the app and its extensions matched (App Store Connect rejects
# an archive where they differ); that job moved to ci_pre_xcodebuild.sh, which stamps the
# number from KaChat/Version.xcconfig instead - see the reasoning there.
#
# Secrets: Xcode Cloud has no gitignored Secrets.xcconfig, so materialize it from the
# workflow's (secret) environment variables. Missing var -> file simply not written, and the
# optional #include? in Version.xcconfig keeps the build green (Swap runs keyless).

set -e

if [ -n "$CHANGENOW_API_KEY" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    printf 'CHANGENOW_API_KEY = %s\n' "$CHANGENOW_API_KEY" > KaChat/Secrets.xcconfig
fi
