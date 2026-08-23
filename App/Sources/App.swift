import SwiftUI
import AppKit

@main
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings {} }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: Any?

    private let displays = Displays()
    private lazy var volume = VolumeController(external: displays.external)
    private var mediaKeys: MediaKeys!
    private var trustPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        // Report the status item's screen rect so the HUD can sit beneath it.
        HUD.shared.anchor = { [weak self] in
            guard let button = self?.statusItem.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }

        mediaKeys = MediaKeys { press in
            Task { @MainActor [weak self] in self?.handle(press) }
        }
        mediaKeys.start()

        enableLoginItemOnFirstRun()
        rebuildPanel()
    }

    /// Registers for launch-at-login the first time the app runs, so it is
    /// there after a reboot without the user hunting for the toggle. Only ever
    /// done once; afterwards the switch in the panel (or System Settings) wins.
    private func enableLoginItemOnFirstRun() {
        let key = "didConfigureLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        LoginItem.setEnabled(true)
    }

    /// Bundled template image, falling back to an SF Symbol.
    private static func menuBarIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "slider.horizontal.3",
                       accessibilityDescription: "Display and sound controls")
    }

    private func rebuildPanel() {
        let view = PanelView(
            displays: displays,
            volume: volume,
            mediaKeysActive: mediaKeys.isActive,
            onRequestAccessibility: { [weak self] in self?.promptForAccessibility() },
            onUnlockBrightness: { [weak self] in
                self?.displays.unlockBrightness { [weak self] in self?.rebuildPanel() }
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // The cursor sits over the menu bar while clicking, so sample the
        // display target before the panel opens.
        displays.refresh()
        volume.refresh()
        rebuildPanel()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        displays.reload()
        volume.reload()
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Routes a media key press.
    ///
    /// Brightness keys drive the monitor by default and the built-in panel with
    /// Option held. With no monitor attached there is nothing to invert, so both
    /// forms drive the built-in panel.
    private func handle(_ press: MediaKeys.Press) {
        let step = 1.0 / 16.0
        switch press.key {
        case .brightnessUp, .brightnessDown:
            let delta = press.key == .brightnessUp ? step : -step
            let useBuiltIn = press.optionHeld || !displays.externalAvailable
            if useBuiltIn {
                displays.adjustBuiltInBrightness(by: delta)
            } else {
                displays.adjustExternalBrightness(by: delta)
            }
            HUD.shared.showBrightness(builtIn: useBuiltIn, displays: displays)

        case .volumeUp, .volumeDown:
            volume.adjustVolume(by: press.key == .volumeUp ? step : -step)
            HUD.shared.showVolume(volume)

        case .mute:
            volume.toggleMute()
            HUD.shared.showVolume(volume)
        }
    }

    /// Opens the Accessibility pane and re-arms the tap once permission lands.
    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)

        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        pollForTrust()
    }

    /// Polls until the grant lands, then stops. Replaces any poll already
    /// running, so repeated clicks on the prompt cannot stack timers, and gives
    /// up after two minutes rather than waking the process forever when the
    /// user never grants permission.
    private func pollForTrust() {
        trustPoll?.invalidate()
        let deadline = Date().addingTimeInterval(120)
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            Task { @MainActor in
                guard AXIsProcessTrusted() else {
                    if Date() > deadline { timer.invalidate(); self.trustPoll = nil }
                    return
                }
                timer.invalidate()
                self.trustPoll = nil
                self.mediaKeys.start()
                self.rebuildPanel()
            }
        }
    }
}
