#!/bin/bash
# Builds GlowBar from source and installs it in /Applications.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Apple's free developer tools are needed. A window will pop up — click Install,"
  echo "wait for it to finish, then run this script again."
  xcode-select --install || true
  exit 1
fi

echo "Building GlowBar…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/GlowBar"

APP="build/GlowBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GlowBar"
cp Info.plist "$APP/Contents/Info.plist"

# Version: 1.month.day.year.time (24-hour), stamped when the update was made (VERSION file),
# or now if there isn't one.
VERSION=$(cat VERSION 2>/dev/null || date +"1.%-m.%-d.%Y.%H%M")
BUILDNUM=$(echo "$VERSION" | awk -F. '{printf "%s%02d%02d%s", $4, $2, $3, $5}')
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILDNUM" "$APP/Contents/Info.plist"
echo "Version $VERSION"

# Optional app icon
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --deep --sign - "$APP"

echo "Installing to /Applications…"
pkill -f "GlowBar.app/Contents/MacOS/GlowBar" 2>/dev/null || true
# make sure the old copy is really gone (force it after 3 seconds), or macOS will just re-show it
for i in 1 2 3 4 5 6; do pgrep -f "GlowBar.app/Contents/MacOS/GlowBar" >/dev/null || break; sleep 0.5; done
pkill -9 -f "GlowBar.app/Contents/MacOS/GlowBar" 2>/dev/null || true
sleep 0.5
rm -rf /Applications/GlowBar.app
cp -R "$APP" /Applications/
touch /Applications/GlowBar.app   # refresh the icon in Finder and the Dock
open /Applications/GlowBar.app
echo "Done. GlowBar is running — look for the rays icon in your menu bar."
