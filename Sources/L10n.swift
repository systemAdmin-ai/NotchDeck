import Foundation

// MARK: - Языки интерфейса

enum AppLanguage: String, CaseIterable {
    case system, ru, en

    /// Подпись в списке выбора. Языки подписаны на самих себе, чтобы пункт был
    /// понятен независимо от текущего языка интерфейса.
    var nativeTitle: String {
        switch self {
        case .system: return "Авто / Auto"
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

// MARK: - Локализация

/// Ключом перевода служит русская строка из исходника: `L("Настройки")`.
/// При русском интерфейсе возвращается ключ, при английском — перевод из
/// `en.lproj/Localizable.strings`. Если перевода нет, возвращается ключ:
/// интерфейс деградирует до русского текста, но никогда не до пустой строки.
final class L10n {
    static let shared = L10n()
    static let didChange = Notification.Name("NotchDeck.languageChanged")
    static let defaultsKey = "NotchDeck.appLanguage"

    private let defaults: UserDefaults
    private var bundle: Bundle?
    private(set) var mode: AppLanguage = .system

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    /// Язык системы: русский, если первый предпочитаемый язык начинается с `ru`.
    static var systemLanguage: AppLanguage {
        let first = Locale.preferredLanguages.first ?? "en"
        return first.hasPrefix("ru") ? .ru : .en
    }

    /// Фактический язык с учётом режима «Авто».
    var effective: AppLanguage {
        mode == .system ? Self.systemLanguage : mode
    }

    func reload() {
        if let override = ProcessInfo.processInfo.environment["NOTCHDECK_LANGUAGE"],
           let forced = AppLanguage(rawValue: override) {
            mode = forced
        } else {
            mode = AppLanguage(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "system") ?? .system
        }
        bundle = nil
        guard effective == .en,
              let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let loaded = Bundle(path: path) else { return }
        bundle = loaded
    }

    func set(_ language: AppLanguage) {
        guard language != mode else { return }
        defaults.set(language.rawValue, forKey: Self.defaultsKey)
        reload()
        // Панель перестраивается по этому же уведомлению: см. DeckController.
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        NotificationCenter.default.post(name: Preferences.didChange, object: nil)
    }

    func translate(_ key: String) -> String {
        guard effective == .en, let bundle else { return key }
        let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
        return value == "\u{0}" ? key : value
    }

    /// Диагностика для `--l10n-report`.
    func report() -> String {
        var lines: [String] = []
        lines.append("mode=\(mode.rawValue) effective=\(effective.rawValue) system=\(Self.systemLanguage.rawValue)")
        lines.append("bundle=\(bundle?.bundlePath ?? "none")")
        let path = Bundle.main.path(forResource: "en", ofType: "lproj")
        let table = path.flatMap { NSDictionary(contentsOfFile: $0 + "/Localizable.strings") as? [String: Any] }
        lines.append("keys=\(table?.count ?? 0)")
        lines.append("sample настроек=\(translate("Настройки"))")
        lines.append("sample format=\(String(format: translate("Память занята на %.0f %%"), 71.0))")
        lines.append("missing_fallback=\(translate("__нет такого ключа__"))")
        return lines.joined(separator: "\n")
    }
}

/// Перевод строки интерфейса. С аргументами — format-строка: `L("Память занята на %.0f %%", value)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let base = L10n.shared.translate(key)
    guard !args.isEmpty else { return base }
    return String(format: base, arguments: args)
}
