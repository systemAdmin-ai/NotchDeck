import Foundation
import CoreAudio
import CoreGraphics
import AppKit

// MARK: - Яркость (приватный DisplayServices)
typealias DSGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DSSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias DSGetIncrementFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DSCanChangeFn = @convention(c) (CGDirectDisplayID) -> Int32

final class Brightness {
    static let shared = Brightness()
    private let handle: UnsafeMutableRawPointer?
    private let getFn: DSGetBrightnessFn?
    private let setFn: DSSetBrightnessFn?
    private let incFn: DSGetIncrementFn?

    var display: CGDirectDisplayID = CGMainDisplayID()

    private init() {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        if let h = handle {
            getFn = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: DSGetBrightnessFn.self) }
            setFn = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: DSSetBrightnessFn.self) }
            incFn = dlsym(h, "DisplayServicesGetBrightnessIncrement").map { unsafeBitCast($0, to: DSGetIncrementFn.self) }
        } else {
            getFn = nil; setFn = nil; incFn = nil
        }
    }

    var available: Bool { getFn != nil && setFn != nil }

    func current() -> Float? {
        guard let getFn else { return nil }
        var v: Float = 0
        return getFn(display, &v) == 0 ? v : nil
    }

    func increment() -> Float {
        guard let incFn else { return 1.0 / 16.0 }
        var v: Float = 0
        if incFn(display, &v) == 0, v > 0.001, v <= 0.5 { return v }
        return 1.0 / 16.0
    }

    @discardableResult
    func set(_ value: Float) -> Bool {
        guard let setFn else { return false }
        let clamped = max(0, min(1, value))
        return setFn(display, clamped) == 0
    }

    @discardableResult
    func step(_ direction: Int) -> Float? {
        guard let cur = current() else { return nil }
        let next = max(0, min(1, cur + Float(direction) * increment()))
        set(next)
        return next
    }
}

// MARK: - Звук (CoreAudio HAL)
// Внимание: у встроенных динамиков громкость живёт на мастер-элементе 0, у части
// устройств (HDMI, агрегаты) — на каналах 1/2. Пишем во все элементы, где свойство есть.
final class Volume {
    static let shared = Volume()
    private var device: AudioDeviceID = 0

    private init() { refreshDevice() }

    private func refreshDevice() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr {
            device = dev
        }
    }

    private func scalarAddress(_ el: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: el)
    }

    private func muteAddress(_ el: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: el)
    }

    private var candidateElements: [UInt32] { [0, 1, 2] }

    private func volumeElements() -> [UInt32] {
        refreshDevice()
        guard device != 0 else { return [] }
        return candidateElements.filter { el in
            var a = scalarAddress(el)
            return AudioObjectHasProperty(device, &a)
        }
    }

    private func muteElements() -> [UInt32] {
        refreshDevice()
        guard device != 0 else { return [] }
        return candidateElements.filter { el in
            var a = muteAddress(el)
            return AudioObjectHasProperty(device, &a)
        }
    }

    func current() -> Float? {
        for el in volumeElements() {
            var a = scalarAddress(el)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.stride)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    var canSetVolume: Bool {
        volumeElements().contains { el in
            var address = scalarAddress(el)
            var settable = DarwinBoolean(false)
            return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }
    }

    @discardableResult
    func set(_ value: Float) -> Bool {
        let clamped = max(0, min(1, value))
        var ok = false
        for el in volumeElements() {
            var a = scalarAddress(el)
            var v = clamped
            if AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.stride), &v) == noErr {
                ok = true
            }
        }
        return ok
    }

    func isMuted() -> Bool {
        for el in muteElements() {
            var a = muteAddress(el)
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.stride)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &muted) == noErr { return muted != 0 }
        }
        return false
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        var ok = false
        for el in muteElements() {
            var a = muteAddress(el)
            var next: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.stride), &next) == noErr {
                ok = true
            }
        }
        return ok
    }

    @discardableResult
    func toggleMute() -> Bool { setMuted(!isMuted()) }

    @discardableResult
    func step(_ direction: Int) -> Float? {
        guard let cur = current() else { return nil }
        let next = max(0, min(1, cur + Float(direction) * (1.0 / 16.0)))
        set(next)
        return next
    }

    /// Слушатель изменений громкости/mute (для HUD).
    func addListener(_ callback: @escaping () -> Void) {
        refreshDevice()
        guard device != 0 else { return }
        VolumeBox.shared.onChange = callback
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(VolumeBox.shared).toOpaque())
        for el in volumeElements() {
            var a = scalarAddress(el)
            AudioObjectAddPropertyListener(device, &a, volumeListenerProc, refcon)
        }
        for el in muteElements() {
            var a = muteAddress(el)
            AudioObjectAddPropertyListener(device, &a, volumeListenerProc, refcon)
        }
        var def = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &def, volumeListenerProc, refcon)
    }
}

final class VolumeBox {
    static let shared = VolumeBox()
    var onChange: (() -> Void)?
}

private func volumeListenerProc(_ objID: AudioObjectID, _ numAddresses: UInt32,
                                _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                                _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    if let cb = VolumeBox.shared.onChange {
        DispatchQueue.main.async { cb() }
    }
    return noErr
}

// MARK: - Медиа (MediaRemote)
final class Media {
    static let shared = Media()
    private let send: (@convention(c) (UInt32, CFDictionary?) -> Bool)?

    enum Command: UInt32 {
        case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
    }

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        if let h = dlopen(path, RTLD_NOW), let sym = dlsym(h, "MRMediaRemoteSendCommand") {
            send = unsafeBitCast(sym, to: (@convention(c) (UInt32, CFDictionary?) -> Bool).self)
        } else {
            send = nil
        }
    }

    var available: Bool { send != nil }

    @discardableResult
    func perform(_ cmd: Command) -> Bool {
        guard let send else { return false }
        return send(cmd.rawValue, nil)
    }
}

// MARK: - Питание
enum Power {
    static func sleepDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    static func lockScreen() {
        // приватный login.framework знает про блокировку; если нет — Ctrl+Cmd+Q через System Events
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_NOW),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            let fn = unsafeBitCast(sym, to: LockFn.self)
            _ = fn()
            return
        }
        let script = "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
