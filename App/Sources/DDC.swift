import Foundation
import IOKit
import CoreGraphics

// MARK: - DDC/CI over IOAVService (Apple Silicon)
// Verified against BenQ EW2790U on macOS 26.5 / M3 Pro.

typealias IOAVServiceRef = CFTypeRef

private let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)

private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias RWFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

// Private SPI: resolve optionally so a future macOS that drops these symbols
// disables DDC instead of calling through a null pointer.
private let avCreate = dlsym(coreDisplay, "IOAVServiceCreateWithService")
    .map { unsafeBitCast($0, to: CreateFn.self) }
private let avWrite  = dlsym(coreDisplay, "IOAVServiceWriteI2C")
    .map { unsafeBitCast($0, to: RWFn.self) }
private let avRead   = dlsym(coreDisplay, "IOAVServiceReadI2C")
    .map { unsafeBitCast($0, to: RWFn.self) }

/// Standard VCP feature codes (MCCS spec).
enum VCP: UInt8 {
    case luminance   = 0x10
    case contrast    = 0x12
    case colorPreset = 0x14   // read-only on EW2790U firmware
    case colorTemp   = 0x0C   // read-only on EW2790U firmware
    case inputSource = 0x60
    case volume      = 0x62
    case mute        = 0x8D
    case powerMode   = 0xD6
    /// BenQ picture mode. Some values (HDR/cinema) lock luminance in firmware.
    case pictureMode = 0xDC
}

/// DDC transport for one external display.
///
/// The I2C bus is slow (~75ms/write, ~100ms/read) and tolerates no concurrency,
/// so all traffic runs on one background queue and never blocks the caller.
/// Values are cached and written through, letting the UI stay at display rate
/// while the monitor catches up.
final class ExternalDisplay: @unchecked Sendable {
    private let service: IOAVServiceRef
    private let chip: UInt32 = 0x37
    private let addr: UInt32 = 0x51

    private let bus = DispatchQueue(label: "ddc.bus", qos: .userInitiated)

    /// Last value written or read per feature, so the UI never waits on I2C.
    private var cache: [VCP: (current: UInt16, max: UInt16)] = [:]
    private let cacheLock = NSLock()

    /// Newest pending value per feature; a drag overwrites rather than queues.
    private var pending: [VCP: UInt16] = [:]
    private let pendingLock = NSLock()

    init?() {
        guard let avCreate else { return nil }
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var found: IOAVServiceRef? = nil
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            let location = IORegistryEntrySearchCFProperty(
                svc, kIOServicePlane, "Location" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
            if location == "External", found == nil {
                found = avCreate(kCFAllocatorDefault, svc)?.takeRetainedValue()
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        guard let f = found else { return nil }
        service = f
    }

    // MARK: Cache

    func cached(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[code]
    }

    private func store(_ code: VCP, current: UInt16, max: UInt16) {
        cacheLock.lock(); cache[code] = (current, max); cacheLock.unlock()
    }

    private func updateCachedCurrent(_ code: VCP, _ value: UInt16) {
        cacheLock.lock()
        if let existing = cache[code] { cache[code] = (value, existing.max) }
        cacheLock.unlock()
    }

    // MARK: Blocking primitives (bus queue only)

    private func readSync(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        guard let avWrite, let avRead else { return nil }
        for attempt in 0..<3 {
            var packet = [UInt8](repeating: 0, count: 12)
            packet[0] = 0x82
            packet[1] = 0x01
            packet[2] = code.rawValue
            packet[3] = 0x6E ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3]

            usleep(attempt == 0 ? 12_000 : 30_000)
            guard avWrite(service, chip, addr, &packet, 4) == KERN_SUCCESS else { continue }

            var reply = [UInt8](repeating: 0, count: 12)
            usleep(attempt == 0 ? 25_000 : 50_000)
            guard avRead(service, chip, addr, &reply, 12) == KERN_SUCCESS,
                  reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue
            else { continue }

            let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current  = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (current, maxValue)
        }
        return nil
    }

    private func writeSync(_ code: VCP, _ value: UInt16) {
        guard let avWrite else { return }
        var packet = [UInt8](repeating: 0, count: 12)
        packet[0] = 0x84
        packet[1] = 0x03
        packet[2] = code.rawValue
        packet[3] = UInt8(value >> 8)
        packet[4] = UInt8(value & 0xFF)
        packet[5] = 0x6E ^ 0x51 ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]
        _ = avWrite(service, chip, addr, &packet, 6)
        usleep(12_000) // let the panel latch before the next packet
    }

    // MARK: Async API

    /// Refreshes `codes` in the background, then delivers the cache on the main queue.
    func refresh(_ codes: [VCP], completion: @escaping @MainActor () -> Void = {}) {
        bus.async { [weak self] in
            guard let self else { return }
            for code in codes {
                if let value = self.readSync(code) {
                    self.store(code, current: value.current, max: value.max)
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
        }
    }

    /// Queues a write, keeping only the newest value per feature.
    ///
    /// A drag emits values far faster than the bus drains; coalescing means the
    /// monitor tracks the finger instead of replaying a backlog.
    func set(_ code: VCP, _ value: UInt16) {
        updateCachedCurrent(code, value)

        pendingLock.lock()
        let alreadyQueued = pending[code] != nil
        pending[code] = value
        pendingLock.unlock()
        guard !alreadyQueued else { return }

        bus.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let target = self.pending.removeValue(forKey: code)
            self.pendingLock.unlock()
            guard let target else { return }
            self.writeSync(code, target)
        }
    }

    /// Fractional setter (0...1) using the cached maximum.
    func setFraction(_ code: VCP, _ fraction: Double) {
        guard let maxValue = cached(code)?.max, maxValue > 0 else { return }
        let clamped = max(0, min(1, fraction))
        set(code, UInt16(clamping: Int((clamped * Double(maxValue)).rounded())))
    }

    /// Blocking read for CLI use, where latency does not matter.
    ///
    /// Never call from the bus queue — including from a `refresh` completion
    /// that has hopped back onto it: libdispatch traps on a reentrant `sync`.
    func readBlocking(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        bus.sync {
            let value = readSync(code)
            if let value { store(code, current: value.current, max: value.max) }
            return value
        }
    }

    /// Blocking write for CLI use.
    func writeBlocking(_ code: VCP, _ value: UInt16) {
        bus.sync { writeSync(code, value) }
        updateCachedCurrent(code, value)
    }
}
