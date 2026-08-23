import Foundation

// mon — unified control for the built-in Retina panel and an external DDC display.

func percent(_ cur: UInt16, _ maxV: UInt16) -> String {
    maxV == 0 ? "\(cur)" : "\(Int((Double(cur) / Double(maxV) * 100).rounded()))%"
}

func bar(_ fraction: Double, width: Int = 20) -> String {
    let filled = max(0, min(width, Int((fraction * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func showStatus() {
    if let b = BuiltinDisplay.brightness {
        print("  built-in   brightness  \(bar(Double(b)))  \(Int((b * 100).rounded()))%")
    } else {
        print("  built-in   brightness  unavailable")
    }

    guard let ext = ExternalDisplay() else {
        print("  external   not found (no DDC display connected)")
        return
    }
    let rows: [(String, VCP)] = [
        ("brightness", .luminance),
        ("contrast  ", .contrast),
        ("volume    ", .volume),
    ]
    for (label, code) in rows {
        if let (cur, maxV) = ext.readBlocking(code) {
            print("  external   \(label)  \(bar(Double(cur) / Double(max(maxV, 1))))  \(percent(cur, maxV))")
        } else {
            print("  external   \(label)  --")
        }
    }
    if let (cur, _) = ext.readBlocking(.colorPreset) {
        print("  external   color mode  \(cur)  (read-only in firmware)")
    }
}

func usage() {
    print("""
    mon — display control for built-in + external monitor

      mon                        show status
      mon b <0-100>              built-in brightness
      mon b +10 | -10            adjust built-in brightness
      mon eb <0-100>             external brightness
      mon eb +10 | -10           adjust external brightness
      mon v <0-100> | +5 | -5    external volume
      mon mute                   toggle external mute
      mon c <0-100> | +5 | -5    external contrast
      mon all <0-100>            brightness on both displays
      mon dim                    both to 20%
      mon bright                 both to 100%
    """)
}

/// Parses "50", "+10", or "-10" against a current value.
func resolve(_ arg: String, current: Int, scale: Int) -> Int? {
    if arg.hasPrefix("+") || arg.hasPrefix("-") {
        guard let d = Int(arg) else { return nil }
        return current + d * scale / 100
    }
    guard let v = Int(arg), (0...100).contains(v) else { return nil }
    return v * scale / 100
}

let args = Array(CommandLine.arguments.dropFirst())

guard let cmd = args.first else {
    showStatus()
    exit(0)
}

switch cmd {
case "-h", "--help", "help":
    usage()

case "b":
    guard let arg = args.dropFirst().first else { usage(); exit(1) }
    if arg.hasPrefix("+") || arg.hasPrefix("-") {
        guard let d = Float(arg) else { usage(); exit(1) }
        BuiltinDisplay.adjustBrightness(by: d / 100)
    } else if let v = Float(arg), (0...100).contains(v) {
        BuiltinDisplay.setBrightness(v / 100)
    } else { usage(); exit(1) }
    showStatus()

case "eb", "v", "c":
    let feature: VCP = cmd == "eb" ? .luminance : (cmd == "v" ? .volume : .contrast)
    guard let arg = args.dropFirst().first, let ext = ExternalDisplay() else { usage(); exit(1) }
    guard let (cur, maxV) = ext.readBlocking(feature) else {
        print("external display did not respond"); exit(1)
    }
    if arg.hasPrefix("+") || arg.hasPrefix("-") {
        guard let d = Int(arg) else { usage(); exit(1) }
        let delta = d * Int(maxV) / 100
        ext.writeBlocking(feature, UInt16(clamping: max(0, min(Int(maxV), Int(cur) + delta))))
    } else {
        guard let target = resolve(arg, current: Int(cur), scale: Int(maxV)) else { usage(); exit(1) }
        ext.writeBlocking(feature, UInt16(clamping: max(0, min(Int(maxV), target))))
    }
    showStatus()

case "mute":
    guard let ext = ExternalDisplay() else { exit(1) }
    let muted = ext.readBlocking(.mute)?.current == 1
    ext.writeBlocking(.mute, muted ? 2 : 1)
    print("  external   \(muted ? "unmuted" : "muted")")

case "all", "dim", "bright":
    let target: Int
    if cmd == "dim" { target = 20 } else if cmd == "bright" { target = 100 }
    else if let a = args.dropFirst().first, let v = Int(a) { target = v } else { usage(); exit(1) }

    BuiltinDisplay.setBrightness(Float(target) / 100)
    if let ext = ExternalDisplay(), let (_, maxV) = ext.readBlocking(.luminance) {
        ext.writeBlocking(.luminance, UInt16(clamping: target * Int(maxV) / 100))
    }
    showStatus()

default:
    usage()
    exit(1)
}
