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
  <key>CFBundleVersion</key><string>1.1.1</string>
  <key>CFBundleShortVersionString</key><string>1.1.1</string>
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

# Two signing modes, because they want opposite things.
#
# Local development signs with the Apple Development certificate: the code hash
# stays identical across rebuilds, so macOS keeps honouring the Accessibility
# grant. An ad-hoc signature changes hash every build and silently invalidates
# it — System Settings keeps showing the app enabled while the keys stop working.
#
# Distribution must NOT use that certificate. A Development-signed app carries a
# team identity that only validates on devices provisioned for that account, so
# on anyone else's Mac it is killed at launch: it appears to open, then vanishes
# with no menu bar icon. Ad-hoc has no identity to validate, so it runs anywhere
# once the user approves it in Privacy & Security. Pass --dist for that.
if [ "$1" = "--dist" ] || [ "$2" = "--dist" ]; then
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "signed ad-hoc for distribution"
else
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')

  if [ -n "$IDENTITY" ]; then
    codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "signed with: $IDENTITY"
  else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "signed ad-hoc (grant will reset on each rebuild)"
  fi
fi

echo "built $APP"
