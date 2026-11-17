// Adapted from DeskBridge (MIT), copyright 2026 systemAdmin-ai.
import Foundation

struct DBKeyboardIdentity: Codable, Equatable {
    var vendor: Int
    var product: Int
    var serial: String?
    var transport: String
    var location: Int
    var persistentKey: String? {
        guard let serial, !serial.isEmpty else { return nil }
        return "\(vendor):\(product):\(serial)"
    }
    var sessionKey: String { "\(vendor):\(product):\(transport):\(location)" }
}

struct DBKeyboardProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var identities: [String] = []
    var altShift = false
}

struct DBSettings: Codable {
    var version = 1
    var profiles: [DBKeyboardProfile] = []
    var autoEnableExternal: Bool? = true
    var windowsControl: Bool? = true
    var advancedNavigation: Bool? = false
    var shortcutExceptions: [String]? = nil
    func profile(for identity: DBKeyboardIdentity) -> DBKeyboardProfile? {
        guard let key = identity.persistentKey else { return nil }
        return profiles.first { $0.identities.contains(key) }
    }
}

struct DBKeyboardPolicy {
    static func isExternal(transport: String, builtIn: Bool) -> Bool {
        guard !builtIn else { return false }
        return ["usb", "bluetooth", "bluetooth low energy", "bluetoothlowenergy"].contains(transport.lowercased())
    }
    static func enabled(identity: DBKeyboardIdentity, builtIn: Bool, settings: DBSettings, sessionOverride: Bool?) -> Bool {
        if let sessionOverride { return sessionOverride }
        if let profile = settings.profile(for: identity) { return profile.altShift }
        return settings.autoEnableExternal != false && isExternal(transport: identity.transport, builtIn: builtIn)
    }
}

struct DBModifierChord {
    private var held = Set<Int>()
    private var fired = false
    mutating func update(usage: Int, pressed: Bool) -> Bool {
        if pressed { held.insert(usage) } else { held.remove(usage) }
        let shift = held.contains(0xE1) || held.contains(0xE5)
        let alt = held.contains(0xE2) || held.contains(0xE6)
        let other = !held.isDisjoint(with: [0xE0, 0xE3, 0xE4, 0xE7])
        let active = shift && alt && !other
        defer { if !shift && !alt { fired = false } }
        if active && !fired { fired = true; return true }
        return false
    }
}

struct DBSettingsStore {
    let url: URL
    static var standard: DBSettingsStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DBSettingsStore(url: base.appendingPathComponent((Bundle.main.bundleIdentifier ?? "com.notchdeck.app") + "/Keyboard/settings.json"))
    }
    func load() throws -> DBSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return DBSettings() }
        let value = try JSONDecoder().decode(DBSettings.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    func save(_ value: DBSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
