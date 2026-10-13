#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Synced"
APP_VERSION="${APP_VERSION:-${1:-}}"
if [[ -z "$APP_VERSION" ]]; then
  echo "Usage: scripts/package-dmg.sh <version>" >&2
  exit 2
fi
BUILD_NUMBER="${BUILD_NUMBER:-${APP_VERSION//./}}"
BUNDLE_ID="com.zhoujia.codex-synced"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
VERSIONED_DMG_PATH="$DIST_DIR/Codex-Synced-macOS-$APP_VERSION.dmg"
DMG_STAGING_DIR="$DIST_DIR/dmg-staging"
RW_DMG="$DIST_DIR/$APP_NAME-rw.dmg"
ICON_SOURCE="$ROOT_DIR/Resources/AppIconSource.png"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"
mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR" "$DMG_STAGING_DIR" "$DMG_PATH" "$VERSIONED_DMG_PATH" "$RW_DMG"
if [[ -d "/Volumes/$APP_NAME" ]]; then
  hdiutil detach "/Volumes/$APP_NAME" || true
fi

if [[ -n "${CODEX_SDK_PATH:-}" ]]; then
  swift build -c release --disable-sandbox --sdk "$CODEX_SDK_PATH"
else
  swift build -c release --disable-sandbox
fi

if [[ -f "$ICON_SOURCE" ]]; then
  "$ROOT_DIR/scripts/generate-app-icon.sh"
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/CodexSynced" "$MACOS_DIR/Codex Synced"
chmod +x "$MACOS_DIR/Codex Synced"

if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi
swift "$ROOT_DIR/scripts/make-dmg-background.swift" "$RESOURCES_DIR/DMGBackground.png"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Codex Synced</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi

mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDRW "$RW_DMG"
MOUNT_DIR="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | awk 'index($0, "/Volumes/") { print substr($0, index($0, "/Volumes/")); exit }')"

osascript <<APPLESCRIPT
with timeout of 300 seconds
  tell application "Finder"
    tell disk "$APP_NAME"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {120, 120, 880, 540}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 96
      set background picture of viewOptions to POSIX file "$MOUNT_DIR/$APP_NAME.app/Contents/Resources/DMGBackground.png"
      set position of item "$APP_NAME.app" of container window to {190, 218}
      set position of item "Applications" of container window to {570, 218}
      close
      open
      update without registering applications
      delay 1
    end tell
  end tell
end timeout
APPLESCRIPT

rm -rf "$MOUNT_DIR/.fseventsd"
hdiutil detach "$MOUNT_DIR"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
cp "$DMG_PATH" "$VERSIONED_DMG_PATH"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$VERSIONED_DMG_PATH"
fi
rm -rf "$DMG_STAGING_DIR" "$RW_DMG"

echo "$DMG_PATH"
echo "$VERSIONED_DMG_PATH"
