# Mango 🥭

A menu bar app for brightness, volume, and audio routing across a MacBook's
built-in display and an external DDC-capable monitor.

Written because BenQ's Display Pilot 2 drives the monitor over the same public
DDC/CI protocol, but wraps it in a slow Qt/WebEngine UI and ignores the laptop
panel entirely.

## Features

- **Two brightness sliders** — the external monitor and the built-in panel,
  controlled independently.
- **Function keys** — `F1`/`F2` drive the monitor, `⌥F1`/`⌥F2` the built-in
  panel. With no monitor attached, both drive the built-in panel.
- **Volume** for whichever output is active, including monitors whose volume
  lives in hardware rather than in CoreAudio.
- **Trackpad volume** — rest one finger on the right edge of the trackpad for
  a moment until it clicks, then slide up or down to change the volume of whatever is playing: speakers,
  Bluetooth headphones, or the monitor. The cursor stays put while you do it.
- **Feature switches** — *Monitor control* (brightness sliders and `F1`/`F2`)
  and *Volume control* (trackpad edge, volume slider, volume keys) can each be
  turned off from the panel; a disabled feature hands its keys back to macOS.
- **Audio output and input switching** from the same panel.
- A compact HUD under the menu bar, replacing the macOS one.

## Install

Requires an **Apple Silicon Mac** (M1 or later) on macOS 14+. Intel Macs are not
supported — the display control path does not exist there.

Download the latest `Mango-*.dmg` from [Releases](../../releases), then:

1. Drag **Mango.app** to **Applications**.
2. Open it. macOS refuses the first time and may warn about malware. The build
   is not notarised, which is the whole reason: macOS cannot verify an app it
   has not seen before. To allow it, go to **System Settings → Privacy &
   Security**, scroll to **Security**, and click **Open Anyway** next to the
   message about Mango.
3. Grant Accessibility permission when prompted — this is what lets the
   brightness and volume keys work:
   **System Settings → Privacy & Security → Accessibility → enable Mango**

Mango lives in the menu bar, not the Dock. Look for the mango icon at the top
right; there is no window and no Dock icon.

## Build from source

Requires Xcode command line tools. No Xcode project, no dependencies.

    ./build.sh --install     # build, sign, install to /Applications
    ./package.sh 1.0         # build Mango-1.0.dmg

`build.sh` signs with an Apple Development certificate for local use, so the
code hash stays identical across rebuilds and macOS keeps honouring the
Accessibility grant. An ad-hoc signature changes hash every build and silently
invalidates it — System Settings keeps showing the app enabled while the keys
stop working.

`--dist` (which `package.sh` passes) signs ad-hoc instead. That is deliberate:
a Development certificate carries a team identity that only validates on Macs
provisioned for that developer account, so a Development-signed build is killed
at launch on anyone else's machine — it appears to open, then vanishes with no
menu bar icon. Ad-hoc has no identity to validate and runs anywhere once the
user approves it.

## How it works

| Control | Built-in display | External monitor |
| --- | --- | --- |
| Brightness | `DisplayServices` | DDC/CI VCP `0x10` |
| Volume | CoreAudio | CoreAudio, or DDC VCP `0x62` |

DDC/CI is spoken directly over I2C through `IOAVService`, the same public path
any DDC utility uses. The bus is slow — roughly 100 ms per read and 75 ms per
write — so all traffic runs on a background queue with cached values, and
writes coalesce to the newest pending value. Dragging a slider tracks the
finger rather than replaying a backlog.

Volume takes one of two paths depending on the active output device. Most
devices expose a CoreAudio volume; DisplayPort and HDMI monitors do not,
because their volume lives in the monitor's own hardware and is reachable only
over DDC.

## Command line

`mon` is a small CLI sharing the same DDC engine:

    mon                  # status for both displays
    mon b|eb <0-100>     # built-in / external brightness
    mon v <0-100>        # external volume
    mon dim | bright     # both displays at once

Build it with:

    swiftc -O -o mon src/DDC.swift src/Builtin.swift src/main.swift

## Monitor compatibility

Developed against a **BenQ EW2790U** over USB-C. Any monitor that answers
DDC/CI should work for brightness, contrast, and volume, though vendor
specifics vary.

Two findings specific to this panel, likely shared by other BenQ models:

- **Picture mode locks brightness.** VCP `0xDC` selects the picture mode.
  In HDR and cinema modes the firmware drives the backlight itself:
  brightness writes are accepted and read back correctly, but the panel
  ignores them, so brightness appears to flash and snap back. Mango detects
  this and offers to switch the monitor to Standard.
- **Colour modes are read-only.** The monitor advertises presets on VCP
  `0x14` but silently ignores writes. Display Pilot 2 cannot change them over
  DDC either. Use the monitor's OSD joystick.

## Requirements

- Apple Silicon Mac (the DDC path uses `IOAVService`)
- macOS 14 or later
- A monitor connected by USB-C, DisplayPort, or HDMI

## Licence

MIT
