#!/bin/bash
# Builds a clean, shareable GlowBar for GitHub Releases.
# Builds in a neutral folder so no personal file paths end up inside the app,
# strips debug info, checks the result, and puts GlowBar-app-<version>.zip on your Desktop.
# It does NOT install anything on this Mac.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="/tmp/GlowBarRelease"
VERSION=$(date +"1.%-m.%-d.%Y.%H%M")
BUILDNUM=$(date +"%Y%m%d%H%M")

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Apple's free developer tools are needed. Click Install in the window that appears, then run this again."
  xcode-select --install || true; exit 1
fi

echo "Copying source to a neutral folder…"
rm -rf "$WORK"; mkdir -p "$WORK"
cp -R "$SRC/Package.swift" "$SRC/Sources" "$SRC/Info.plist" "$SRC/AppIcon.icns" "$WORK/"
cd "$WORK"

echo "Building GlowBar ${VERSION}…"
swift build -c release -Xswiftc -gnone
BIN="$(swift build -c release --show-bin-path)/GlowBar"

APP="$WORK/out/GlowBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GlowBar"
strip -x "$APP/Contents/MacOS/GlowBar" 2>/dev/null || true
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILDNUM" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Checking for anything personal inside the app…"
ME="$(whoami)"
if grep -a -q -i -e "$ME" -e "/Users/" "$APP/Contents/MacOS/GlowBar"; then
  echo "❌ Found a personal path inside the app — not packaging it. Send this message to Claude."
  grep -a -o -i -e "/Users/[^ \"]*" "$APP/Contents/MacOS/GlowBar" | sort -u | head
  exit 1
fi
echo "✅ Clean: no usernames or home-folder paths inside."

OUT="$HOME/Desktop/GlowBar-app-${VERSION}.zip"
( cd "$WORK/out" && ditto -c -k --keepParent GlowBar.app "$OUT" )
rm -rf "$WORK" "$HOME/Library/Caches/org.swift.swiftpm"
echo ""
echo "✅ Ready to upload: $OUT"
echo "   Version ${VERSION}"
