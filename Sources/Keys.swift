import AppKit
import ApplicationServices

// MARK: - Перехват клавиш яркости и громкости
//
// Системный OSD показывается самим macOS в ответ на NX_SYSDEFINED. Чтобы показать свой компактный
// индикатор вместо системного, событие нужно перехватить (CGEventTap) и не пропустить дальше,
// а изменение применить самому — через DisplayServices (яркость) и CoreAudio (громкость).
// Для этого нужен доступ в «Универсальный доступ» (Accessibility); без него tap не создаётся,
// и тогда работает запасной путь: опрос значений и своя плашка (системный индикатор остаётся).

enum LevelKind { case brightness, volume }

final class MediaKeyTap {
    static let shared = MediaKeyTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var active = false

    var onChange: ((LevelKind, Float, Bool) -> Void)?   // kind, значение 0…1, приглушено

    // NX_KEYTYPE_*
    private let keySoundUp = 0
    private let keySoundDown = 1
    private let keyBrightnessUp = 2
    private let keyBrightnessDown = 3
    private let keyMute = 7

    var enabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "NotchDeck.mediaKeys") == nil || d.bool(forKey: "NotchDeck.mediaKeys")
    }

    private var retryTimer: Timer?
    private var ownedKeys = Set<Int>()
    private var replacementForTest: ((Int, Bool) -> Bool)?
    var canReplace: () -> Bool = { Preferences.shared.bool("hudEnabled") && !NotchHUD.shared.panelExpanded }

    /// A filtering tap owns a key only after applying its change successfully.
    @discardableResult
    func start() -> Bool {
        if active { return true }
        guard enabled, AXIsProcessTrusted() else {
            scheduleRetry()
            return false
        }
        let mask = CGEventMask(1) << 14
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
                let owner = MediaKeyTap.shared
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return MediaKeyTap.handle(event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: nil) else {
            scheduleRetry()
            Dbg.log("keys: cannot create filtering tap; macOS retains keys")
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        active = true
        retryTimer?.invalidate()
        retryTimer = nil
        Dbg.log("keys: replacement tap active; system OSD suppressed for handled keys")
        return true
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in _ = self?.start() }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        active = false
        ownedKeys.removeAll()
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// true — событие наше, дальше не пускаем (системный OSD не появится).
    private static func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return false
        }
        let key = Int((ns.data1 >> 16) & 0xFFFF)
        let state = (ns.data1 >> 8) & 0xFF
        if state == 0x0B { return shared.ownedKeys.remove(key) != nil }
        guard state == 0x0A, [0, 1, 2, 3, 7].contains(key),
              shared.enabled, shared.onChange != nil, shared.canReplace(),
              !ns.modifierFlags.contains(.control), !ns.modifierFlags.contains(.command) else { return false }
        if ns.modifierFlags.contains(.option), !ns.modifierFlags.contains(.shift) { return false }
        // Repeated mute downs must not toggle back and forth while the key is held.
        if key == 7, shared.ownedKeys.contains(key) { return true }
        let fine = ns.modifierFlags.contains([.option, .shift])
        guard shared.replace(keyCode: key, fine: fine) else { return false }
        shared.ownedKeys.insert(key)
        return true
    }

    @discardableResult
    private func replace(keyCode: Int, fine: Bool) -> Bool {
        if let replacementForTest { return replacementForTest(keyCode, fine) }
        switch keyCode {
        case keyBrightnessUp, keyBrightnessDown:
            guard let current = Brightness.shared.current() else { return false }
            let amount = Brightness.shared.increment() / (fine ? 4 : 1)
            let next = max(0, min(1, current + (keyCode == keyBrightnessUp ? amount : -amount)))
            guard Brightness.shared.set(next) else { return false }
            let actual = Brightness.shared.current() ?? next
            LevelWatch.shared.synchronize()
            onChange?(.brightness, actual, false)
        case keySoundUp, keySoundDown:
            guard Volume.shared.canSetVolume, let current = Volume.shared.current() else { return false }
            let amount: Float = fine ? 1/64 : 1/16
            let next = max(0, min(1, current + (keyCode == keySoundUp ? amount : -amount)))
            guard Volume.shared.set(next) else { return false }
            if Volume.shared.isMuted() { _ = Volume.shared.setMuted(false) }
            let actual = Volume.shared.current() ?? next
            LevelWatch.shared.synchronize()
            onChange?(.volume, actual, Volume.shared.isMuted())
        case keyMute:
            guard let actual = Volume.shared.current(), Volume.shared.toggleMute() else { return false }
            LevelWatch.shared.synchronize()
            onChange?(.volume, actual, Volume.shared.isMuted())
        default: return false
        }
        Dbg.log("keys: consumed key=\(keyCode), applied exactly once")
        return true
    }

    static func testRouting() {
        let owner = shared
        var writes: [(Int, Bool)] = []
        var succeeds = true
        owner.onChange = { _, _, _ in }
        owner.canReplace = { true }
        owner.replacementForTest = { key, fine in writes.append((key, fine)); return succeeds }
        func check(_ value: Bool, _ label: String) {
            if !value { fputs("KEY ROUTING FAIL: \(label)\n", stderr); exit(1) }
        }
        func event(_ key: Int, _ down: Bool, flags: NSEvent.ModifierFlags = []) -> Bool {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (key << 16) | ((down ? 0x0A : 0x0B) << 8), data2: -1)!
            return handle(event.cgEvent!)
        }
        check(!event(16, true), "unrelated key consumed")
        check(writes.isEmpty, "unrelated key wrote")
        check(event(0, true) && event(0, false), "volume down/up not consumed together")
        check(writes.count == 1, "key-up writes twice")
        for _ in 0..<8 { check(event(2, true), "repeat not consumed") }
        check(event(2, false) && writes.count == 9, "repeat count")
        check(event(7, true) && event(7, true) && event(7, false), "mute route")
        check(writes.count == 10, "held mute toggles twice")
        check(event(1, true, flags: [.option, .shift]) && event(1, false), "fine route")
        check(writes.last?.1 == true, "fine step lost")
        succeeds = false
        check(!event(3, true) && !event(3, false), "failed write swallows native fallback")
        let count = writes.count
        owner.canReplace = { false }
        check(!event(0, true) && writes.count == count, "hidden HUD consumes key")
        owner.replacementForTest = nil
        owner.onChange = nil
        owner.canReplace = { Preferences.shared.bool("hudEnabled") && !NotchHUD.shared.panelExpanded }
        owner.ownedKeys.removeAll()
        print("KEY ROUTING PASS: filtering, exactly once, repeats, mute, fine step, failed-write fallback, hidden HUD")
    }

    /// Диагностический путь: только читает уже установленный системой уровень.
    /// Физические клавиши идут штатным путём macOS; HUD появляется через LevelWatch.
    func apply(keyCode: Int) {
        switch keyCode {
        case keyBrightnessUp, keyBrightnessDown:
            guard let v = Brightness.shared.current() else { return }
            onChange?(.brightness, v, false)
            Dbg.log(String(format: "keys: наблюдение после системной обработки, яркость %.0f %%", v * 100))
        case keySoundUp, keySoundDown, keyMute:
            guard let v = Volume.shared.current() else { return }
            onChange?(.volume, v, Volume.shared.isMuted())
            Dbg.log(String(format: "keys: наблюдение после системной обработки, громкость %.0f %%", v * 100))
        default:
            return
        }
    }
}

