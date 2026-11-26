import Foundation
import AppKit
import CoreGraphics

/// One-finger volume control along the right edge of the trackpad.
///
/// A single finger that lands in the right-hand strip and rests there briefly
/// becomes a volume gesture: a haptic tick confirms it, then sliding up is
/// louder and down is quieter. The cursor is frozen for the duration so the
/// swipe does not also drag it.
///
/// The hold is what separates it from ordinary pointing. A cursor move that
/// starts at the edge lands and moves almost at once; resting still first is
/// deliberate. Any movement before the hold completes hands the touch back as
/// a normal cursor move.
///
/// One-finger movement never produces scroll events — macOS turns it straight
/// into cursor motion — so the raw contact positions come from the private
/// MultitouchSupport framework, the same source gesture utilities use. It is
/// loaded with `dlopen` rather than linked, so a future macOS that drops or
/// changes it simply leaves the feature inert instead of stopping the app from
/// launching.
@MainActor
final class TrackpadVolume {
    /// Right-hand strip, as a fraction of the trackpad width, where a touch can arm.
    private static let edge: Float = 0.92
    /// How long the finger has to rest before the swipe arms.
    private static let hold: TimeInterval = 0.35
    /// Movement (normalised trackpad units) allowed during the hold. Covers
    /// the tremor of a resting finger; anything more is a cursor move.
    private static let stillness: Float = 0.02
    /// Volume change per unit of trackpad height: ~80% of the pad is full range.
    private static let sensitivity: Double = 1.25
    /// Smallest change worth sending to the device (DDC writes are not free).
    private static let minimumStep: Double = 0.01

    private let volume: VolumeController
    private let multitouch = Multitouch.load()
    private var running = false

    private enum Phase {
        case idle
        /// Resting in the edge strip; arms if it stays still for `hold`.
        case holding(id: Int32, device: UInt, startX: Float, startY: Float, lastY: Float,
                     cursor: CGPoint)
        /// Committed to a volume gesture.
        case engaged(id: Int32, lastY: Float, cursor: CGPoint, pending: Double)
        /// Not ours (started elsewhere, moved sideways, or extra fingers);
        /// ignored until every finger lifts.
        case rejected
    }
    private var phase = Phase.idle {
        didSet { if case .holding = phase {} else { holdTimer?.cancel(); holdTimer = nil } }
    }
    private var holdTimer: DispatchWorkItem?

    init(volume: VolumeController) {
        self.volume = volume

        // Multitouch devices are torn down across sleep and their callbacks go
        // quiet; re-register on wake. This also picks up a Magic Trackpad that
        // connected while the machine was asleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.stop()
                    self.start()
                }
            }
    }

    /// False when MultitouchSupport could not be loaded on this system.
    var isAvailable: Bool { multitouch != nil }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
        // Retried on every call, so it arms once Accessibility is granted.
        if enabled, running { CursorLock.shared.install() }
    }

    private func start() {
        guard !running, let multitouch else { return }
        Multitouch.sink = { [weak self] touches in
            CursorLock.touchSeen()
            DispatchQueue.main.async { self?.process(touches) }
        }
        multitouch.start()
        CursorLock.shared.install()
        running = true
    }

    private func stop() {
        guard running else { return }
        multitouch?.stop()
        Multitouch.sink = nil
        running = false
        finish()
        CursorLock.shared.uninstall()
    }

    // MARK: Gesture

    private func process(_ touches: [Multitouch.Contact]) {
        guard running else { return }
        let down = touches.filter(\.isDown)

        guard !down.isEmpty else { finish(); return }
        guard down.count == 1 else {
            if case .engaged = phase { releaseCursor() }
            phase = .rejected
            return
        }
        let touch = down[0]

        switch phase {
        case .idle:
            guard touch.x >= Self.edge else { phase = .rejected; return }
            phase = .holding(id: touch.id, device: touch.device, startX: touch.x,
                             startY: touch.y, lastY: touch.y, cursor: Self.cursorLocation())
            // A timer rather than frame timestamps: a perfectly still finger
            // is not guaranteed to keep producing frames.
            let timer = DispatchWorkItem { [weak self] in self?.holdElapsed() }
            holdTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: timer)

        case let .holding(id, device, startX, startY, _, cursor):
            guard touch.id == id else { phase = .rejected; return }
            let dx = touch.x - startX, dy = touch.y - startY
            if dx * dx + dy * dy > Self.stillness * Self.stillness {
                phase = .rejected // moved before arming: ordinary pointing
            } else {
                phase = .holding(id: id, device: device, startX: startX, startY: startY,
                                 lastY: touch.y, cursor: cursor)
            }

        case let .engaged(id, lastY, cursor, pending):
            guard touch.id == id else { finish(); phase = .rejected; return }
            let delta = Double(touch.y - lastY) * Self.sensitivity
            phase = .engaged(id: id, lastY: touch.y, cursor: cursor, pending: pending + delta)
            flush()

        case .rejected:
            break
        }
    }

    /// The finger rested long enough: arm the swipe.
    private func holdElapsed() {
        guard case let .holding(id, device, _, _, lastY, cursor) = phase else { return }
        freezeCursor(at: cursor)
        volume.refresh() // pick up changes made elsewhere since last time
        multitouch?.click(device: device)
        phase = .engaged(id: id, lastY: lastY, cursor: cursor, pending: 0)
    }

    /// Sends the accumulated change once it is big enough to matter.
    private func flush() {
        guard case let .engaged(id, lastY, cursor, pending) = phase,
              abs(pending) >= Self.minimumStep else { return }
        phase = .engaged(id: id, lastY: lastY, cursor: cursor, pending: 0)
        guard volume.controllable else { return }
        volume.adjustVolume(by: pending)
        HUD.shared.showVolume(volume)
    }

    private func finish() {
        if case .engaged = phase { releaseCursor() }
        phase = .idle
    }

    // MARK: Cursor

    private var frozenCursor: CGPoint?

    /// Current cursor position in CoreGraphics' top-left global coordinates —
    /// the space `CGWarpMouseCursorPosition` expects. (`NSEvent.mouseLocation`
    /// is bottom-left and would land on the wrong screen.)
    private static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func freezeCursor(at point: CGPoint) {
        frozenCursor = point
        CursorLock.locked = true
        // Undo the few points it drifted while the touch was still deciding.
        CGWarpMouseCursorPosition(point)
    }

    private func releaseCursor() {
        CursorLock.locked = false
        if let frozenCursor { CGWarpMouseCursorPosition(frozenCursor) }
        frozenCursor = nil
    }
}

