import Foundation
import AppKit
import CoreGraphics

/// Intercepts the hardware brightness and volume keys.
///
/// macOS delivers these as `NSSystemDefined` subtype 8 events rather than
/// ordinary key codes, so a session event tap is the only way to see them.
/// Handled keys are swallowed to suppress the system HUD; anything else passes
/// through untouched.
@MainActor
final class MediaKeys {
    enum Key {
        case brightnessUp, brightnessDown
        case volumeUp, volumeDown, mute
    }

    /// A key press plus the modifiers held with it.
    struct Press {
        let key: Key
        /// Option inverts the brightness target (monitor <-> built-in).
        let optionHeld: Bool
    }

    // NX_KEYTYPE constants from IOKit's ev_keymap.h.
    private enum Code {
        static let soundUp: Int32 = 0
        static let soundDown: Int32 = 1
        static let mute: Int32 = 7
        static let brightnessUp: Int32 = 2
        static let brightnessDown: Int32 = 3
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private nonisolated let handler: @Sendable (Press) -> Void

    /// The live port, readable from the tap thread.
    ///
    /// macOS disarms the tap from its own callback thread, so re-arming cannot
    /// hop to the main actor first — the port has to be reachable without
    /// touching main-actor state. Written once, before the tap is enabled.
    private nonisolated(unsafe) var tapPort: CFMachPort?

    /// Which key groups to intercept. Read on the tap thread, so they bypass
    /// the actor; a Bool flip racing one key press is harmless. A disabled
    /// group passes straight through to macOS.
    nonisolated(unsafe) var handlesBrightness = true
    nonisolated(unsafe) var handlesVolume = true

    /// Set when the tap is live; false means Accessibility permission is missing.
    private(set) var isActive = false

    init(handler: @escaping @Sendable (Press) -> Void) {
        self.handler = handler
    }

    /// Returns false if Accessibility permission has not been granted yet.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return isActive }

        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let keys = Unmanaged<MediaKeys>.fromOpaque(context).takeUnretainedValue()

                // Re-enable if macOS disarms the tap after a slow callback.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    keys.reenable()
                    return Unmanaged.passUnretained(event)
                }
                return keys.handle(event)
            },
            userInfo: context
        ) else {
            isActive = false
            return false
        }

        self.tap = tap
        tapPort = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        return true
    }

    private nonisolated func reenable() {
        guard let tapPort else { return }
        CGEvent.tapEnable(tap: tapPort, enable: true)
    }

    private nonisolated func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8
        else { return Unmanaged.passUnretained(event) }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyState = ((data & 0x0000_FF00) >> 8)
        let isKeyDown = keyState == 0x0A

        guard isKeyDown else {
            // Swallow the matching key-up so the system HUD stays hidden.
            return mapping(for: keyCode) == nil ? Unmanaged.passUnretained(event) : nil
        }
        guard let key = mapping(for: keyCode) else { return Unmanaged.passUnretained(event) }

        let optionHeld = nsEvent.modifierFlags.contains(.option)
        let press = Press(key: key, optionHeld: optionHeld)
        let deliver = handler
        DispatchQueue.main.async { deliver(press) }
        return nil // consumed
    }

    private nonisolated func mapping(for code: Int32) -> Key? {
        switch code {
        case Code.soundUp:        return handlesVolume ? .volumeUp : nil
        case Code.soundDown:      return handlesVolume ? .volumeDown : nil
        case Code.mute:           return handlesVolume ? .mute : nil
        case Code.brightnessUp:   return handlesBrightness ? .brightnessUp : nil
        case Code.brightnessDown: return handlesBrightness ? .brightnessDown : nil
        default:                  return nil
        }
    }
}

