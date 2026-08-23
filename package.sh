#!/bin/bash
# Builds Mango.dmg — a drag-to-Applications installer.
#
# The app is signed with a Development certificate, not a Distribution one, so
# it is not notarised: Gatekeeper will warn on first launch and the user has to
# right-click → Open once. That is expected for a self-distributed build.
set -e
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
STAGE="$(mktemp -d)"
DMG="Mango-$VERSION.dmg"

./build.sh

# ditto preserves the code signature; cp -R can break the seal.
ditto Mango.app "$STAGE/Mango.app"
ln -s /Applications "$STAGE/Applications"

# Short install note travels with the disk image.
cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Installing Mango
================

1. Drag Mango.app onto the Applications folder.
2. Open Applications and RIGHT-CLICK Mango -> Open, then confirm.
   (Needed only the first time: this build is signed but not notarised.)
3. Grant Accessibility permission when asked. This is what lets the
   brightness and volume keys work:
   System Settings -> Privacy & Security -> Accessibility -> enable Mango

Mango lives in the menu bar, not the Dock.
NOTE

rm -f "$DMG"
hdiutil create -volname "Mango" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "built $DMG"
