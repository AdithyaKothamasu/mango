import Foundation
import CoreAudio
import AudioToolbox

/// A selectable input or output device.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let transport: Transport

    enum Transport {
        case builtIn, displayPort, bluetooth, usb, virtual, aggregate, other

        var symbol: String {
            switch self {
            case .builtIn:     return "laptopcomputer"
            case .displayPort: return "display"
            case .bluetooth:   return "wave.3.right"
            case .usb:         return "cable.connector"
            case .virtual:     return "square.stack.3d.up"
            case .aggregate:   return "rectangle.stack"
            case .other:       return "hifispeaker"
            }
        }
    }
}

/// CoreAudio device enumeration, default-device routing, and volume.
///
/// Not every output exposes a software volume control: DisplayPort monitors
/// (the BenQ included) keep volume in monitor hardware, reachable only over
/// DDC. `outputSupportsSoftwareVolume` reports which path applies.
enum Audio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Enumeration

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func name(of id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<CFTypeRef?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = unmanaged?.takeRetainedValue() else { return "Unknown" }
        return value as String
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return Int(UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels })
    }

    private static func transport(of id: AudioDeviceID) -> AudioDevice.Transport {
        var addr = address(kAudioDevicePropertyTransportType)
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &raw) == noErr else { return .other }
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn:     return .builtIn
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB:         return .usb
        case kAudioDeviceTransportTypeVirtual:     return .virtual
        case kAudioDeviceTransportTypeAggregate:   return .aggregate
        default:                                   return .other
        }
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        allDeviceIDs()
            .filter { channelCount($0, scope: scope) > 0 }
            .map { AudioDevice(id: $0, name: name(of: $0), transport: transport(of: $0)) }
    }

    static var outputs: [AudioDevice] { devices(scope: kAudioDevicePropertyScopeOutput) }
    static var inputs: [AudioDevice]  { devices(scope: kAudioDevicePropertyScopeInput) }

    // MARK: Default routing

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        var addr = address(selector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return AudioDevice(id: id, name: name(of: id), transport: transport(of: id))
    }

    @discardableResult
    private static func setDefaultDevice(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) -> Bool {
        var addr = address(selector)
        var value = id
        return AudioObjectSetPropertyData(system, &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    static var defaultOutput: AudioDevice? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    static var defaultInput: AudioDevice?  { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    /// Moves system output, and system-alert output with it, so alerts follow the music.
    static func selectOutput(_ device: AudioDevice) {
        setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, device.id)
        setDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, device.id)
    }

    static func selectInput(_ device: AudioDevice) {
        setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, device.id)
    }

    // MARK: Volume

    private static func volumeAddress(_ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
    }

    /// True when the active output exposes a software volume slider.
    static var outputSupportsSoftwareVolume: Bool {
        guard let id = defaultOutput?.id else { return false }
        var addr = volumeAddress(kAudioDevicePropertyScopeOutput)
        return AudioObjectHasProperty(id, &addr)
    }

    /// Output volume in 0...1, or nil when the device has no software control.
    static var outputVolume: Float? {
        guard let id = defaultOutput?.id else { return nil }
        var addr = volumeAddress(kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setOutputVolume(_ value: Float) -> Bool {
        guard let id = defaultOutput?.id else { return false }
        var addr = volumeAddress(kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var clamped = Float32(max(0, min(1, value)))
        return AudioObjectSetPropertyData(id, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &clamped) == noErr
    }

    static var isOutputMuted: Bool {
        guard let id = defaultOutput?.id else { return false }
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &muted) == noErr else { return false }
        return muted == 1
    }

    @discardableResult
    static func setOutputMuted(_ muted: Bool) -> Bool {
        guard let id = defaultOutput?.id else { return false }
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Fires `handler` when the default output or input device changes.
    static func observeDefaultChanges(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in handler() }
        }
    }
}
