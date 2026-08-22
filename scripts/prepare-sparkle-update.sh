#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT}/Support/Info.plist")}"
ARCHIVE="${2:-${ROOT}/dist/CodexVitals-${VERSION}.dmg}"
RELEASE_NOTES="${3:-}"
RAMTERSTUDIO_ROOT="${RAMTERSTUDIO_ROOT:-${ROOT}/../RamterStudio}"
APPCAST="${RAMTERSTUDIO_ROOT}/codex-vitals/appcast.xml"
GENERATOR="${ROOT}/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
STAGING="${ROOT}/dist/sparkle-appcast"

if [[ ! -f "$ARCHIVE" ]]; then
    echo "error: update archive not found: $ARCHIVE" >&2
    exit 1
fi
if [[ ! -x "$GENERATOR" ]]; then
    echo "error: Sparkle generate_appcast tool not found; run 'swift package resolve' first." >&2
    exit 1
fi
if [[ ! -d "$RAMTERSTUDIO_ROOT" ]]; then
    echo "error: RamterStudio checkout not found: $RAMTERSTUDIO_ROOT" >&2
    exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$ARCHIVE" "$STAGING/"
if [[ -f "$APPCAST" ]]; then
    cp "$APPCAST" "$STAGING/appcast.xml"
fi
if [[ -n "$RELEASE_NOTES" ]]; then
    if [[ ! -f "$RELEASE_NOTES" ]]; then
        echo "error: release notes not found: $RELEASE_NOTES" >&2
        exit 1
    fi
    cp "$RELEASE_NOTES" "$STAGING/$(basename "${ARCHIVE%.*}").md"
fi

"$GENERATOR" \
    --download-url-prefix "https://github.com/Joowonoil/Codex-Vitals/releases/download/v${VERSION}/" \
    --link "https://ramterstudio.com/codex-vitals/" \
    --full-release-notes-url "https://github.com/Joowonoil/Codex-Vitals/releases" \
    --embed-release-notes \
    --maximum-versions 5 \
    "$STAGING"

xmllint --noout "$STAGING/appcast.xml"
cp "$STAGING/appcast.xml" "$APPCAST"

echo "Updated Sparkle feed: $APPCAST"
echo "Archive: $ARCHIVE"
echo "Publish the GitHub release asset before deploying RamterStudio."
