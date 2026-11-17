// Adapted from DeskBridge (MIT), copyright 2026 systemAdmin-ai.
import AppKit
import Combine
import IOKit.hid
import Carbon

struct DBKeyboard: Identifiable {
    let id: UInt64
    let name: String
    let identity: DBKeyboardIdentity
    let builtIn: Bool
    var isExternal: Bool { DBKeyboardPolicy.isExternal(transport: identity.transport, builtIn: builtIn) }
    var groupKey: String {
        if let key = identity.persistentKey { return "serial:\(key)" }
        if identity.location != 0 { return "location:\(identity.sessionKey)" }
        return "registry:\(id)"
    }
}
struct DBScreenInfo: Identifiable {
    let id: UInt32
    let name: String
    let detail: String
}

final class DBHardware: ObservableObject {
    @Published var keyboards: [DBKeyboard] = []
    @Published var screens: [DBScreenInfo] = []
    @Published var message = ""
    @Published private(set) var accessDetail = ""
    @Published private(set) var modifierEvents = 0
    @Published private(set) var sourceName = ""
    var bundlePath: String { Bundle.main.bundleURL.path }
    let shortcuts = DBNativeShortcuts()
    private var currentSettings: DBSettings?
    private var heldModifiers: [UInt64: Set<Int>] = [:]
    private var activationObserver: NSObjectProtocol?
    @Published var paused = false { didSet { chords.removeAll(); updateShortcuts() } }
    @Published var enabled: Set<UInt64> = []
    private var chords: [UInt64: DBModifierChord] = [:]
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var opened = false
    private var sessionOverrides: [UInt64: Bool] = [:]
    private var lastSwitchTime: TimeInterval = 0
    @Published private(set) var inputReady = false
    var groups: [DBKeyboard] {
        var seen = Set<String>()
        return keyboards.filter { seen.insert($0.groupKey).inserted }
    }
    func interfaceCount(_ keyboard: DBKeyboard) -> Int { keyboards.filter { $0.groupKey == keyboard.groupKey }.count }
    func applyRules(_ settings: DBSettings, devices: [DBKeyboard]? = nil) {
        currentSettings = settings
        updateShortcuts()
        let devices = devices ?? keyboards
        let desired = Set(devices.filter { DBKeyboardPolicy.enabled(identity: $0.identity, builtIn: $0.builtIn, settings: settings, sessionOverride: sessionOverrides[$0.id]) }.map(\.id))
        guard enabled != desired else { return }
        chords.removeAll()
        enabled = desired
    }
    private func updateShortcuts() {
        guard let currentSettings else { return }
        let held = heldModifiers.values.contains { !$0.isEmpty }
        shortcuts.update(settings: currentSettings, paused: paused, permission: permission, modifiersHeld: held)
    }
    var permission: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    init() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<DBHardware>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<DBHardware>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<DBHardware>.fromOpaque(context).takeUnretainedValue().input(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        openInputIfAllowed()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.openInputIfAllowed()
            self.updateShortcuts()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.updateShortcuts() }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshScreens() }
        refresh()
    }
    private func openInputIfAllowed() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let cgGranted = CGPreflightListenEventAccess()
        let state = access == kIOHIDAccessTypeGranted ? "разрешён" : (access == kIOHIDAccessTypeDenied ? "отказано" : "не запрошен")
        let detail = "IOHID: \(state) · CoreGraphics: \(cgGranted ? "разрешён" : "нет доступа")"
        if accessDetail != detail { accessDetail = detail }
        updateSourceName()
        guard access == kIOHIDAccessTypeGranted else {
            if opened { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)); opened = false }
            if inputReady { inputReady = false; chords.removeAll() }
            return
        }
        guard !opened else { return }
        opened = true
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        opened = result == kIOReturnSuccess
        inputReady = opened
        message = opened ? "Клавиатуры готовы. Нажмите Alt + Shift на внешней клавиатуре." : "Не удалось открыть HID: \(result). Перезапустите приложение."
    }
    func requestPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
        openInputIfAllowed()
        if !inputReady { message = "Если DeskBridge включён в настройках, но IOHID сообщает отказ: удалите старую запись кнопкой «−», добавьте эту сборку кнопкой «+» и перезапустите приложение." }
    }
    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }
    func refresh() {
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let discovered = devices.map { device in
            func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
            func string(_ key: String) -> String? { IOHIDDeviceGetProperty(device, key as CFString) as? String }
            return DBKeyboard(id: registryID(device), name: string(kIOHIDProductKey) ?? "Keyboard", identity: DBKeyboardIdentity(vendor: int(kIOHIDVendorIDKey), product: int(kIOHIDProductIDKey), serial: string(kIOHIDSerialNumberKey), transport: string(kIOHIDTransportKey) ?? "Unknown", location: int(kIOHIDLocationIDKey)), builtIn: int("Built-In") != 0)
        }.sorted { $0.id < $1.id }
        let connected = Set(discovered.map(\.id))
        sessionOverrides = sessionOverrides.filter { connected.contains($0.key) }
        heldModifiers = heldModifiers.filter { connected.contains($0.key) }
        enabled.formIntersection(connected)
        chords = chords.filter { connected.contains($0.key) }
        keyboards = discovered
        refreshScreens()
    }
    func refreshScreens() {
        screens = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            let mode = CGDisplayCopyDisplayMode(id)
            return DBScreenInfo(id: id, name: screen.localizedName, detail: "\(mode?.pixelWidth ?? 0) × \(mode?.pixelHeight ?? 0) px · \(Int(mode?.refreshRate ?? 0)) Hz · \(Int(screen.frame.origin.x)), \(Int(screen.frame.origin.y))")
        }
    }
    func setEnabled(_ id: UInt64, _ value: Bool) {
        guard let keyboard = keyboards.first(where: { $0.id == id }) else { return }
        for member in keyboards where member.groupKey == keyboard.groupKey {
            sessionOverrides[member.id] = value
            if value { enabled.insert(member.id) } else { enabled.remove(member.id) }
            chords[member.id] = DBModifierChord()
        }
    }
    private func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == 7 else { return }
        let id = registryID(IOHIDElementGetDevice(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard (0xE0...0xE7).contains(usage) else { return }
        var held = heldModifiers[id] ?? []
        if IOHIDValueGetIntegerValue(value) != 0 { held.insert(usage) } else { held.remove(usage) }
        heldModifiers[id] = held
        if heldModifiers.values.allSatisfy({ $0.isEmpty }) { updateShortcuts() }
        guard !paused, enabled.contains(id) else { chords[id] = DBModifierChord(); return }
        modifierEvents += 1
        var chord = chords[id] ?? DBModifierChord()
        let trigger = chord.update(usage: usage, pressed: IOHIDValueGetIntegerValue(value) != 0)
        chords[id] = chord
        // Composite keyboards can report the same chord through multiple HID interfaces.
        if trigger {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastSwitchTime > 0.15 { lastSwitchTime = now; switchInputSource() }
        }
    }
    private func updateSourceName() {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if let pointer = TISGetInputSourceProperty(current, kTISPropertyLocalizedName) {
            let name = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            if sourceName != name { sourceName = name }
        }
    }
    func switchInputSource() {
        let filter = [kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!, kTISPropertyInputSourceIsSelectCapable!: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], sources.count > 1 else {
            message = "Добавьте минимум два источника ввода в настройках macOS."; return
        }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let index = sources.firstIndex { CFEqual($0, current) } ?? 0
        let status = TISSelectInputSource(sources[(index + 1) % sources.count])
        updateSourceName()
        message = status == noErr ? "Источник ввода: \(sourceName)" : "Не удалось переключить источник: \(status)"
    }
    deinit {
        shortcuts.restoreAll()
        timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