// MARK: - Запасной путь: следим за значениями опросом
final class LevelWatch {
    static let shared = LevelWatch()

    private var timer: Timer?
    private var lastBrightness: Float?
    private var lastVolume: Float?
    private var lastMuted = false

    var onChange: ((LevelKind, Float, Bool) -> Void)?

    func start(interval: TimeInterval = 0.3) {
        guard timer == nil else { return }
        synchronize()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func synchronize() {
        lastBrightness = Brightness.shared.current()
        lastVolume = Volume.shared.current()
        lastMuted = Volume.shared.isMuted()
    }

    private func observeBrightness(_ value:Float?) {lastBrightness=value}

    static func testAutomaticBrightness() {
        let watcher=LevelWatch()
        var presentations=0
        watcher.onChange={_,_,_ in presentations += 1}
        for value:Float in [0.1,0.35,0.8,0.6,0.2] {watcher.observeBrightness(value)}
        guard presentations==0,watcher.lastBrightness==0.2 else {
            fputs("AUTO BRIGHTNESS FAIL\n",stderr);exit(1)
        }
        print("AUTO BRIGHTNESS PASS: automatic changes never present HUD")
    }

    private func poll() {
        // Polling cannot distinguish automatic brightness from the user's slider.
        // Only the owned hardware-key handler is allowed to present brightness HUD.
        observeBrightness(Brightness.shared.current())

        let v = Volume.shared.current()
        let m = Volume.shared.isMuted()
        let changed = v.map { abs($0 - (lastVolume ?? $0)) > 0.001 } ?? false
        let muteChanged = m != lastMuted
        lastVolume = v
        lastMuted = m
        if changed || muteChanged { onChange?(.volume, v ?? 0, m) }
    }
}
