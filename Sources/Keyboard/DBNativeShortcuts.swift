// Adapted from DeskBridge (MIT), copyright 2026 systemAdmin-ai.
import AppKit
import Combine
import IOKit.hidsystem

struct DBKeyMapping: Codable, Equatable {
    var source: UInt64
    var destination: UInt64
    static let leftControl: UInt64 = 0x7000000E0
    static let leftCommand: UInt64 = 0x7000000E3
    static let controlToCommand = DBKeyMapping(source: leftControl, destination: leftCommand)
    var dictionary: [String: NSNumber] {
        ["HIDKeyboardModifierMappingSrc": NSNumber(value: source), "HIDKeyboardModifierMappingDst": NSNumber(value: destination)]
    }
    static func addingControl(to original: [DBKeyMapping]) -> [DBKeyMapping]? {
        // A pre-existing Control mapping belongs to the user or another utility.
        guard !original.contains(where: { $0.source == leftControl }) else { return nil }
        return original + [.controlToCommand]
    }
    static func decode(_ value: CFTypeRef?) -> [DBKeyMapping]? {
        guard let value else { return [] }
        guard let list = value as? [[String: NSNumber]] else { return nil }
        var result: [DBKeyMapping] = []
        for entry in list {
            guard entry.count == 2, let src = entry["HIDKeyboardModifierMappingSrc"], let dst = entry["HIDKeyboardModifierMappingDst"] else { return nil }
            result.append(DBKeyMapping(source: src.uint64Value, destination: dst.uint64Value))
        }
        return result
    }
}

struct DBShortcutPolicy {
    static let defaultExceptions = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
        "com.microsoft.rdc.macos", "com.microsoft.rdc.mac", "com.microsoft.rdc.osx.beta",
        "com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.UTM",
        "com.anydesk.AnyDesk", "com.teamviewer.TeamViewer", "com.apple.ScreenSharing"
    ]
    static func isExcluded(_ bundleID: String?, exceptions: [String]) -> Bool {
        guard let bundleID else { return true }
        return exceptions.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }
}

struct DBSavedKeyMap: Codable {
    let fingerprint: String
    let original: [DBKeyMapping]
    let applied: [DBKeyMapping]
    func canRestore(fingerprint: String, current: [DBKeyMapping]) -> Bool {
        self.fingerprint == fingerprint && current == applied
    }
}

/// Native, device-scoped key maps. No keyboard event injection or virtual driver.
final class DBNativeShortcuts: ObservableObject {
    @Published private(set) var status = "Ctrl-сочетания: ожидание устройств"
    private(set) var appliedServiceCount = 0
    private(set) var conflictCount = 0
    private(set) var failureCount = 0
    var journalError: Bool { journalFailed }
    private var snapshotClient: IOHIDEventSystemClient?
    private var saved: [String: DBSavedKeyMap] = [:]
    private var journalFailed = false
    private var conflictsUntilDisconnect = Set<String>()
    private let journalURL = DBSettingsStore.standard.url.deletingLastPathComponent().appendingPathComponent("keymap-recovery.json")
    private var terminateObserver: NSObjectProtocol?

