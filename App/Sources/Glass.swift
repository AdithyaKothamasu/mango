import SwiftUI
import AppKit

/// Tinted-glass surface: a blurred backdrop with a cool tint and a hairline
/// edge, so the panel reads as a pane of glass rather than a flat sheet.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension Color {
    static let glassTint      = Color(red: 0.42, green: 0.55, blue: 0.95)
    static let glassSurface   = Color.white.opacity(0.06)
    static let glassStroke    = Color.white.opacity(0.10)
    static let glassText      = Color.white.opacity(0.92)
    static let glassSecondary = Color.white.opacity(0.45)
}

/// A rounded translucent tile used for grouping controls.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.glassSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                    )
            )
    }
}

/// Continuous slider with a glass track and a soft glow on the filled portion.
struct GlassSlider: View {
    let value: Double
    let icon: String
    var tint: Color = .glassTint
    var enabled: Bool = true
    let onChange: (Double) -> Void

    private let height: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filled = max(height, width * CGFloat(max(0, min(1, value))))

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule()
                    .fill(
                        LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.85)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: filled)
                    .shadow(color: tint.opacity(0.35), radius: 6, y: 1)

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.glassText)
                    .padding(.leading, 10)
            }
            .frame(height: height)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.glassStroke, lineWidth: 0.5))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard enabled else { return }
                        onChange(Double(max(0, min(1, drag.location.x / width))))
                    }
            )
            .opacity(enabled ? 1 : 0.4)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: value)
        }
        .frame(height: height)
    }
}

/// Compact popup menu for picking an audio device.
struct DevicePicker: View {
    let icon: String
    let title: String
    let devices: [AudioDevice]
    let selection: AudioDevice?
    let onSelect: (AudioDevice) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.glassSecondary)
                .frame(width: 14)

            Menu {
                ForEach(devices) { device in
                    Button {
                        onSelect(device)
                    } label: {
                        if device.id == selection?.id {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection?.name ?? "—")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.glassText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.glassSecondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(title)
        }
    }
}
