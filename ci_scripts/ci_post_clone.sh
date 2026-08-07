#!/bin/sh
#
# Xcode Cloud runs this after cloning the repo, before the build starts. Its only job: make
# every target (main app, KaChatNotificationService, KaChatShareExtension) share the exact
# build number Xcode Cloud is about to assign for this run.
#
# Xcode Cloud's automatic build-number management stamps the archived main app's
# CFBundleVersion after the fact, but it doesn't touch nested app extensions - and App Store
# Connect rejects an archive where they don't match ("The CFBundleVersion of an app extension
# must match that of its containing parent app"). Setting CURRENT_PROJECT_VERSION for every
# target to $CI_BUILD_NUMBER before the build runs means the mismatch never has a chance to
# happen, regardless of what Xcode Cloud does afterward to the main app specifically.
#
# Requires VERSIONING_SYSTEM = apple-generic (set in KaChat/Version.xcconfig, shared by every
# target) - without it, agvtool fails with "not using Apple Generic Versioning".
#
# Only archive builds need this; other actions (plain build/test) don't produce anything
# uploaded to App Store Connect, so there's nothing to keep in sync for those.

set -e

if [ "$CI_XCODEBUILD_ACTION" = "archive" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    agvtool new-version -all "$CI_BUILD_NUMBER"
fi

# Secrets: Xcode Cloud has no gitignored Secrets.xcconfig, so materialize it from the
# workflow's (secret) environment variables. Missing var -> file simply not written, and the
# optional #include? in Version.xcconfig keeps the build green (Swap runs keyless).
if [ -n "$CHANGENOW_API_KEY" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    printf 'CHANGENOW_API_KEY = %s\n' "$CHANGENOW_API_KEY" > KaChat/Secrets.xcconfig
fi