    init() {
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do { saved = try JSONDecoder().decode([String: DBSavedKeyMap].self, from: Data(contentsOf: journalURL)) }
            catch { journalFailed = true; status = "Журнал клавиш повреждён: переназначение отключено" }
        }
        restoreAll()
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.restoreAll() }
    }
    private func services() -> [IOHIDServiceClient] {
        // A simple client's service list is a snapshot without event scheduling.
        // Recreate it on reconciliation so hot-plugged keyboards are included.
        let snapshot = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        snapshotClient = snapshot
        return IOHIDEventSystemClientCopyServices(snapshot) as? [IOHIDServiceClient] ?? []
    }
    private func property(_ service: IOHIDServiceClient, _ key: String) -> CFTypeRef? {
        IOHIDServiceClientCopyProperty(service, key as CFString)
    }
    private func int(_ service: IOHIDServiceClient, _ key: String) -> Int {
        (property(service, key) as? NSNumber)?.intValue ?? 0
    }
    private func string(_ service: IOHIDServiceClient, _ key: String) -> String {
        property(service, key) as? String ?? ""
    }
    private func id(_ service: IOHIDServiceClient) -> String {
        String((IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0)
    }
    private func fingerprint(_ service: IOHIDServiceClient) -> String {
        "\(int(service, "VendorID")):\(int(service, "ProductID")):\(string(service, "SerialNumber")):\(string(service, "Transport")):\(int(service, "LocationID"))"
    }
    @discardableResult private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: journalURL, options: .atomic)
            return true
        } catch { status = "Не удалось сохранить журнал восстановления: \(error.localizedDescription)"; return false }
    }
    private func write(_ map: [DBKeyMapping], to service: IOHIDServiceClient) -> Bool {
        guard IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, map.map(\.dictionary) as CFArray) else { return false }
        return DBKeyMapping.decode(property(service, "UserKeyMapping")) == map
    }
    private func restore(_ service: IOHIDServiceClient) -> Bool {
        let key = id(service)
        guard let entry = saved[key] else { return true }
        guard let current = DBKeyMapping.decode(property(service, "UserKeyMapping")) else { return false }
        if entry.canRestore(fingerprint: fingerprint(service), current: current) {
            guard write(entry.original, to: service) else { return false }
        }
        // A changed identity/map is owned by another actor: do not overwrite it.
        saved.removeValue(forKey: key)
        return persist()
    }
    func restoreAll() {
        appliedServiceCount = 0
        guard !journalFailed else { return }
        var failures = 0
        let current = services()
        for service in current where saved[id(service)] != nil {
            if !restore(service) { failures += 1 }
        }
        // Missing permission can hide services. Keep recovery records until access returns.
        let ids = Set(current.map { id($0) })
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
            saved = saved.filter { ids.contains($0.key) }
        }
        if !saved.isEmpty || failures > 0 { status = "Не все карты восстановлены; журнал сохранён для повторной попытки" }
        _ = persist()
    }
    func update(settings: DBSettings, paused: Bool, permission: Bool, modifiersHeld: Bool) {
        guard !journalFailed else { return }
        let excluded = DBShortcutPolicy.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, exceptions: settings.shortcutExceptions ?? DBShortcutPolicy.defaultExceptions)
        let desired = settings.windowsControl != false && !paused && permission && !excluded
        // Avoid changing a modifier's meaning between key-down and key-up.
        if modifiersHeld && !paused && settings.windowsControl != false {
            status = "Ctrl: отпустите модификаторы для применения настроек"
            return
        }
        let currentServices = services()
        var applied = 0, conflicts = 0, failures = 0
        for service in currentServices {
            let key = id(service)
            let external = DBKeyboardPolicy.isExternal(transport: string(service, "Transport"), builtIn: int(service, "Built-In") != 0)
            let keyboard = IOHIDServiceClientConformsTo(service, 1, 6) != 0
            if !desired || !external || !keyboard {
                if !restore(service) { failures += 1 }
                continue
            }
            if conflictsUntilDisconnect.contains(key) { conflicts += 1; continue }
            guard key != "0", let map = DBKeyMapping.decode(property(service, "UserKeyMapping")) else { failures += 1; continue }
            if let own = saved[key] {
                if own.canRestore(fingerprint: fingerprint(service), current: map) { applied += 1; continue }
                // Do not re-apply over an external change during this update.
                saved.removeValue(forKey: key)
                conflictsUntilDisconnect.insert(key)
                _ = persist()
                conflicts += 1
                continue
            }
            guard let replacement = DBKeyMapping.addingControl(to: map) else { conflicts += 1; continue }
            saved[key] = DBSavedKeyMap(fingerprint: fingerprint(service), original: map, applied: replacement)
            guard persist() else { saved.removeValue(forKey: key); failures += 1; continue }
            if write(replacement, to: service) { applied += 1 }
            else {
                // A setter may change the map even when verification fails; keep the journal.
                failures += 1
            }
        }
        let ids = Set(currentServices.map { id($0) })
        let stale = saved.keys.filter { !ids.contains($0) }
        if permission {
            conflictsUntilDisconnect.formIntersection(ids)
            if !stale.isEmpty { stale.forEach { saved.removeValue(forKey: $0) }; _ = persist() }
        }
        let text: String
        if !permission { text = "Ctrl: требуется разрешение мониторинга ввода" }
        else if paused || settings.windowsControl == false { text = "Ctrl: исходные карты восстановлены" }
        else if excluded { text = "Ctrl: исключение для текущего приложения" }
        else { text = "Левый Ctrl → ⌘: сервисов \(applied)" }
        appliedServiceCount = applied
        conflictCount = conflicts
        failureCount = failures
        status = text + (conflicts > 0 ? " · конфликтов: \(conflicts)" : "") + (failures > 0 ? " · ошибок: \(failures)" : "")
    }
    deinit {
        restoreAll()
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }
}
