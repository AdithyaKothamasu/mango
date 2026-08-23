import Foundation
import AppKit
import CoreGraphics

/// Brightness for both panels, tracked independently.
///
/// Each display keeps its own value so either can be driven at any time,
/// whatever the cursor is doing. The external display may be absent, in which
/// case only the built-in half is live.
@MainActor
final class Displays: ObservableObject {
    @Published private(set) var builtInBrightness: Double = 1
    @Published private(set) var externalBrightness: Double = 1
    @Published private(set) var externalName = "External Display"
    @Published private(set) var externalAvailable = false

    /// Set when the monitor reports a picture mode that locks brightness.
    @Published private(set) var brightnessLocked = false

    let external: ExternalDisplay?

    init() {
        external = ExternalDisplay()
        externalAvailable = external != nil
        externalName = Self.externalScreenName() ?? "External Display"
        external?.refresh([.luminance, .pictureMode, .volume, .mute]) { [weak self] in
            self?.refresh()
        }
        refresh()

        // Track hotplug so the UI disables itself when the monitor goes away.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            }
    }

    private static func externalScreenName() -> String? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(number) == 0
        }?.localizedName
    }

    /// True while a physical external screen is attached and answering DDC.
    private var externalScreenAttached: Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(number) == 0
        }
    }

    private func screensChanged() {
        externalAvailable = external != nil && externalScreenAttached
        if let name = Self.externalScreenName() { externalName = name }
        guard externalAvailable else { refresh(); return }
        external?.refresh([.luminance, .pictureMode]) { [weak self] in self?.refresh() }
    }

    /// Reads from cache only — safe to call on every UI event.
    func refresh() {
        builtInBrightness = Double(BuiltinDisplay.brightness ?? 1)
        externalAvailable = external != nil && externalScreenAttached

        guard externalAvailable, let external else {
            brightnessLocked = false
            return
        }
        if let (current, maxValue) = external.cached(.luminance), maxValue > 0 {
            externalBrightness = Double(current) / Double(maxValue)
        }
        brightnessLocked = PictureMode.locksBrightness(external.cached(.pictureMode)?.current)
    }

    /// Pulls fresh values off the wire, then updates the UI.
    func reload(completion: @escaping @MainActor () -> Void = {}) {
        guard externalAvailable, let external else {
            refresh(); completion(); return
        }
        external.refresh([.luminance, .pictureMode]) { [weak self] in
            self?.refresh()
            completion()
        }
    }

    // MARK: Built-in

    func setBuiltInBrightness(_ value: Double) {
        let clamped = max(0, min(1, value))
        builtInBrightness = clamped
        BuiltinDisplay.setBrightness(Float(clamped))
    }

    func adjustBuiltInBrightness(by delta: Double) {
        // Read back the real value first; the user may have changed it elsewhere.
        if let actual = BuiltinDisplay.brightness { builtInBrightness = Double(actual) }
        setBuiltInBrightness(builtInBrightness + delta)
    }

    // MARK: External

    func setExternalBrightness(_ value: Double) {
        guard externalAvailable else { return }
        let clamped = max(0, min(1, value))
        externalBrightness = clamped
        external?.setFraction(.luminance, clamped)
    }

    func adjustExternalBrightness(by delta: Double) {
        guard externalAvailable else { return }
        setExternalBrightness(externalBrightness + delta)
    }

    /// Switches the monitor to Standard picture mode, which unlocks brightness.
    func unlockBrightness(completion: @escaping @MainActor () -> Void = {}) {
        guard let external else { completion(); return }
        external.set(.pictureMode, PictureMode.standard)
        external.refresh([.pictureMode, .luminance]) { [weak self] in
            self?.refresh()
            completion()
        }
    }
}

/// BenQ picture modes on VCP 0xDC.
///
/// HDR and cinema-style modes drive the backlight themselves: luminance writes
/// are accepted and stored, but the panel ignores them, so brightness appears
/// to flash and snap back. Standard hands control back to VCP 0x10.
enum PictureMode {
    static let standard: UInt16 = 0

    static func locksBrightness(_ value: UInt16?) -> Bool {
        guard let value else { return false }
        return value != standard
    }
}
