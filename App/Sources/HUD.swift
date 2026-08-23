import SwiftUI
import AppKit

/// Feedback for the function keys, shown because the event tap swallows the
/// presses that would otherwise raise the system HUD.
///
/// Deliberately shaped like the menu bar panel rather than the macOS square:
/// the same glass pill and slider, anchored under the status item so the
/// feedback appears where the app itself lives.
@MainActor
final class HUD {
    static let shared = HUD()

    private var window: NSPanel?
    private var dismiss: Timer?
    private let model = HUDModel()

    /// Set by the app delegate so the pill can line up with the menu bar icon.
    var anchor: (() -> NSRect?)?

    private init() {}

    func showBrightness(builtIn: Bool, displays: Displays) {
        model.update(icon: "sun.max.fill",
                     value: builtIn ? displays.builtInBrightness : displays.externalBrightness,
                     tint: Color(red: 0.98, green: 0.76, blue: 0.35),
                     caption: builtIn ? "Built-in" : displays.externalName)
        present()
    }

    func showVolume(_ volume: VolumeController) {
        model.update(icon: volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                     value: volume.isMuted ? 0 : volume.volume,
                     tint: .glassTint,
                     caption: volume.isMuted ? "Muted" : volume.deviceName)
        present()
    }

    private static let size = NSSize(width: 232, height: 74)

    private func present() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = NSHostingController(rootView: HUDView(model: model))
            window = panel
        }
        guard let window else { return }
        window.setFrame(NSRect(origin: position(), size: Self.size), display: false)
        window.orderFrontRegardless()
        model.visible = true

        dismiss?.invalidate()
        dismiss = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            Task { @MainActor in
                self.model.visible = false
                try? await Task.sleep(for: .milliseconds(260))
                if self.model.visible == false { self.window?.orderOut(nil) }
            }
        }
    }

    /// Sits just below the status item, clamped so it never leaves the screen.
    private func position() -> NSPoint {
        let gap: CGFloat = 8

        if let rect = anchor?(),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            let x = rect.midX - Self.size.width / 2
            let minX = screen.frame.minX + gap
            let maxX = screen.frame.maxX - Self.size.width - gap
            return NSPoint(x: min(max(x, minX), maxX),
                           y: rect.minY - Self.size.height - gap)
        }

        // No status item (rare): fall back to the top-right of the active screen.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(x: frame.maxX - Self.size.width - gap,
                       y: frame.maxY - Self.size.height - gap)
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var icon = "sun.max.fill"
    @Published var value: Double = 0
    @Published var tint: Color = .glassTint
    @Published var caption = ""
    @Published var visible = false

    func update(icon: String, value: Double, tint: Color, caption: String) {
        self.icon = icon
        self.value = value
        self.tint = tint
        self.caption = caption
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(model.caption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.glassSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text("\(Int((model.value * 100).rounded()))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.glassText)
            }
            // The same control as the panel, so the two read as one app.
            GlassSlider(value: model.value, icon: model.icon, tint: model.tint) { _ in }
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 232, height: 74)
        .background(GlassBackground())
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.glassStroke, lineWidth: 0.5)
        )
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1 : 0.97, anchor: .top)
        .offset(y: model.visible ? 0 : -6)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: model.visible)
        .preferredColorScheme(.dark)
    }
}
