import Foundation

// MARK: - Плитки, кнопки и приложения
enum Item: String, CaseIterable, Identifiable {
    // индикаторы
    case cpu, ram, temp, battery, net, disk, uptime, ip, happStatus, checkpointStatus
    // питание
    case sleep, lockScreen, mediaToggle, volumeMute, downloads, preferences
    // инструменты
    case clipboard, screenshot, record, shelf, quickNote, recordMic, recordAudio
    // запуск приложений

    var id: String { rawValue }

    var isMetric: Bool {
        switch self {
        case .cpu, .ram, .temp, .battery, .net, .disk, .uptime, .ip, .happStatus, .checkpointStatus: return true
        default: return false
        }
    }

    var isTool: Bool {
        switch self {
        case .clipboard, .screenshot, .record, .shelf: return true
        default: return false
        }
    }

    // Shortcuts are user-selected .app bundles; no personal application presets ship.
    var isApp: Bool { false }
    var appPath: String? { nil }
    var appBundleID: String? { nil }

    static var metrics: [Item] { allCases.filter { $0.isMetric } }
    static var actions: [Item] { allCases.filter { !$0.isMetric } }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .ram: return "RAM"
        case .temp: return "Темп."
        case .battery: return "Батарея"
        case .net: return "Сеть"
        case .disk: return "Диск"
        case .uptime: return "Uptime"
        case .ip: return "IP"
        case .happStatus:return "Happ"
        case .checkpointStatus:return "Check Point"
        case .quickNote:return "Заметки"
        case .recordMic:return "Микрофон записи"
        case .recordAudio:return "Звук записи"
        case .sleep: return "Сон экрана"
        case .lockScreen: return "Заблокировать"
        case .mediaToggle: return "Пауза / играть"
        case .volumeMute: return "Без звука"
        case .downloads: return "Загрузки"
        case .preferences: return "Настройки"
        case .clipboard: return "Буфер"
        case .screenshot: return "Скрин"
        case .record: return "Запись"
        case .shelf: return "Полка"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .ram: return "memorychip"
        case .temp: return "thermometer.medium"
        case .battery: return "battery.75percent"
        case .net: return "network"
        case .disk: return "internaldrive"
        case .uptime: return "clock"
        case .ip: return "globe"
        case .happStatus:return "shield.lefthalf.filled"
        case .checkpointStatus:return "lock.shield"
        case .quickNote:return "note.text"
        case .recordMic:return Capture.microphoneEnabled ? "mic.fill":"mic.slash.fill"
        case .recordAudio:return Capture.systemAudioEnabled ? "speaker.wave.2.fill":"speaker.slash.fill"
        case .sleep: return "moon.zzz.fill"
        case .lockScreen: return "lock.fill"
        case .mediaToggle: return "playpause.fill"
        case .volumeMute: return "speaker.slash.fill"
        case .downloads: return "folder.fill"
        case .preferences: return "gearshape.fill"
        case .clipboard: return "doc.on.doc.fill"
        case .screenshot: return "camera.viewfinder"
        case .record: return "record.circle"
        case .shelf: return "tray.full.fill"
        }
    }
}

// MARK: - Конфигурация (UserDefaults, без Combine)
final class Config {
    static let shared = Config()
    static let didChange = Notification.Name("NotchDeck.configChanged")

    private let defaults = UserDefaults.standard
    private(set) var hidden: Set<String>
    private(set) var order: [String]

    static let cleanHiddenItems = ["cpu","temp","disk","uptime","ip","happStatus","checkpointStatus","sleep","lockScreen","mediaToggle","volumeMute","downloads","recordMic","recordAudio","clipboard","shelf"]
    private init() {
        let known = Set(Item.allCases.map(\.rawValue))
        hidden = Set(defaults.stringArray(forKey: "NotchDeck.hiddenItems") ?? Self.cleanHiddenItems).intersection(known)
        if !defaults.bool(forKey: "NotchDeck.actionsR39Migrated") {
            hidden.formUnion(["lockScreen","mediaToggle","volumeMute","downloads"])
            defaults.set(Array(hidden),forKey:"NotchDeck.hiddenItems")
            defaults.set(true,forKey:"NotchDeck.actionsR39Migrated")
        }
        var o = (defaults.stringArray(forKey: "NotchDeck.order") ?? []).filter { known.contains($0) }
        for item in Item.allCases where !o.contains(item.rawValue) { o.append(item.rawValue) }
        order = o
    }

    func visible(_ items: [Item]) -> [Item] {
        items.filter { !hidden.contains($0.rawValue) }.sorted { a, b in
            (order.firstIndex(of: a.rawValue) ?? 999) < (order.firstIndex(of: b.rawValue) ?? 999)
        }
    }

    private func save() {
        defaults.set(Array(hidden), forKey: "NotchDeck.hiddenItems")
        defaults.set(order, forKey: "NotchDeck.order")
    }

    func hide(_ item: Item) {
        hidden.insert(item.rawValue)
        save()
        NotificationCenter.default.post(name: Config.didChange, object: nil)
    }

    func unhide(_ item: Item) {
        hidden.remove(item.rawValue)
        save()
        NotificationCenter.default.post(name: Config.didChange, object: nil)
    }

    func resetAll() {
        hidden = []
        order = Item.allCases.map(\.rawValue)
        save()
        NotificationCenter.default.post(name: Config.didChange, object: nil)
    }
}