// MARK: - MultitouchSupport bridge

/// Thin, dynamically loaded wrapper over the private MultitouchSupport API.
private final class Multitouch {
    struct Contact: Sendable {
        /// The surface it came from, so feedback goes to the pad being touched.
        let device: UInt
        let id: Int32
        let state: Int32
        /// Normalised 0...1, origin at the bottom-left of the pad.
        let x: Float
        let y: Float

        /// MTTouchState: 3 = making contact, 4 = touching.
        var isDown: Bool { state == 3 || state == 4 }
    }

    // Layout of MTTouch as reverse-engineered by the community (96 bytes).
    private struct Point { var x: Float; var y: Float }
    private struct Vector { var position: Point; var velocity: Point }
    private struct Touch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var fingerID: Int32
        var handID: Int32
        var normalized: Vector
        var total: Float
        var unknown1: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var absolute: Vector
        var unknown2: Int32
        var unknown3: Int32
        var density: Float
    }

    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                         Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback?) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias GetDeviceID = @convention(c) (UnsafeMutableRawPointer?,
                                                    UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuator = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorCall = @convention(c) (CFTypeRef) -> Int32
    private typealias Actuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    /// The trackpad's haptic engine, driven directly.
    ///
    /// `NSHapticFeedbackManager` only reaches the trackpad while this app is
    /// frontmost, which a menu bar app almost never is, and its patterns are
    /// faint. The actuator API works from the background and has firmer
    /// clicks. Missing symbols just mean no click; the gesture still works.
    private struct Haptics {
        let getDeviceID: GetDeviceID
        let create: CreateActuator
        let open: ActuatorCall
        let close: ActuatorCall
        let actuate: Actuate
    }
    private var haptics: Haptics?
    private var actuators: [UInt: CFTypeRef] = [:]

    /// Receives each frame's contacts on the framework's own thread. The C
    /// callback carries no context pointer, so this has to be global.
    nonisolated(unsafe) static var sink: (@Sendable ([Contact]) -> Void)?

    private let createList: CreateList
    private let register: Register
    private let unregister: Register
    private let startDevice: Start
    private let stopDevice: Stop
    private var devices: CFArray?

    private init(createList: CreateList, register: Register, unregister: Register,
                 start: Start, stop: Stop) {
        self.createList = createList
        self.register = register
        self.unregister = unregister
        self.startDevice = start
        self.stopDevice = stop
    }

    static func load() -> Multitouch? {
        // A layout mismatch would mean reading garbage; refuse rather than guess.
        guard MemoryLayout<Touch>.stride == 96 else { return nil }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let createList = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop")
        else { return nil }
        let multitouch = Multitouch(
            createList: unsafeBitCast(createList, to: CreateList.self),
            register: unsafeBitCast(register, to: Register.self),
            unregister: unsafeBitCast(unregister, to: Register.self),
            start: unsafeBitCast(start, to: Start.self),
            stop: unsafeBitCast(stop, to: Stop.self))
        if let getID = dlsym(handle, "MTDeviceGetDeviceID"),
           let create = dlsym(handle, "MTActuatorCreateFromDeviceID"),
           let open = dlsym(handle, "MTActuatorOpen"),
           let close = dlsym(handle, "MTActuatorClose"),
           let actuate = dlsym(handle, "MTActuatorActuate") {
            multitouch.haptics = Haptics(
                getDeviceID: unsafeBitCast(getID, to: GetDeviceID.self),
                create: unsafeBitCast(create, to: CreateActuator.self),
                open: unsafeBitCast(open, to: ActuatorCall.self),
                close: unsafeBitCast(close, to: ActuatorCall.self),
                actuate: unsafeBitCast(actuate, to: Actuate.self))
        }
        return multitouch
    }

    private static let callback: Callback = { device, touches, count, _, _ in
        guard let sink = Multitouch.sink else { return 0 }
        var contacts: [Contact] = []
        if let touches, count > 0 {
            let buffer = UnsafeBufferPointer(
                start: touches.assumingMemoryBound(to: Touch.self), count: Int(count))
            contacts = buffer.map {
                Contact(device: UInt(bitPattern: device), id: $0.identifier, state: $0.state,
                        x: $0.normalized.position.x, y: $0.normalized.position.y)
            }
        }
        sink(contacts)
        return 0
    }

    /// Every multitouch surface: the built-in trackpad and any Magic Trackpad.
    private func eachDevice(_ body: (UnsafeMutableRawPointer) -> Void) {
        guard let devices else { return }
        for index in 0..<CFArrayGetCount(devices) {
            if let device = CFArrayGetValueAtIndex(devices, index) {
                body(UnsafeMutableRawPointer(mutating: device))
            }
        }
    }

    func start() {
        devices = createList()?.takeRetainedValue()
        eachDevice { device in
            register(device, Self.callback)
            startDevice(device, 0)
            openActuator(for: device)
        }
    }

    private func openActuator(for device: UnsafeMutableRawPointer) {
        guard let haptics else { return }
        var id: UInt64 = 0
        guard haptics.getDeviceID(device, &id) == 0,
              let actuator = haptics.create(id)?.takeRetainedValue(),
              haptics.open(actuator) == 0 else { return }
        actuators[UInt(bitPattern: device)] = actuator
    }

    /// Fires one click on the given surface. Pattern 6 is the firmest of the
    /// short clicks; lower numbers are progressively lighter.
    func click(device: UInt, pattern: Int32 = 6) {
        guard let haptics, let actuator = actuators[device] else { return }
        _ = haptics.actuate(actuator, pattern, 0, 0, 0)
    }

    func stop() {
        if let haptics {
            for actuator in actuators.values { _ = haptics.close(actuator) }
        }
        actuators = [:]
        eachDevice { device in
            unregister(device, Self.callback)
            stopDevice(device)
        }
        devices = nil
    }
}

