#!/bin/sh
# Xcode Cloud runs this after cloning and before the archive.
# App Store Connect rejects an upload whose CFBundleVersion was already used.
# CI_BUILD_NUMBER increases on every cloud build, so each TestFlight upload is new.
# Local Xcode builds leave the checked-in build number (1) alone.

set -eu

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "CI_BUILD_NUMBER is not set. Leaving CURRENT_PROJECT_VERSION unchanged."
  exit 0
fi

case "$CI_BUILD_NUMBER" in
  *[!0-9]*)
    echo "CI_BUILD_NUMBER must be a positive integer, got '${CI_BUILD_NUMBER}'." >&2
    exit 1
    ;;
esac

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
PROJECT="$ROOT/Postcam.xcodeproj/project.pbxproj"

if [ ! -f "$PROJECT" ]; then
  echo "Could not find $PROJECT" >&2
  exit 1
fi

# Info.plist publishes this setting as CFBundleVersion.
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};/g" "$PROJECT"

echo "Set CURRENT_PROJECT_VERSION to ${CI_BUILD_NUMBER}"
grep "CURRENT_PROJECT_VERSION" "$PROJECT"
