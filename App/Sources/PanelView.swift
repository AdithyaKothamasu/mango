import SwiftUI

struct PanelView: View {
    @ObservedObject var displays: Displays
    @ObservedObject var volume: VolumeController
    let mediaKeysActive: Bool
    let onRequestAccessibility: () -> Void
    let onUnlockBrightness: () -> Void

    @State private var outputs: [AudioDevice] = []
    @State private var inputs: [AudioDevice] = []
    @State private var currentOutput: AudioDevice?
    @State private var currentInput: AudioDevice?
    @State private var launchAtLogin = LoginItem.isEnabled

    private let amber = Color(red: 0.98, green: 0.76, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            brightnessCard
            volumeCard
            devicesCard

            if !mediaKeysActive {
                Button(action: onRequestAccessibility) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("Enable function keys…")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            footer
        }
        .padding(14)
        .frame(width: 288)
        .background(GlassBackground())
        .background(Color.black.opacity(0.28))
        .preferredColorScheme(.dark)
        .onAppear {
            reloadDevices()
            launchAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: Brightness

    private var brightnessCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    rowLabel("Monitor",
                             detail: displays.externalAvailable ? displays.externalName : "Not connected",
                             value: displays.externalBrightness,
                             showValue: displays.externalAvailable)
                    GlassSlider(value: displays.externalBrightness,
                                icon: "sun.max.fill",
                                tint: amber,
                                enabled: displays.externalAvailable) {
                        displays.setExternalBrightness($0)
                    }
                    if displays.externalAvailable, displays.brightnessLocked {
                        Button(action: onUnlockBrightness) {
                            HStack(spacing: 5) {
                                Image(systemName: "lock.fill").font(.system(size: 9))
                                Text("Picture mode locks brightness · Unlock")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.orange.opacity(0.95))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider().overlay(Color.glassStroke)

                VStack(alignment: .leading, spacing: 8) {
                    rowLabel("Built-in", detail: "MacBook Display",
                             value: displays.builtInBrightness, showValue: true)
                    GlassSlider(value: displays.builtInBrightness,
                                icon: "sun.max.fill",
                                tint: amber) {
                        displays.setBuiltInBrightness($0)
                    }
                }
            }
        }
    }

    // MARK: Volume

    private var volumeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                rowLabel(volume.isMuted ? "Volume · Muted" : "Volume",
                         detail: volume.deviceName,
                         value: volume.volume,
                         showValue: volume.controllable)
                HStack(spacing: 8) {
                    GlassSlider(value: volume.isMuted ? 0 : volume.volume,
                                icon: volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                enabled: volume.controllable) {
                        volume.setVolume($0)
                    }
                    Button {
                        volume.toggleMute()
                    } label: {
                        Image(systemName: volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(volume.isMuted ? Color.orange : Color.glassSecondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.glassSurface)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!volume.controllable)
                }
                if !volume.controllable {
                    Text("This output has no adjustable volume.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.glassSecondary)
                }
            }
        }
    }

    // MARK: Devices

    private var devicesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                DevicePicker(icon: "speaker.wave.2", title: "Output",
                             devices: outputs, selection: currentOutput) { device in
                    Audio.selectOutput(device)
                    reloadDevices()
                    volume.reload()
                }
                Divider().overlay(Color.glassStroke)
                DevicePicker(icon: "mic", title: "Input",
                             devices: inputs, selection: currentInput) { device in
                    Audio.selectInput(device)
                    reloadDevices()
                }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(
                    LinearGradient(colors: [Color(red: 0.96, green: 0.34, blue: 0.29),
                                            Color(red: 0.98, green: 0.77, blue: 0.24)],
                                   startPoint: .topTrailing, endPoint: .bottomLeading))
            Text("Mango")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.glassText)
            Spacer()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $launchAtLogin) {
                Text("Open at login")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.glassText)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Color.glassTint)
            .onChange(of: launchAtLogin) { _, enabled in
                if !LoginItem.setEnabled(enabled) {
                    // Registration can be refused if the user blocked the app
                    // in System Settings; reflect the real state back.
                    launchAtLogin = LoginItem.isEnabled
                }
            }

            HStack {
                Text(displays.externalAvailable
                     ? "F1/F2 monitor · ⌥ built-in"
                     : "No monitor · F1/F2 built-in")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.glassSecondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.glassSecondary)
            }
        }
    }

    private func rowLabel(_ title: String, detail: String,
                          value: Double, showValue: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.glassText)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Color.glassSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if showValue {
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.glassSecondary)
            }
        }
    }

    private func reloadDevices() {
        outputs = Audio.outputs
        inputs = Audio.inputs
        currentOutput = Audio.defaultOutput
        currentInput = Audio.defaultInput
    }
}