// MARK: - Cursor lock

/// Holds the pointer still during a swipe by dropping mouse-move events before
/// the window server applies them.
///
/// `CGAssociateMouseAndMouseCursorPosition` only works for the frontmost app,
/// and a session-level tap sees events after the pointer has already moved, so
/// this sits at the HID level, the one point where dropping a move actually
/// stops it. Needs the same Accessibility grant as the media keys.
private final class CursorLock {
    nonisolated(unsafe) static let shared = CursorLock()

    /// Set on the main actor, read on the tap thread; a stale read costs one
    /// event at most.
    nonisolated(unsafe) static var locked = false

    /// When the last multitouch frame arrived. If frames stop (sleep, the
    /// device vanishing) the lock lapses on its own instead of pinning the
    /// pointer until the next touch.
    nonisolated(unsafe) private static var lastTouch: CFAbsoluteTime = 0
    private static let lapse: CFAbsoluteTime = 0.25

    static func touchSeen() { lastTouch = CFAbsoluteTimeGetCurrent() }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = CursorLock.shared.tap { CGEvent.tapEnable(tap: port, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let fresh = CFAbsoluteTimeGetCurrent() - CursorLock.lastTouch < CursorLock.lapse
                return CursorLock.locked && fresh ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil)
        else { return } // no Accessibility yet: the swipe still works, the pointer just drifts
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func uninstall() {
        CursorLock.locked = false
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }
}
