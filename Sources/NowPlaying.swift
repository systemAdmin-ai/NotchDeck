import AppKit

// MARK: - «Сейчас играет»
//
// Приватный MediaRemote на macOS 26+ читать не даёт: MRMediaRemoteGetNowPlayingInfo
// возвращает nil без entitlement com.apple.mediaremote.get-now-playing-info, а с такой
// строкой в подписи ad-hoc сборку убивает taskgated (Killed: 9). Проверено 12.11.2026:
// QuickTime играл, mediaremoted видел клиента, а вызов отдавал nil.
//
// Поэтому источник — AppleScript, как у Alcove (в его entitlements
// temporary-exception.apple-events: Spotify, Music, Safari, Chrome, Dia).

struct NowPlaying {
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var playing: Bool
    var source: String        // «Music», «Spotify», «QuickTime Player»
    var artwork:NSImage? = nil
    var sourceBundleID:String? = nil

    var progress: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, elapsed / duration)))
    }
}

enum MediaCommand { case toggle, next, previous }

final class NowPlayingReader {
    static let shared = NowPlayingReader()

    /// Плееры в порядке приоритета.
    private let sources: [(name: String, bundle: String)] = [
        ("Spotify", "com.spotify.client"),
        ("Music", "com.apple.Music"),
        ("QuickTime Player", "com.apple.QuickTimePlayerX")
    ]

    private var cache: [String: NSAppleScript] = [:]
    private var busy = false
    private(set) var lastSource: String?
    private(set) var last: NowPlaying?

    private func script(_ source: String, _ body: String) -> NSAppleScript? {
        let key = source + "\u{1}" + body
        if let s = cache[key] { return s }
        let s = NSAppleScript(source: "tell application \"\(source)\"\n\(body)\nend tell")
        if s != nil { cache[key] = s }
        return s
    }

    @discardableResult
    private func run(_ source: String, _ body: String) -> NSAppleEventDescriptor? {
        guard let s = script(source, body) else { return nil }
        var err: NSDictionary?
        let res = s.executeAndReturnError(&err)
        if let err { Dbg.log("AppleScript \(source): \(err[NSAppleScript.errorNumber] ?? "?")"); return nil }
        return res
    }

    func startSystemWatch(_ update:@escaping (NowPlaying?)->Void) {
        SystemMediaStream.shared.onUpdate = { [weak self] np in
            self?.last=np;self?.lastSource=np?.source;update(np)
        }
        SystemMediaStream.shared.start()
    }

    /// Число из AppleScript: в русской локали дробная часть отделяется запятой («12,0»).
    private static func num(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func fields(_ d: NSAppleEventDescriptor?) -> [String] {
        guard let str = d?.stringValue else { return [] }
        return str.components(separatedBy: "\u{1}")
    }

    /// Читает текущий трек. completion вызывается на главной очереди; nil — ничего не играет.
    func read(_ completion: @escaping (NowPlaying?) -> Void) {
        if SystemMediaStream.shared.running {
            let np=SystemMediaStream.shared.current
            last=np;lastSource=np?.source;completion(np);return
        }
        guard !busy else {return completion(last)}
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let found = self.probe()
            DispatchQueue.main.async {
                self.busy = false
                if let found { self.lastSource = found.source; self.last = found } else { self.last = nil }
                completion(found)
            }
        }
    }

    private let musicBody = """
    if player state is playing then
        return (name of current track) & (ASCII character 1) & (artist of current track) & (ASCII character 1) & (duration of current track as text) & (ASCII character 1) & (player position as text) & (ASCII character 1) & "1"
    else if player state is paused then
        return (name of current track) & (ASCII character 1) & (artist of current track) & (ASCII character 1) & (duration of current track as text) & (ASCII character 1) & (player position as text) & (ASCII character 1) & "0"
    end if
    return ""
    """

    private let quickTimeBody = """
    if (count of documents) is 0 then return ""
    set d to document 1
    return (name of d) & (ASCII character 1) & "" & (ASCII character 1) & (duration of d as text) & (ASCII character 1) & (current time of d as text) & (ASCII character 1) & (playing of d as text)
    """

    private func probe() -> NowPlaying? {
        var paused:NowPlaying?
        for (name, bundle) in sources {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { continue }
            let raw: NSAppleEventDescriptor?
            switch name {
            case "QuickTime Player": raw = run(name, quickTimeBody)
            default: raw = run(name, musicBody)
            }
            let f = NowPlayingReader.fields(raw)
            guard f.count >= 5, !f[0].isEmpty else { continue }
            let playing = f[4] == "1" || f[4].lowercased() == "true"
            let result=NowPlaying(title: f[0], artist: f[1],
                              duration: NowPlayingReader.num(f[2]), elapsed: NowPlayingReader.num(f[3]),
                              playing: playing, source: name)
            if playing {return result}
            if paused == nil {paused=result}
        }
        return paused
    }

    /// Управление активным плеером.
    /// Перемотка на долю трека (0…1) для текущего источника.
    func seek(to fraction: Double, completion: (() -> Void)? = nil) {
        guard let np = last, np.duration > 0 else { completion?(); return }
        if np.source == "demo" {completion?();return}
        if np.source == "system" {SystemMediaStream.shared.seek(to:max(0,min(np.duration,fraction*np.duration)));completion?();return}
        let target = max(0, min(np.duration - 0.5, np.duration * fraction))
        // целые секунды: QuickTime не принимает дробное значение («45,0» → ошибка -2740)
        let pos = String(Int(target.rounded()))
        let script: String
        switch np.source {
        case "QuickTime Player":
            script = "tell application \"QuickTime Player\" to set current time of document 1 to \(pos)"
        case "VLC":
            script = ""
        default:
            // Music и Spotify понимают долю в процентах надёжнее, чем секунды
            script = "tell application \"\(np.source)\" to set player position to \(pos)"
        }
        guard !script.isEmpty else { completion?(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let n = err?[NSAppleScript.errorNumber] { Dbg.log("seek error \(n) для \(np.source)") }
            DispatchQueue.main.async { completion?() }
        }
    }

    func perform(_ cmd: MediaCommand) {
        if lastSource == "demo" {return}
        if lastSource == "system" {
            switch cmd {
            case .toggle:_=Media.shared.perform(.toggle)
            case .next:_=Media.shared.perform(.next)
            case .previous:_=Media.shared.perform(.previous)
            }
            return
        }
        guard let source=lastSource else{return}
        let body: String
        if source == "QuickTime Player" {
            body = cmd == .toggle
                ? "if (count of documents) > 0 then\nif playing of document 1 then\npause document 1\nelse\nplay document 1\nend if\nend if"
                : "return"
        } else {
            switch cmd {
            case .toggle: body = "playpause"
            case .next: body = "next track"
            case .previous: body = "previous track"
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { self.run(source, body) }
        Dbg.log("медиа: \(cmd) через \(source)")
    }
}

// MARK: - Запуск приложений
enum Launcher {
    /// Открывает приложение или активирует уже запущенное. true — если получилось.
    @discardableResult
    static func open(item: Item) -> Bool {
        guard let path = item.appPath else { return false }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("NotchDeck launch failed: \(error.localizedDescription)") }
        }
        return true
    }

    /// Уже запущено? (для подсветки/активации)
    static func isRunning(item: Item) -> Bool {
        guard let id = item.appBundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    static func icon(item: Item, size: CGFloat) -> NSImage? {
        guard let path = item.appPath else { return nil }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: size, height: size)
        return img
    }
}
