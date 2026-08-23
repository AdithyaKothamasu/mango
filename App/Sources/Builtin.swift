import Foundation
import CoreGraphics

// MARK: - Built-in Retina display
// CoreDisplay_Display_SetUserBrightness is a no-op on current macOS;
// DisplayServices is the path that actually moves the panel.

private let displayServices = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

enum BuiltinDisplay {
    private static let get = dlsym(displayServices, "DisplayServicesGetBrightness")
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let set = dlsym(displayServices, "DisplayServicesSetBrightness")
        .map { unsafeBitCast($0, to: SetFn.self) }

    static var id: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids[..<Int(count)].first { CGDisplayIsBuiltin($0) == 1 } ?? CGMainDisplayID()
    }

    /// Brightness in 0...1, or nil if the panel doesn't report it.
    static var brightness: Float? {
        guard let get else { return nil }
        var value: Float = 0
        return get(id, &value) == 0 ? value : nil
    }

    @discardableResult
    static func setBrightness(_ value: Float) -> Bool {
        guard let set else { return false }
        return set(id, max(0, min(1, value))) == 0
    }

    @discardableResult
    static func adjustBrightness(by delta: Float) -> Float? {
        guard let current = brightness else { return nil }
        let next = max(0, min(1, current + delta))
        return setBrightness(next) ? next : nil
    }
}
