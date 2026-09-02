#!/bin/bash
# Builds Mango.app. Signed with a stable identifier so macOS keeps the
# Accessibility grant across rebuilds.
set -e
APP="Mango.app"
BUNDLE_ID="com.adithya.mango"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon + menu bar template images
if [ -f Assets/Mango.icns ]; then
  cp Assets/Mango.icns "$APP/Contents/Resources/Mango.icns"
fi
for f in menubar.png menubar@2x.png; do
  [ -f "Assets/$f" ] && cp "Assets/$f" "$APP/Contents/Resources/$f"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mango</string>
  <key>CFBundleDisplayName</key><string>Mango</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0.1</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Mango</string>
  <key>CFBundleIconFile</key><string>Mango</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -O -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit -framework CoreAudio \
  -framework AudioToolbox -framework CoreGraphics -framework IOKit \
  -framework ServiceManagement \
  -o "$APP/Contents/MacOS/Mango" \
  App/Sources/*.swift

# Sign with a real identity when one exists. An ad-hoc signature changes hash
# on every build, which silently invalidates the Accessibility grant: System
# Settings keeps showing the app enabled while macOS no longer matches it.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')

if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "signed ad-hoc (grant will reset on each rebuild)"
fi

# Install to a stable location; TCC ties the grant to the app's path as well
# as its signature.
if [ "$1" != "--no-install" ] && { [ -d "/Applications/Mango.app" ] || [ "$1" = "--install" ]; }; then
  pkill -f "Mango.app" 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Mango.app
  cp -R "$APP" /Applications/Mango.app
  echo "installed to /Applications/Mango.app"
fi

echo "built $APP"
