import AppKit
import Foundation
import AVFoundation

// MARK: - Буфер обмена
enum ClipKind { case text, image, files }

final class ClipItem {
    let kind: ClipKind
    let text: String?
    let image: NSImage?
    let urls: [URL]

    init(kind: ClipKind, text: String? = nil, image: NSImage? = nil, urls: [URL] = []) {
        self.kind = kind
        self.text = text
        self.image = image
        self.urls = urls
    }

    var preview: String {
        switch kind {
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "(пусто)" : String(t.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        case .image:
            let w = Int(image?.size.width ?? 0), h = Int(image?.size.height ?? 0)
            return "Изображение \(w)×\(h)"
        case .files:
            return urls.map { $0.lastPathComponent }.joined(separator: ", ")
        }
    }

    var symbol: String {
        switch kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }
}

/// История копирований: только в памяти, максимум 30 записей и ~20 МБ картинок.
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var items: [ClipItem] = []
    private var lastChange = -1
    private var timer: Timer?
    private let limit = 30
    private let imageBudget = 20 * 1024 * 1024

    private init() {}

    func start() {
        guard timer == nil, Preferences.shared.bool("clipboardHistory",fallback:false) else { return }
        lastChange = NSPasteboard.general.changeCount
        let t = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        capture(pb)
    }

    /// Разбирает текущее содержимое буфера (вызывается и из CLI, и по таймеру).
    @discardableResult
    func capture(_ pb: NSPasteboard = .general) -> ClipItem? {
        var item: ClipItem?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            item = ClipItem(kind: .files, urls: urls)
        } else if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
                  let img = images.first {
            item = ClipItem(kind: .image, image: img)
        } else if let s = pb.string(forType: .string), !s.isEmpty {
            item = ClipItem(kind: .text, text: s)
        }
        guard let item else { return nil }
        // не дублируем подряд одинаковое
        if let first = items.first, first.preview == item.preview, first.kind == item.kind { return item }
        items.insert(item, at: 0)
        trim()
        Dbg.log("clipboard: captured item; count=\(items.count)")
        return item
    }

    private func trim() {
        if items.count > limit { items.removeLast(items.count - limit) }
        var budget = imageBudget
        var keep: [ClipItem] = []
        for it in items {
            if it.kind == .image {
                let bytes = Int((it.image?.tiffRepresentation?.count ?? 0))
                if bytes > budget { continue }
                budget -= bytes
            }
            keep.append(it)
        }
        items = keep
    }

    func restore(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let img = item.image { pb.writeObjects([img]) }
        case .files:
            pb.writeObjects(item.urls as [NSURL])
        }
        lastChange = pb.changeCount
        Dbg.log("clipboard: restored item")
    }

    func clear() {
        items.removeAll()
    }
}

// MARK: - Полка для файлов
final class ShelfStore {
    static let shared = ShelfStore()
    private(set) var urls: [URL] = []
    private let limit = 20
    private let key = "NotchDeck.shelf"

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        urls = saved.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() {
        UserDefaults.standard.set(urls.map { $0.path }, forKey: key)
    }

    @discardableResult
    func add(_ new: [URL]) -> Int {
        var added = 0
        for u in new where u.isFileURL {
            guard !urls.contains(u) else { continue }
            urls.append(u)
            added += 1
        }
        if urls.count > limit { urls.removeFirst(urls.count - limit) }
        if added > 0 { save(); Dbg.log("shelf: +\(added) файлов, всего=\(urls.count)") }
        return added
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        save()
    }

    func clear() {
        urls.removeAll()
        save()
    }
}

// MARK: - Скриншоты и запись
enum Capture {
    static var folder: URL {
        let u = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/Screenshots")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    static func file(_ ext: String) -> URL {
        folder.appendingPathComponent("NotchDeck-\(stamp()).\(ext)")
    }

    /// Интерактивный выбор области/окна средствами системы; файл кладём в папку и в буфер.
    static func screenshot(rect: NSRect? = nil) -> URL {
        let path = file("png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if let r = rect {
            p.arguments = ["-x", "-R", String(format: "%d,%d,%d,%d", Int(r.origin.x), Int(r.origin.y),
                                              Int(r.width), Int(r.height)), "-t", "png", path.path]
        } else {
            p.arguments = ["-i", "-x", "-o", "-t", "png", path.path]
        }
        try? p.run()
        if rect != nil {
            p.waitUntilExit()
            afterScreenshot(path, status: p.terminationStatus)
        }
        p.terminationHandler = { proc in
            afterScreenshot(path, status: proc.terminationStatus)
        }
        return path
    }

