import AppKit
import Combine

final class KeyboardMode {
    static let shared = KeyboardMode()
    static let didChange = Notification.Name("NotchDeck.keyboardModeChanged")
    private let defaults = UserDefaults.standard
    private var policy: KeyboardModePolicy
    private var hardware: DBHardware?
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var signature = ""
    private(set) var state: KeyboardModeState = .off
    private(set) var externalCount = 0
    private(set) var deviceNames = ""
    var automatic: Bool { policy.automatic }
    var requested: Bool { policy.requested(externalCount: externalCount) }
    var active: Bool { state == .active }
    private var standaloneRunning: Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "org.deskbridge.app" } }
    private var exceptions: [String] { defaults.stringArray(forKey: "NotchDeck.keyboard.exceptions") ?? DBShortcutPolicy.defaultExceptions }

    private init() {
        policy = KeyboardModePolicy(automatic: (defaults.object(forKey: "NotchDeck.keyboard.automatic") as? Bool) ?? true,
                                    manualOverride: defaults.object(forKey: "NotchDeck.keyboard.manualOverride") as? Bool)
    }
    func start() {
        guard timer == nil else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reconcile() })
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.reconcile() }
        RunLoop.main.add(t, forMode: .common); timer = t
        reconcile()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        subscription?.cancel(); subscription = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
        hardware?.paused = true
        hardware?.shortcuts.restoreAll()
        hardware = nil
        state = .off
        signature = ""
        emit()
    }
    func toggle() {
        if state == .permission || state == .conflict { KeyboardModePreferences.shared.show(); return }
        policy.toggle(externalCount: externalCount)
        save(); reconcile()
    }
    func setEnabled(_ value: Bool) { policy.manualOverride = value; save(); reconcile() }
    func setAutomatic(_ value: Bool) { policy.setAutomatic(value); save(); reconcile() }
    func requestPermission() { hardware?.requestPermission(); reconcile() }
    private func save() {
        defaults.set(policy.automatic, forKey: "NotchDeck.keyboard.automatic")
        if let manual = policy.manualOverride { defaults.set(manual, forKey: "NotchDeck.keyboard.manualOverride") }
        else { defaults.removeObject(forKey: "NotchDeck.keyboard.manualOverride") }
    }
    private func reconcile() {
        if standaloneRunning {
            hardware?.paused = true
            var disabled = DBSettings(); disabled.windowsControl = false; disabled.autoEnableExternal = false
            hardware?.applyRules(disabled)
            state = policy.manualOverride == false || (!automatic && policy.manualOverride == nil) ? .off : .conflict
            let nextSignature = "standalone|\(state)|\(automatic)|\(String(describing: policy.manualOverride))"
            if signature != nextSignature { signature = nextSignature; emit() }
            return
        }
        if hardware == nil {
            let source = DBHardware(); hardware = source
            subscription = source.$keyboards.sink { [weak self] _ in DispatchQueue.main.async { self?.reconcile() } }
        }
        guard let hardware else { return }
        let external = hardware.groups.filter(\.isExternal)
        externalCount = external.count
        deviceNames = external.map(\.name).joined(separator: ", ")
        let blocked = standaloneRunning
        let enabled = requested && !blocked
        var settings = DBSettings()
        settings.autoEnableExternal = enabled
        settings.windowsControl = enabled
        settings.shortcutExceptions = exceptions
        if hardware.paused != !enabled { hardware.paused = !enabled }
        hardware.applyRules(settings)
        let excluded = DBShortcutPolicy.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, exceptions: exceptions)
        let next = KeyboardModeState.resolve(requested: requested, automatic: automatic, manuallyOff: policy.manualOverride == false,
                                             externalCount: externalCount, permission: hardware.permission, ready: hardware.inputReady,
                                             blocked: blocked, errors: hardware.shortcuts.conflictCount > 0 || hardware.shortcuts.failureCount > 0 || hardware.shortcuts.journalError,
                                             applied: hardware.shortcuts.appliedServiceCount, excluded: excluded)
        state = next
        let nextSignature = "\(next)|\(externalCount)|\(deviceNames)|\(policy.automatic)|\(String(describing: policy.manualOverride))"
        if signature != nextSignature { signature = nextSignature; emit() }
    }
    private func emit() { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    var status: String {
        switch state {
        case .off: return L("Клавиатура: выключено вручную")
        case .waiting: return L("Клавиатура: ожидание внешнего устройства")
        case .permission: return L("Клавиатура: нужен доступ к мониторингу ввода")
        case .conflict: return standaloneRunning ? L("Закройте DeskBridge, чтобы включить режим в NotchDeck") : L("Клавиатура: переназначение не применено; проверьте настройки")
        case .suspended: return L("Клавиатура: Alt+Shift включён, Ctrl сохранён для текущего приложения")
        case .active: return L("Клавиатура: Alt+Shift и Ctrl-сочетания включены")
        }
    }
    var tooltip: String { status + "\n" + (active ? L("Нажмите, чтобы выключить") : L("Нажмите, чтобы включить или открыть настройки")) }
    func showSettings() { KeyboardModePreferences.shared.show() }
}

