#!/usr/bin/env bash
# Builds the local Swift release .app with configurable display metadata.
#
# Optional variables:
#   PRODUCT_NAME  App bundle filename without .app.
#   DISPLAY_NAME  Finder / Spotlight name.
#   BUNDLE_ID     CFBundleIdentifier.
#   VERSION       CFBundleShortVersionString and CFBundleVersion.
#   INSTALL_APPS  If 1, copies the generated app to /Applications.
#   SIGN_IDENTITY Code signing identity. Defaults to ad-hoc signing (-).
#
# Usage:
#   ./build-app.sh
#   DISPLAY_NAME="Codex Vitals" PRODUCT_NAME="CodexVitals" ./build-app.sh
#
# Signing note: local builds default to ad-hoc signing. Public distribution
# builds should pass a Developer ID Application identity and be notarized.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PRODUCT_NAME="${PRODUCT_NAME:-CodexVitals}"
DISPLAY_NAME="${DISPLAY_NAME:-Codex Vitals}"
BUNDLE_ID="${BUNDLE_ID:-app.codexvitals.menubar}"
DEFAULT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT}/Support/Info.plist")"
VERSION="${VERSION:-$DEFAULT_VERSION}"
INSTALL_APPS="${INSTALL_APPS:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ICNS="${ROOT}/Support/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
	echo "Generating AppIcon.icns..."
	"${ROOT}/Support/make-icns.sh"
fi

echo "swift build -c release ..."
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
EXE="${BIN_DIR}/CodexVitals"
SPARKLE_FRAMEWORK="${ROOT}/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -x "$EXE" ]]; then
	echo "error: executable not found: $EXE" >&2
	exit 1
fi
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
	echo "error: Sparkle.framework not found: $SPARKLE_FRAMEWORK" >&2
	exit 1
fi

OUT="${ROOT}/dist/${PRODUCT_NAME}.app"
rm -rf "$OUT"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources" "${OUT}/Contents/Frameworks"
cp "$EXE" "${OUT}/Contents/MacOS/CodexVitals"
chmod +x "${OUT}/Contents/MacOS/CodexVitals"
ditto "$SPARKLE_FRAMEWORK" "${OUT}/Contents/Frameworks/Sparkle.framework"
cp "${ROOT}/Support/Info.plist" "${OUT}/Contents/Info.plist"
cp "$ICNS" "${OUT}/Contents/Resources/AppIcon.icns"
cp "${ROOT}/Support/codex.png" "${OUT}/Contents/Resources/codex.png"
cp "${ROOT}/Support/ClaudeSpark.png" "${OUT}/Contents/Resources/ClaudeSpark.png"
cp "${ROOT}/Support/RamterStudioLogo.png" "${OUT}/Contents/Resources/RamterStudioLogo.png"
cp "${ROOT}/THIRD-PARTY-NOTICES.txt" "${OUT}/Contents/Resources/THIRD-PARTY-NOTICES.txt"
if [[ -f "${ROOT}/.build/checkouts/Sparkle/LICENSE" ]]; then
	cp "${ROOT}/.build/checkouts/Sparkle/LICENSE" "${OUT}/Contents/Resources/Sparkle-LICENSE.txt"
fi
xattr -cr "$OUT" 2>/dev/null || true

PLIST="${OUT}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${DISPLAY_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${DISPLAY_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$PLIST"

if command -v codesign &>/dev/null; then
	if [[ "$SIGN_IDENTITY" == "-" ]]; then
		codesign --force --deep --sign - "$OUT"
	else
		codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$OUT"
	fi
	codesign --verify --deep --strict --verbose=2 "$OUT"
fi

echo "OK: $OUT"
echo "   Open: open \"$OUT\""
echo "   Spotlight: search for \"${DISPLAY_NAME}\"."

if [[ "$INSTALL_APPS" == "1" ]]; then
	DEST="/Applications/${PRODUCT_NAME}.app"
	rm -rf "$DEST"
	cp -R "$OUT" "$DEST"
	echo "Installed: $DEST"
fi