    /// После съёмки: путь в буфер + сигнал. Отмена пользователем — просто лог.
    private static func afterScreenshot(_ path: URL, status: Int32) {
        guard status == 0, FileManager.default.fileExists(atPath: path.path) else {
            Dbg.log("screenshot: отменён (status \(status))")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path.path, forType: .string)
        Signal.post("Скриншот сохранён", symbol: "camera.fill")
        Dbg.log("screenshot: \(path.path)")
    }

    /// Проверочная запись фиксированной длины (без интерактивного интерфейса).
    @discardableResult
    static func recordTest(seconds: Int) -> URL {
        let path = file("mov")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = recordingArguments(to:path,seconds:seconds)
        try? p.run()
        p.waitUntilExit()
        let ok = FileManager.default.fileExists(atPath: path.path)
        Dbg.log("record-test: \(path.path) существует=\(ok)")
        return path
    }

    static func recordingArguments(to url:URL,seconds:Int?=nil,
        systemAudio:Bool=Capture.systemAudioEnabled,microphone:Bool=Capture.microphoneEnabled,interactive:Bool=false)->[String] {
        var arguments=["-v"]
        if systemAudio {arguments.append("-A")}
        if microphone {arguments.append("-g")}
        if let seconds {arguments += ["-V",String(max(1,seconds))]}
        else {arguments += interactive ? ["-J","video"]:["-D","1"]}
        return arguments+["-x",url.path]
    }

