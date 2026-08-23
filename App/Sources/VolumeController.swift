import Foundation
import AppKit

/// Volume for whichever output is currently active.
///
/// Two hardware paths hide behind one slider. Most devices expose a CoreAudio
/// software volume. DisplayPort/HDMI monitors do not — their volume lives in
/// the panel and is only reachable over DDC. The active output decides which
/// path a change takes, so the control means the same thing either way.
@MainActor
final class VolumeController: ObservableObject {
    @Published private(set) var volume: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var deviceName = "—"
    @Published private(set) var controllable = true

    private let external: ExternalDisplay?

    init(external: ExternalDisplay?) {
        self.external = external
        external?.refresh([.volume, .mute]) { [weak self] in self?.refresh() }
        refresh()
        Audio.observeDefaultChanges { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    /// True when audio is riding the monitor's DisplayPort link.
    private var routesThroughMonitor: Bool {
        guard let output = Audio.defaultOutput else { return false }
        return output.transport == .displayPort && !Audio.outputSupportsSoftwareVolume
    }

    func refresh() {
        deviceName = Audio.defaultOutput?.name ?? "—"

        if routesThroughMonitor {
            if let external, let (current, maxValue) = external.cached(.volume), maxValue > 0 {
                volume = Double(current) / Double(maxValue)
                isMuted = external.cached(.mute)?.current == 1
                controllable = true
            } else {
                // No DDC answer yet: drop the stale reading rather than label a
                // silent output "Muted" from the previous device's state.
                isMuted = false
                controllable = false
            }
        } else if let level = Audio.outputVolume {
            volume = Double(level)
            isMuted = Audio.isOutputMuted
            controllable = true
        } else {
            isMuted = false
            controllable = false
        }
    }

    func setVolume(_ value: Double) {
        let clamped = max(0, min(1, value))
        volume = clamped

        if routesThroughMonitor {
            external?.setFraction(.volume, clamped)
        } else {
            Audio.setOutputVolume(Float(clamped))
        }
        if isMuted, clamped > 0 { setMuted(false) }
    }

    func adjustVolume(by delta: Double) {
        setVolume(volume + delta)
    }

    /// Re-reads from hardware; used when the output device changes.
    func reload() {
        deviceName = Audio.defaultOutput?.name ?? "—"
        if routesThroughMonitor, let external {
            external.refresh([.volume, .mute]) { [weak self] in self?.refresh() }
        } else {
            refresh()
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if routesThroughMonitor {
            external?.set(.mute, muted ? 1 : 2)
        } else {
            Audio.setOutputMuted(muted)
        }
    }

    func toggleMute() { setMuted(!isMuted) }
}