final class KeyboardModePreferences: NSObject {
    static let shared = KeyboardModePreferences()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x:0,y:0,width:560,height:350),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            w.title = L("Клавиатура Windows"); w.isReleasedWhenClosed = false
            w.contentView = KeyboardModeSettingsView(frame:NSRect(x:0,y:0,width:560,height:350));w.center();window=w
        }
        window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
}

final class KeyboardModeSettingsView: NSView {
    override var isFlipped: Bool { true }
    private let automatic = NSButton(checkboxWithTitle:"",target:nil,action:nil)
    private let enabled = NSButton(checkboxWithTitle:"",target:nil,action:nil)
    private let status = NSTextField(wrappingLabelWithString:"")
    private let devices = NSTextField(wrappingLabelWithString:"")
    private var observer: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private let note = NSTextField(wrappingLabelWithString: "")
    private let permission = NSButton(title: "", target: nil, action: nil)
    override init(frame:NSRect) {
        super.init(frame:frame)
        automatic.title=L("Автовключение при подключении внешней клавиатуры")
        automatic.target=self;automatic.action=#selector(autoChanged)
        automatic.frame=NSRect(x:20,y:20,width:520,height:26);addSubview(automatic)
        enabled.title=L("Alt+Shift и левый Ctrl как Command")
        enabled.target=self;enabled.action=#selector(enabledChanged)
        enabled.frame=NSRect(x:20,y:58,width:520,height:26);addSubview(enabled)
        status.frame=NSRect(x:20,y:104,width:520,height:46);status.font = .systemFont(ofSize:13,weight:.semibold);addSubview(status)
        devices.frame=NSRect(x:20,y:156,width:520,height:34);devices.font = .systemFont(ofSize:12);devices.textColor = .secondaryLabelColor;addSubview(devices)
        note.stringValue=L("Встроенная клавиатура не меняется. Ручное выключение сохраняется; включите режим кнопкой или повторно выберите авторежим. Правый Ctrl остаётся Control. Терминалы и удалённые сессии исключены из замены Ctrl.")
        note.frame=NSRect(x:20,y:202,width:520,height:76);note.font = .systemFont(ofSize:12);note.textColor = .secondaryLabelColor;addSubview(note)
        permission.title=L("Разрешить мониторинг ввода…");permission.target=self;permission.action=#selector(requestPermission)
        permission.bezelStyle = .rounded;permission.frame=NSRect(x:20,y:296,width:290,height:32);addSubview(permission)
        observer=NotificationCenter.default.addObserver(forName:KeyboardMode.didChange,object:nil,queue:.main) { [weak self] _ in self?.refresh() }
        languageObserver=NotificationCenter.default.addObserver(forName:L10n.didChange,object:nil,queue:.main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {
        if let observer {NotificationCenter.default.removeObserver(observer)}
        if let languageObserver {NotificationCenter.default.removeObserver(languageObserver)}
    }
    private func refresh() {
        let mode=KeyboardMode.shared
        window?.title=L("Клавиатура Windows")
        automatic.title=L("Автовключение при подключении внешней клавиатуры")
        enabled.title=L("Alt+Shift и левый Ctrl как Command")
        permission.title=L("Разрешить мониторинг ввода…")
        note.stringValue=L("Встроенная клавиатура не меняется. Ручное выключение сохраняется; включите режим кнопкой или повторно выберите авторежим. Правый Ctrl остаётся Control. Терминалы и удалённые сессии исключены из замены Ctrl.")
        automatic.state=mode.automatic ? .on:.off;enabled.state=mode.requested ? .on:.off
        status.stringValue=mode.status;devices.stringValue=mode.externalCount>0 ? L("Подключено: %@",mode.deviceNames):L("Внешняя клавиатура не обнаружена")
    }
    @objc private func autoChanged() {KeyboardMode.shared.setAutomatic(automatic.state == .on)}
    @objc private func enabledChanged() {KeyboardMode.shared.setEnabled(enabled.state == .on)}
    @objc private func requestPermission() {KeyboardMode.shared.requestPermission()}
}