    static var systemAudioEnabled:Bool {Preferences.shared.bool("recordSystemAudio")}
    static var microphoneEnabled:Bool {Preferences.shared.bool("recordMicrophone",fallback:false)}
    static func toggleSystemAudio() {
        guard !isRecording else {Signal.post("Звук меняется перед началом записи",symbol:"speaker.wave.2");return}
        Preferences.shared.set(!systemAudioEnabled,for:"recordSystemAudio")
        Signal.post(systemAudioEnabled ? "Системный звук: включён":"Системный звук: выключен",symbol:"speaker.wave.2")
    }
    static func toggleMicrophone() {
        guard !isRecording else {Signal.post("Микрофон меняется перед началом записи",symbol:"mic");return}
        if microphoneEnabled {Preferences.shared.set(false,for:"recordMicrophone");return}
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized:Preferences.shared.set(true,for:"recordMicrophone")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for:.audio) {granted in DispatchQueue.main.async {
                if granted {Preferences.shared.set(true,for:"recordMicrophone")}
                else {Signal.post("Доступ к микрофону не разрешён",symbol:"mic.slash")}
            }}
        default:
            let alert=NSAlert();alert.messageText="Нет доступа к микрофону"
            alert.informativeText="Включи доступ NotchDeck в настройках микрофона. Запись без микрофона продолжает работать."
            alert.addButton(withTitle:"Открыть настройки");alert.addButton(withTitle:"Отмена")
            if alert.runModal() == .alertFirstButtonReturn,let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {NSWorkspace.shared.open(url)}
        }
    }

    static let recordingChanged = Notification.Name("NotchDeck.recordingChanged")
    private static var recorder: ScreenRecording?
    private(set) static var recordingURL: URL?
    private(set) static var recordingStarted: Date?
    private(set) static var stopping = false
    static var isRecording: Bool { recorder != nil }
    static var elapsedText: String { formatElapsed(recorder?.duration ?? 0) }
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let n=max(0,Int(seconds)); return n>=3600 ? String(format:"%d:%02d:%02d",n/3600,n/60%60,n%60):String(format:"%02d:%02d",n/60,n%60)
    }
    private static func changed() {NotificationCenter.default.post(name:recordingChanged,object:nil)}

    /// Sound selection belongs to the launch flow; no capture starts on opening this dialog.
    @discardableResult
    static func toggleRecording() -> Bool {
        if isRecording {stopRecording();return false}
        let alert=NSAlert()
        alert.messageText="Запись экрана"
        alert.informativeText="Выбери экран и звук перед началом. Остановить запись можно красной кнопкой в чёлке."
        alert.addButton(withTitle:"Начать запись");alert.addButton(withTitle:"Отмена")
        let options=NSView(frame:NSRect(x:0,y:0,width:320,height:122))
        let mic=NSPopUpButton(frame:NSRect(x:0,y:43,width:320,height:28),pullsDown:false)
        mic.addItems(withTitles:["Без микрофона","Микрофон — системный вход"])
        let area=NSPopUpButton(frame:NSRect(x:0,y:85,width:320,height:28),pullsDown:false)
        area.addItems(withTitles:["Основной экран целиком","Выбрать область экрана"])
        area.setAccessibilityLabel("Область записи");options.addSubview(area)
        mic.selectItem(at:microphoneEnabled ? 1:0)
        mic.setAccessibilityLabel("Микрофон записи")
        let sound=NSButton(checkboxWithTitle:"Записывать звук приложений",target:nil,action:nil)
        sound.frame=NSRect(x:0,y:7,width:320,height:25);sound.state=systemAudioEnabled ? .on:.off
        options.addSubview(mic);options.addSubview(sound);alert.accessoryView=options
        NSApp.activate(ignoringOtherApps:true)
        guard alert.runModal() == .alertFirstButtonReturn else {return false}
        let wantsMic=mic.indexOfSelectedItem==1
        let interactive=area.indexOfSelectedItem==1
        Preferences.shared.set(sound.state == .on,for:"recordSystemAudio")
        if wantsMic && AVCaptureDevice.authorizationStatus(for:.audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for:.audio) {granted in DispatchQueue.main.async {
                guard granted else {Signal.post("Микрофон не разрешён · запись не начата",symbol:"mic.slash");return}
                Preferences.shared.set(true,for:"recordMicrophone");_ = startRecording(interactive:interactive)
            }}
            return false
        }
        if wantsMic && AVCaptureDevice.authorizationStatus(for:.audio) != .authorized {
            Signal.post("Нет доступа к микрофону · выбери запись без микрофона или разреши доступ в настройках",symbol:"mic.slash")
            return false
        }
        Preferences.shared.set(wantsMic,for:"recordMicrophone")
        return startRecording(interactive:interactive)
    }

    static func stopRecording() {
        guard let r=recorder,!stopping else{return}
        stopping=true;changed();r.stop()
        Dbg.log("record: stopping → \(recordingURL?.path ?? "-")")
    }

    @discardableResult
    static func startRecording(seconds:Int?=nil, test:Bool=false,interactive:Bool=false) -> Bool {
        guard !isRecording else{return false}
        guard CGPreflightScreenCaptureAccess() else {
            let alert=NSAlert();alert.messageText="Нужен доступ к записи экрана"
            alert.informativeText="Разреши NotchDeck в разделе «Конфиденциальность и безопасность → Запись экрана и системного звука», затем перезапусти приложение."
            alert.addButton(withTitle:"Открыть настройки");alert.addButton(withTitle:"Отмена")
            if alert.runModal() == .alertFirstButtonReturn,let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {NSWorkspace.shared.open(url)}
            return false
        }
        let region:CGRect?
        if interactive {guard let chosen=RecordingRegion.choose() else{return false};region=chosen} else {region=nil}
        let path=test ? URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("NotchDeck-record-test-\(stamp()).mov"):file("mov")
        let session=ScreenRecording(url:path)
        recorder=session;recordingURL=path;recordingStarted=nil;stopping=false
        session.onChange = { [weak session] in
            guard let session,recorder === session else{return}
            if session.started && recordingStarted == nil {recordingStarted=Date();Signal.post("Идёт запись экрана",symbol:"record.circle.fill")}
            changed()
        }
        session.onFinish = { [weak session] error in
            guard let session,recorder === session else{return}
            let size=(try? FileManager.default.attributesOfItem(atPath:path.path)[.size] as? NSNumber)?.intValue ?? 0
            recorder=nil;recordingStarted=nil;stopping=false;changed()
            Dbg.log("record: session finished bytes=\(size) error=\(error?.localizedDescription ?? "none") file=\(path.path)")
            Signal.post(error == nil && size>1024 ? "Запись сохранена":"Не удалось сохранить запись · \(error?.localizedDescription ?? "пустой файл")",symbol:error == nil ? "checkmark.circle":"exclamationmark.triangle")
        }
        session.start(systemAudio:systemAudioEnabled,microphone:test ? false:microphoneEnabled,rect:region,seconds:seconds)
        changed()
        Dbg.log("record: session preparing systemAudio=\(systemAudioEnabled) microphone=\(test ? false:microphoneEnabled) file=\(path.path)")
        return true
    }

}

// MARK: - Порог предупреждения о памяти
enum MemWarn {
    /// По умолчанию 85 %; ключ нужен для проверок (`defaults write NotchDeck.memWarnPercent 30`).
    static var threshold: Double {
        let v = UserDefaults.standard.double(forKey: "NotchDeck.memWarnPercent")
        return v > 0 ? v : 85
    }
}

// MARK: - Сигналы у чёлки
enum Signal {
    static let didPost = Notification.Name("NotchDeck.signal")

    static func post(_ text: String, symbol: String) {
        NotificationCenter.default.post(name: didPost, object: nil,
                                        userInfo: ["text": text, "symbol": symbol])
        Dbg.log("signal: \(text)")
    }
}
