#!/bin/bash
# Builds Mango.dmg — a drag-to-Applications installer.
#
# The app is signed ad-hoc and not notarised, so Gatekeeper warns on first
# launch and the user has to approve it in Privacy & Security. That is expected
# for a self-distributed build.
set -e
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
STAGE="$(mktemp -d)"
DMG="Mango-$VERSION.dmg"

# Build only; do not touch the installed copy or the running app.
# --dist signs ad-hoc: a Development certificate only validates on the
# developer's own provisioned Macs and is killed at launch on anyone else's.
./build.sh --no-install --dist

# ditto preserves the code signature; cp -R can break the seal.
ditto Mango.app "$STAGE/Mango.app"
ln -s /Applications "$STAGE/Applications"

# Short install note travels with the disk image.
cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Installing Mango
================

1. Drag Mango.app onto the Applications folder.

2. Open it. macOS will refuse the first time and may warn about malware.
   This build is not notarised, which is why -- there is nothing to
   download or scan, macOS simply cannot verify an app it has not seen.

   To allow it:
     System Settings -> Privacy & Security
     scroll to Security, find the message about Mango,
     click "Open Anyway", then confirm.

   If that option is not there, right-click Mango in Applications,
   choose Open, then Open again in the dialog.

3. Grant Accessibility permission when asked. This is what lets the
   brightness and volume keys work:
     System Settings -> Privacy & Security -> Accessibility -> enable Mango

Mango lives in the menu bar, not the Dock -- look for the mango icon at
the top right. There is no window and no Dock icon.

Requires an Apple Silicon Mac (M1 or later) running macOS 14 or later.
Intel Macs are not supported: the display control path does not exist there.
NOTE

rm -f "$DMG"
hdiutil create -volname "Mango" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "built $DMG"
