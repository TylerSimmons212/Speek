#!/usr/bin/env bash
# Build, sign, notarize, staple, and package Speek as a distributable .dmg.
#
# Prereqs (one-time, see README):
#   1. Developer ID Application cert installed in login keychain
#   2. Notary credentials saved as profile "Speek-Notary":
#        xcrun notarytool store-credentials Speek-Notary \
#          --apple-id <you> --team-id 7MGPA96634 --password <app-specific-pw>
#
# Usage: ./scripts/release.sh

set -euo pipefail

# --- Config ---
TEAM_ID="7MGPA96634"
SIGNING_IDENTITY="Developer ID Application: Tyler Simmons (7MGPA96634)"
NOTARY_PROFILE="Speek-Notary"
SCHEME="Speek"
PROJECT="Speek.xcodeproj"

# --- Paths ---
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Speek.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/Speek.app"
DMG_PATH="$BUILD_DIR/Speek.dmg"

echo "🧹 Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "🔧 Regenerating Xcode project from project.yml..."
xcodegen generate >/dev/null

echo "📦 Archiving Release build (Developer ID + hardened runtime)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive | xcbeautify --quiet 2>/dev/null || \
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive

echo "📝 Writing export options..."
cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

echo "📤 Exporting signed .app..."
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist"

echo "✅ Built: $APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier" | head -3

echo "💿 Building .dmg..."
hdiutil create \
  -volname "Speek" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "🔐 Submitting to Apple notary service (typically 1-5 min)..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "📎 Stapling notarization ticket to .dmg..."
xcrun stapler staple "$DMG_PATH"

echo "🔎 Verifying..."
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature "$DMG_PATH" 2>&1 || true

echo ""
echo "🎉 Done!"
echo "   Distributable: $DMG_PATH"
ls -lh "$DMG_PATH"
