import Foundation

/// The two top-level features, each switchable from the panel.
///
/// - **Monitor control:** the brightness sliders and the F1/F2 keys.
/// - **Volume control:** the right-edge trackpad swipe, the volume slider and
///   the volume/mute keys.
///
/// Turning one off hands its keys back to macOS untouched rather than just
/// hiding the UI. Both choices persist across launches.
@MainActor
final class Features: ObservableObject {
    @Published var monitorControl: Bool {
        didSet { save(monitorControl, Keys.monitor) }
    }
    @Published var volumeControl: Bool {
        didSet { save(volumeControl, Keys.volume) }
    }

    /// Called after either switch changes, so the app can re-arm its inputs.
    var onChange: (() -> Void)?

    private enum Keys {
        static let monitor = "feature.monitorControl"
        static let volume = "feature.volumeControl"
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.monitor: true, Keys.volume: true])
        monitorControl = defaults.bool(forKey: Keys.monitor)
        volumeControl = defaults.bool(forKey: Keys.volume)
    }

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }
}
