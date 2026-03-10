#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# TranslateCall — End-to-end Release Build Script
#
# Usage:
#   TEAM_ID=XXXXXXXXXX NOTARYTOOL_PROFILE=TranslateCallProfile ./scripts/build-release.sh
#
# Prerequisites:
#   - Xcode Command Line Tools installed
#   - Developer ID Application certificate in Keychain
#   - notarytool credential profile stored via:
#       xcrun notarytool store-credentials TranslateCallProfile \
#           --apple-id you@example.com --team-id XXXXXXXXXX
# =============================================================================

# --- Configuration -----------------------------------------------------------
APP_NAME="TranslateCall"
VERSION="0.5.0"
BUILD_DIR="build/release"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}-beta.zip"
STAGING_DIR="${BUILD_DIR}/dmg-staging"
DMG_NAME="${APP_NAME}-${VERSION}-beta.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

# --- Env var validation -------------------------------------------------------
: "${TEAM_ID:?ERROR: TEAM_ID env var is required (your Apple Developer Team ID)}"
: "${NOTARYTOOL_PROFILE:?ERROR: NOTARYTOOL_PROFILE env var is required (keychain profile name for notarytool)}"

# --- Tool checks -------------------------------------------------------------
command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found — install Xcode Command Line Tools"; exit 1; }
command -v hdiutil >/dev/null 2>&1 || { echo "ERROR: hdiutil not found"; exit 1; }

# --- Prepare output directory ------------------------------------------------
mkdir -p "${BUILD_DIR}"

echo "============================================================"
echo "  TranslateCall ${VERSION}-beta — Release Build"
echo "  Team ID: ${TEAM_ID}"
echo "============================================================"

# --- Step 1: Archive ---------------------------------------------------------
echo ""
echo "▶ Step 1/4 — Archiving..."
xcodebuild archive \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    | xcpretty 2>/dev/null || true

[ -d "${ARCHIVE_PATH}" ] || { echo "ERROR: Archive not found at ${ARCHIVE_PATH}"; exit 1; }
echo "  ✓ Archive: ${ARCHIVE_PATH}"

# --- Step 2: Export ----------------------------------------------------------
echo ""
echo "▶ Step 2/4 — Exporting (Developer ID)..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "scripts/ExportOptions.plist" \
    DEVELOPMENT_TEAM="${TEAM_ID}"

[ -d "${APP_PATH}" ] || { echo "ERROR: Exported .app not found at ${APP_PATH}"; exit 1; }
echo "  ✓ Export: ${APP_PATH}"

# --- Step 3: Notarize --------------------------------------------------------
echo ""
echo "▶ Step 3/4 — Notarizing (this may take 2–8 minutes)..."
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARYTOOL_PROFILE}" \
    --wait \
    --timeout 600

echo "  ✓ Notarization complete — stapling..."
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
echo "  ✓ Staple verified"

# --- Step 4: Create DMG ------------------------------------------------------
echo ""
echo "▶ Step 4/4 — Creating DMG..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -sf /Applications "${STAGING_DIR}/Applications"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"
rm -rf "${STAGING_DIR}"

DMG_SIZE=$(du -sh "${DMG_PATH}" | cut -f1)
echo "  ✓ DMG: ${DMG_PATH} (${DMG_SIZE})"

# --- Done --------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Build complete!"
echo "  DMG: ${DMG_PATH}"
echo ""
echo "  Next steps:"
echo "    1. git tag -s v${VERSION}-beta -m 'M5 Beta Release'"
echo "    2. git push origin v${VERSION}-beta"
echo "    3. gh release create v${VERSION}-beta \\"
echo "           \"${DMG_PATH}#${DMG_NAME}\" \\"
echo "           --title 'TranslateCall v${VERSION} Beta' \\"
echo "           --notes-file scripts/release-notes.md \\"
echo "           --prerelease"
echo "============================================================"
