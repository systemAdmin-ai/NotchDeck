import AppKit

// MARK: - Метрики раскладки
enum Layout {
    static let pad: CGFloat = 14
    static let tileW: CGFloat = 100
    static let tileH: CGFloat = 40
    static let gap: CGFloat = 6
    static let cols = 4
    static let actionW: CGFloat = 34
    static let appW: CGFloat = 40
    static let appH: CGFloat = 34
    static let mediaH: CGFloat = 34
    static let actionH: CGFloat = 30
    static let actionGap: CGFloat = 7
    static let rowGap: CGFloat = 6
    static let shelfH: CGFloat = 46
}

enum Fmt {
    static func speed(_ kb:Double)->String {
        let value=kb.isFinite ? max(0,kb):0
        let amount:Double,unit:String
        if value>=1_048_576 {amount=value/1_048_576;unit=L("ГБ/с")}
        else if value>=1024 {amount=value/1024;unit=L("МБ/с")}
        else if value>=1 {amount=value;unit=L("КБ/с")}
        else {amount=value*1024;unit=L("Б/с")}
        return String(format:amount>=100 || amount==0 ? "%.0f %@":"%.1f %@",amount,unit)
    }

    static func value(_ item: Item, _ s: MetricSnapshot) -> String {
        switch item {
        case .cpu: return String(format: "%.0f%%", s.cpu)
        case .ram: return String(format: "%.1f", s.ramUsed)
        case .temp: return s.temp.map { String(format: "%.0f°", $0) } ?? "—"
        case .battery: return s.battery.map { "\($0)%" } ?? "—"
        case .net: return s.networkReady ? "↓\(speed(s.down))":"…"
        case .disk: return String(format: L("%.0fГ"), s.diskFree)
        case .uptime: return s.uptime
        case .happStatus:return s.happStatus
        case .checkpointStatus:return s.checkpointStatus
        case .ip: return s.ip
        default: return ""
        }
    }

    static func sub(_ item: Item, _ s: MetricSnapshot) -> String {
        switch item {
        case .ram: return ""
        case .net: return s.networkReady ? "↑\(speed(s.up))":""
        case .battery: return s.charging ? L("заряд") : ""
        case .ip: return s.vpn ? "VPN" : ""
        default: return ""
        }
    }
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = PanelPalette.foreground) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = NSFont.systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.drawsBackground = false
    f.isBordered = false
    f.isEditable = false
    f.isSelectable = false
    f.lineBreakMode = .byTruncatingTail
    return f
}

private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
    let v = NSImageView()
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    v.contentTintColor = color
    v.imageScaling = .scaleProportionallyUpOrDown
    return v
}

/// Контейнер с системой координат «сверху вниз» (как у панели)
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Кнопка, принимающая первый клик (окно не становится key)
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        Dbg.log("button down '\(title)' at \(event.locationInWindow)")
        super.mouseDown(with: event)
    }
}

enum PanelPalette {
    static func isLight(_ appearance:NSAppearance)->Bool {
        switch Preferences.shared.panelStyle {
        case .light:return true
        case .auto:return appearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua
        default:return false
        }
    }
    static func gray(_ white:CGFloat,alpha:CGFloat)->NSColor {
        NSColor(name:nil) {appearance in
            NSColor(white:isLight(appearance) ? 1-white:white,alpha:alpha)
        }
    }
    static var foreground:NSColor {gray(1,alpha:1)}
    static var appearance:NSAppearance? {
        switch Preferences.shared.panelStyle {
        case .auto:return nil
        case .light:return NSAppearance(named:.aqua)
        default:return NSAppearance(named:.darkAqua)
        }
    }
}

// MARK: - Фон панели
// Скругление — через CALayer (maskedCorners), а не NSBezierPath: во flipped-вью дуги
// appendArc рисуются зеркально, и вместо скругления получается диагональный срез.
final class NotchBackgroundView:NSView {
    private let blur=NSVisualEffectView()
    private let tint=CAGradientLayer()
    private let tintHost=NSView()
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true
        layer?.cornerRadius=18
        layer?.cornerCurve = .continuous
        layer?.maskedCorners=[.layerMinXMinYCorner,.layerMaxXMinYCorner]
        layer?.masksToBounds=true
        blur.frame=bounds;blur.autoresizingMask=[.width,.height]
        blur.material = .hudWindow;blur.blendingMode = .behindWindow
        blur.state = .active
        addSubview(blur)
        tint.startPoint=CGPoint(x:0,y:1);tint.endPoint=CGPoint(x:1,y:0)
        tintHost.frame=bounds;tintHost.autoresizingMask=[.width,.height]
        tintHost.wantsLayer=true;tintHost.layer=tint
        addSubview(tintHost)
        applyStyle()
    }
    required init?(coder:NSCoder) {fatalError()}
    func applyStyle() {
        guard let layer else{return}
        let style=Preferences.shared.panelStyle
        appearance=PanelPalette.appearance;blur.appearance=PanelPalette.appearance
        blur.material = style == .auto || style == .light || style == .dark ? .popover:.hudWindow
        blur.isHidden = style == .graphite || style == .midnight
        layer.backgroundColor = NSColor.clear.cgColor
        layer.borderWidth = style == .neon ? 1.2:0.5
        layer.borderColor = PanelPalette.gray(1,alpha:0.18).cgColor
        switch style {
        case .auto:
            tint.colors=[NSColor.clear.cgColor,NSColor.clear.cgColor]
        case .light:
            tint.colors=[NSColor(white:1,alpha:0.18).cgColor,NSColor(white:0.96,alpha:0.24).cgColor]
        case .dark:
            tint.colors=[NSColor(white:0.08,alpha:0.20).cgColor,NSColor(white:0.02,alpha:0.30).cgColor]
        case .glass:
            tint.colors=[PanelPalette.gray(0.12,alpha:0.28).cgColor,PanelPalette.gray(0.04,alpha:0.4).cgColor]
        case .graphite:
            tint.colors=[PanelPalette.gray(0.17,alpha:0.98).cgColor,PanelPalette.gray(0.10,alpha:0.98).cgColor]
        case .midnight:
            tint.colors=[NSColor.black.cgColor,PanelPalette.gray(0.015,alpha:1).cgColor]
            layer.borderColor=PanelPalette.gray(1,alpha:0.07).cgColor
        case .aurora:
            tint.colors=[NSColor(srgbRed:0.12,green:0.25,blue:0.48,alpha:0.60).cgColor,
                         NSColor(srgbRed:0.25,green:0.12,blue:0.40,alpha:0.65).cgColor]
        case .neon:
            tint.colors=[PanelPalette.gray(0.03,alpha:0.80).cgColor,NSColor(srgbRed:0.03,green:0.13,blue:0.15,alpha:0.85).cgColor]
            layer.borderColor=NSColor(srgbRed:0.30,green:0.94,blue:0.85,alpha:0.8).cgColor
        }
        needsLayout=true
    }
    override func layout() {
        super.layout()
        CATransaction.begin();CATransaction.setDisableActions(true)
        tint.frame=bounds;CATransaction.commit()
    }
}

// MARK: - Базовый «нажимаемый» вид
class PressableView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    private var pressTimer: Timer?
    private var longFired = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        alphaValue = 0.85
    }

    override func mouseExited(with event: NSEvent) {
        alphaValue = 1
    }

    override func mouseDown(with event: NSEvent) {
        Dbg.log("press hit \(type(of: self)) at \(event.locationInWindow)")
        longFired = false
        let t = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.longFired = true
            self.onLongPress?()
        }
        RunLoop.main.add(t, forMode: .common)
        pressTimer = t
    }

    override func mouseUp(with event: NSEvent) {
        Dbg.log("press up \(type(of: self)) long=\(longFired)")
        pressTimer?.invalidate()
        pressTimer = nil
        guard !longFired, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onTap?()
    }
}

// MARK: - Плитка индикатора
final class TileView: PressableView {
    let item: Item
    private let icon: NSImageView
    private let titleLabel: NSTextField
    private let subLabel: NSTextField
    private let valueLabel: NSTextField
    private let badge: NSImageView

    init(item: Item) {
        self.item = item
        icon = symbol(item.symbol, size: 9, color: PanelPalette.gray(0.72,alpha:1))
        titleLabel = label(item.title, size: 8.5, weight: .medium, color: PanelPalette.gray(0.80,alpha:1))
        subLabel = label("", size: 8, color: PanelPalette.gray(0.58,alpha:1))
        valueLabel = label("—", size: 13, weight: .semibold, color: PanelPalette.gray(0.96,alpha:1))
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        badge = symbol("minus.circle.fill", size: 12, color: .systemRed)
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.tileW, height: Layout.tileH))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = PanelPalette.gray(1,alpha:0.07).cgColor
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(subLabel)
        addSubview(valueLabel)
        addSubview(badge)
        badge.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setEditing(_ editing: Bool) {
        badge.isHidden = !editing
        layer?.backgroundColor = NSColor(white: 1, alpha: editing ? 0.05 : 0.07).cgColor
    }

    func update(_ s: MetricSnapshot) {
        valueLabel.stringValue = Fmt.value(item, s)
        subLabel.stringValue = Fmt.sub(item, s)
        applyAccent(accentColor(s))
    }

    /// Акцент ведёт всю плитку целиком: иконка, подпись и значение — один цвет.
    /// Для остальных метрик акцента нет, они остаются нейтральными.
    /// Текущий акцент — нужен для автопроверок раскраски.
    private(set) var currentAccent: NSColor?

    private func applyAccent(_ color: NSColor?) {
        currentAccent = color
        if let color {
            let c = PanelPalette.isLight(effectiveAppearance) ? (color.blended(withFraction:0.55,of:.black) ?? color):color
            icon.contentTintColor = c.withAlphaComponent(0.95)
            titleLabel.textColor = c
            valueLabel.textColor = c
            subLabel.textColor = c.withAlphaComponent(0.62)
        } else {
            icon.contentTintColor = PanelPalette.gray(0.72,alpha:1)
            titleLabel.textColor = PanelPalette.gray(0.80,alpha:1)
            valueLabel.textColor = PanelPalette.gray(0.96,alpha:1)
            subLabel.textColor = PanelPalette.gray(0.58,alpha:1)
        }
    }

    /// Температура — как в физике: холодная синяя, горячая цветом огня. RAM — от занятости.
    private func accentColor(_ s: MetricSnapshot) -> NSColor? {
        switch item {
        case .temp:
            let t = s.temp ?? 0
            switch t {
            case ..<45:  return NSColor(srgbRed: 0.47, green: 0.72, blue: 1.00, alpha: 1) // синий
            case ..<60:  return NSColor(srgbRed: 0.62, green: 0.85, blue: 0.98, alpha: 1) // голубой
            case ..<72:  return NSColor(srgbRed: 1.00, green: 0.84, blue: 0.50, alpha: 1) // тёплый жёлтый
            case ..<85:  return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.28, alpha: 1) // оранжевый
            default:     return NSColor(srgbRed: 1.00, green: 0.36, blue: 0.30, alpha: 1) // огонь
            }
        case .ram:
            guard s.ramTotal > 0 else { return nil }
            let pct = s.ramUsed / s.ramTotal * 100
            return pct >= MemWarn.threshold
                ? NSColor(srgbRed: 1.00, green: 0.62, blue: 0.28, alpha: 1)
                : NSColor(srgbRed: 0.56, green: 0.86, blue: 0.78, alpha: 1)
        default:
            return nil
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        icon.frame = NSRect(x: 7, y: 5, width: 10, height: 10)
        titleLabel.frame = NSRect(x: 19, y: 3, width: w - 26, height: 12)
        subLabel.alignment = .right
        subLabel.frame = NSRect(x: w - 45, y: 19, width: 38, height: 12)
        valueLabel.frame = NSRect(x: 7, y: 17, width: subLabel.stringValue.isEmpty ? w-14:w-55, height: 17)
        if item == .happStatus || item == .checkpointStatus {valueLabel.font = .systemFont(ofSize:11,weight:.semibold)}
        if item == .net {
            valueLabel.font = .monospacedDigitSystemFont(ofSize:10.5,weight:.semibold)
            valueLabel.frame=NSRect(x:7,y:15,width:w-14,height:13)
            subLabel.font = .monospacedDigitSystemFont(ofSize:9.5,weight:.regular)
            subLabel.alignment = .left
            subLabel.frame=NSRect(x:7,y:28,width:w-14,height:12)
        }
        badge.frame = NSRect(x: w - 11, y: -2, width: 13, height: 13)
    }
}

// MARK: - Кнопка действия
final class ActionView: PressableView {
    let item: Item
    private let icon: NSImageView
    private let recordingTime = label("", size: 7, color: PanelPalette.foreground)
    private var recordingObserver: NSObjectProtocol?

    init(item: Item) {
        self.item = item
        icon = symbol(item.symbol, size: 13, color: PanelPalette.foreground)
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.actionW, height: Layout.actionH))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = PanelPalette.gray(1,alpha:0.09).cgColor
        addSubview(icon)
        if item == .record {
            setAccessibilityElement(true);setAccessibilityRole(.button)
            recordingTime.alignment = .center
            recordingTime.font = .monospacedDigitSystemFont(ofSize:7,weight:.semibold)
            addSubview(recordingTime)
            recordingObserver=NotificationCenter.default.addObserver(forName:Capture.recordingChanged,object:nil,queue:.main) {[weak self] _ in self?.updateRecording()}
            updateRecording()
        }
        if item != .record {toolTip=item.title}
        if item == .recordMic {toolTip=L("Микрофон записи: %@", Capture.microphoneEnabled ? L("вкл") : L("выкл")) + L(" · переключается перед записью")}
        if item == .recordAudio {toolTip=L("Системный звук записи: %@", Capture.systemAudioEnabled ? L("вкл") : L("выкл")) + L(" · переключается перед записью")}
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {if let recordingObserver {NotificationCenter.default.removeObserver(recordingObserver)}}
    func updateRecording() {
        guard item == .record else{return}
        let active=Capture.isRecording
        icon.image=NSImage(systemSymbolName:active ? "stop.fill":"record.circle",accessibilityDescription:active ? L("Остановить запись"):L("Начать запись"))
        icon.contentTintColor=active ? .systemRed:PanelPalette.foreground
        recordingTime.isHidden = !active
        recordingTime.stringValue=Capture.stopping ? L("Стоп…"):(Capture.recordingStarted == nil ? L("Пуск…"):Capture.elapsedText)
        toolTip=active ? (Capture.recordingStarted == nil ? L("Подготовка записи · нажми, чтобы отменить"):L("Идёт запись экрана · %@ · нажми, чтобы остановить", Capture.elapsedText)):L("Запись экрана · выбрать микрофон и звук")
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(active ? recordingTime.stringValue:L("Не идёт"))
        layer?.backgroundColor=active ? NSColor.systemRed.withAlphaComponent(0.22).cgColor:PanelPalette.gray(1,alpha:0.09).cgColor
        needsLayout=true
    }

    func setEditing(_ editing: Bool) {
        if item == .record {updateRecording();return}
        let enabled=(item == .recordMic && Capture.microphoneEnabled) || (item == .recordAudio && Capture.systemAudioEnabled)
        layer?.backgroundColor = enabled && !editing ? NSColor(srgbRed:0.12,green:0.45,blue:0.34,alpha:0.6).cgColor:NSColor(white: 1, alpha: editing ? 0.05 : 0.09).cgColor
    }

    override func layout() {
        super.layout()
        if item == .record && Capture.isRecording {
            icon.frame=NSRect(x:(bounds.width-11)/2,y:3,width:11,height:11)
            recordingTime.frame=NSRect(x:1,y:17,width:bounds.width-2,height:11)
        } else {icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)}
    }
}

// MARK: - Кнопка запуска приложения
final class AppView: PressableView {
    let item: Item
    private let icon = NSImageView()

    init(item: Item) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.appW, height: Layout.appH))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = PanelPalette.gray(1,alpha:0.09).cgColor
        icon.image = Launcher.icon(item: item, size: 24)
        icon.imageScaling = .scaleProportionallyUpOrDown
        toolTip = item.title
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setEditing(_ editing: Bool) {
        layer?.backgroundColor = NSColor(white: 1, alpha: editing ? 0.05 : 0.09).cgColor
        alphaValue = editing ? 0.55 : 1
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 24) / 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
    }
}

// MARK: - Медиабар («сейчас играет»)
final class MiniButton: PressableView {
    private let icon = NSImageView()

    init(symbol name: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 24))
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        setSymbol(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = PanelPalette.gray(0.95,alpha:1)
    }

    override func layout() {
        super.layout()
        icon.frame = bounds
    }
}

final class MediaBarView: NSView {
    override var isFlipped: Bool { true }

    var onPrev: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private let art = NSImageView()
    private let titleLabel = label("", size: 11.5, weight: .semibold, color: PanelPalette.gray(0.96,alpha:1))
    private let artistLabel = label("", size: 9, color: PanelPalette.gray(0.60,alpha:1))
    private let track = NSView()
    private let fill = NSView()
    private let prevBtn = MiniButton(symbol: "backward.fill")
    private let playBtn = MiniButton(symbol: "play.fill")
    private let nextBtn = MiniButton(symbol: "forward.fill")
    private var progress: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 432, height: Layout.mediaH))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = PanelPalette.gray(1,alpha:0.07).cgColor
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 5
        art.layer?.masksToBounds = true
        addSubview(art)
        addSubview(titleLabel)
        addSubview(artistLabel)
        track.wantsLayer = true
        track.layer?.cornerRadius = 1
        track.layer?.backgroundColor = PanelPalette.gray(1,alpha:0.14).cgColor
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 1
        fill.layer?.backgroundColor = PanelPalette.gray(0.95,alpha:0.85).cgColor
        track.addSubview(fill)
        addSubview(track)
        prevBtn.onTap = { [weak self] in self?.onPrev?() }
        playBtn.onTap = { [weak self] in self?.onToggle?() }
        nextBtn.onTap = { [weak self] in self?.onNext?() }
        addSubview(prevBtn)
        addSubview(playBtn)
        addSubview(nextBtn)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyPalette() {
        layer?.backgroundColor=PanelPalette.gray(1,alpha:0.07).cgColor
        track.layer?.backgroundColor=PanelPalette.gray(1,alpha:0.14).cgColor
        fill.layer?.backgroundColor=PanelPalette.gray(0.95,alpha:0.85).cgColor
    }
    var titleText: String { titleLabel.stringValue }

    /// Тап по полосе прогресса — перемотка на долю трека.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard track.frame.insetBy(dx: -4, dy: -8).contains(p) else { return }
        let frac = (p.x - track.frame.minX) / max(1, track.frame.width)
        onSeek?(Double(max(0, min(1, frac))))
    }

    func update(_ np: NowPlaying) {
        titleLabel.stringValue = np.title
        artistLabel.stringValue = np.artist.isEmpty ? np.source : np.artist
        art.image = np.artwork
        if art.image == nil,let bundle=np.sourceBundleID,
           let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) {
            art.image=NSWorkspace.shared.icon(forFile:url.path)
        }
        if art.image == nil {art.image=NSImage(systemSymbolName:"music.note",accessibilityDescription:L("Обложка недоступна"))}
        playBtn.setSymbol(np.playing ? "pause.fill" : "play.fill")
        progress = np.progress
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let topY = (h - 24) / 2 - 1
        art.frame = NSRect(x: 5, y: topY, width: 24, height: 24)
        let bw: CGFloat = 22
        let right = bounds.width - 5
        nextBtn.frame = NSRect(x: right - bw, y: topY, width: bw, height: 24)
        playBtn.frame = NSRect(x: right - bw * 2 - 2, y: topY, width: bw, height: 24)
        prevBtn.frame = NSRect(x: right - bw * 3 - 4, y: topY, width: bw, height: 24)
        let textX: CGFloat = 35
        let textW = max(0, prevBtn.frame.minX - textX - 8)
        titleLabel.frame = NSRect(x: textX, y: 6, width: textW, height: 13)
        artistLabel.frame = NSRect(x: textX, y: 18, width: textW, height: 11)
        track.frame = NSRect(x: textX, y: h - 4, width: textW, height: 2)
        fill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * progress, height: 2)
    }
}

// MARK: - Содержимое панели
final class PanelContentView: NSView {
    override var isFlipped: Bool { true }

    private let bg = NotchBackgroundView()
    private let profileHeader=ProfileHeaderView(frame:.zero)
    private let profileRowHeight:CGFloat=34
    private var tiles: [TileView] = []
    private var actions: [ActionView] = []
    private var apps: [AppView] = []
    private var customApps: [FirstMouseButton] = []
    var mediaOnly = false { didSet { needsLayout = true } }
    private var layoutWidth:CGFloat {Preferences.shared.panelWidth}
    private var metricColumns:Int {Preferences.shared.compactPanel ? 3:4}
    private var shortcutColumns:Int {max(1,Int((layoutWidth-Layout.pad*2+Layout.actionGap)/(Layout.appW+Layout.actionGap)))}
    private var shortcutCount: Int { actions.count+apps.count+tools.count+customApps.count }
    private var shortcutRows: Int { Int(ceil(Double(shortcutCount)/Double(shortcutColumns))) }
    private var tools: [ActionView] = []
    private let shelf = FlippedView()
    let mediaBar = MediaBarView()
    private let shelfTitle = label(L("Скрытые — тапни, чтобы вернуть"), size: 9, color: PanelPalette.gray(0.62,alpha:1))
    private let doneButton = FirstMouseButton(title: L("Готово"), target: nil, action: nil)
    private var shelfViews: [NSView] = []

    var notchHeight: CGFloat = 32
    var onHideTile: ((Item) -> Void)?
    var onTapTile: ((Item) -> Void)?
    var onTapAction: ((Item) -> Void)?
    var onMediaAction: ((MediaCommand) -> Void)?
    var onLongPress: (() -> Void)?
    var onDone: (() -> Void)?

    var editing = false {
        didSet { rebuild() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(bg)
        addSubview(profileHeader)
        shelf.isHidden = true
        doneButton.isBordered = false
        doneButton.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        doneButton.contentTintColor = PanelPalette.gray(1,alpha:0.85)
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        shelf.addSubview(shelfTitle)
        shelf.addSubview(doneButton)
        mediaBar.isHidden = true
        mediaBar.onPrev = { [weak self] in self?.onMediaAction?(.previous) }
        mediaBar.onToggle = { [weak self] in self?.onMediaAction?(.toggle) }
        mediaBar.onNext = { [weak self] in self?.onMediaAction?(.next) }
        addSubview(mediaBar)
        addSubview(shelf)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func doneTapped() {
        Dbg.log("done tapped")
        onDone?()
    }

    func contentHeight()->CGFloat {
        if mediaOnly {return notchHeight+Layout.mediaH+18}
        // Compute from the destination width, never the collapsed 181pt window.
        // The same cursor is used by layout(), so no empty rows can be reserved.
        var bottom=notchHeight+2+profileRowHeight
        if !tiles.isEmpty {
            let rows=Int(ceil(Double(tiles.count)/Double(metricColumns)))
            bottom += CGFloat(rows)*Layout.tileH+CGFloat(rows-1)*Layout.gap+Layout.rowGap
        }
        if !mediaBar.isHidden {bottom += Layout.mediaH+Layout.rowGap}
        if shortcutCount>0 {bottom += CGFloat(shortcutRows)*Layout.appH+CGFloat(shortcutRows-1)*Layout.actionGap}
        if editing {bottom += 8+Layout.shelfH}
        return bottom+12
    }

    func applyAppearance() {
        appearance=PanelPalette.appearance
        bg.applyStyle();mediaBar.applyPalette();profileHeader.reload();rebuild();needsLayout=true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Dynamic text colors update automatically; layer colors need rebuilding.
        DispatchQueue.main.async {[weak self] in self?.bg.applyStyle();self?.mediaBar.applyPalette();self?.rebuild()}
    }

    func rebuild() {
        tiles.forEach { $0.removeFromSuperview() }
        actions.forEach { $0.removeFromSuperview() }
        apps.forEach { $0.removeFromSuperview() }
        customApps.forEach { $0.removeFromSuperview() }
        customApps.removeAll()
        tools.forEach { $0.removeFromSuperview() }
        shelfViews.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
        actions.removeAll()
        apps.removeAll()
        tools.removeAll()
        shelfViews.removeAll()

        let cfg = Config.shared
        for item in cfg.visible(Item.metrics) {
            let t = TileView(item: item)
            t.setEditing(editing)
            t.onTap = { [weak self] in
                guard let self else { return }
                if self.editing { self.onHideTile?(item) } else { self.onTapTile?(item) }
            }
            t.onLongPress = { [weak self] in self?.onLongPress?() }
            addSubview(t)
            tiles.append(t)
        }
        for item in cfg.visible(Item.actions) where item.isTool {
            let a = ActionView(item: item)
            a.setEditing(editing)
            a.onTap = { [weak self] in
                guard let self else { return }
                if self.editing { self.onHideTile?(item) } else { self.onTapAction?(item) }
            }
            a.onLongPress = { [weak self] in self?.onLongPress?() }
            addSubview(a)
            tools.append(a)
        }
        for item in cfg.visible(Item.actions) where !item.isApp && !item.isTool {
            let a = ActionView(item: item)
            a.setEditing(editing)
            a.onTap = { [weak self] in
                guard let self else { return }
                if self.editing { self.onHideTile?(item) } else { self.onTapAction?(item) }
            }
            a.onLongPress = { [weak self] in self?.onLongPress?() }
            addSubview(a)
            actions.append(a)
        }
        for item in cfg.visible(Item.actions) where item.isApp {
            let a = AppView(item: item)
            a.setEditing(editing)
            a.onTap = { [weak self] in
                guard let self else { return }
                if self.editing { self.onHideTile?(item) } else { self.onTapAction?(item) }
            }
            a.onLongPress = { [weak self] in self?.onLongPress?() }
            addSubview(a)
            apps.append(a)
        }

        for shortcut in Preferences.shared.applications {
            let button = FirstMouseButton(title: "", target: self, action: #selector(customAppTapped(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(shortcut.id)
            button.image = NSWorkspace.shared.icon(forFile: shortcut.path)
            button.image?.size = NSSize(width:24,height:24)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 10
            button.layer?.backgroundColor = PanelPalette.gray(1,alpha:0.09).cgColor
            button.toolTip = shortcut.name + (FileManager.default.fileExists(atPath:shortcut.path) ? "" : L(" — приложение перемещено или удалено"))
            addSubview(button);customApps.append(button)
        }

        shelf.isHidden = !editing
        if editing {
            let hiddenItems = Item.allCases.filter { cfg.hidden.contains($0.rawValue) }
            var x: CGFloat = 0
            for item in hiddenItems {
                let b = FirstMouseButton(title: "\(item.title)", target: self, action: #selector(unhideTapped(_:)))
                b.identifier = NSUserInterfaceItemIdentifier(item.rawValue)
                b.isBordered = true
                b.bezelStyle = .inline
                b.font = NSFont.systemFont(ofSize: 9)
                b.contentTintColor = PanelPalette.foreground
                b.sizeToFit()
                b.setFrameSize(NSSize(width: max(46, b.frame.width + 12), height: 22))
                b.frame.origin = NSPoint(x: x, y: 20)
                x += b.frame.width + 6
                shelf.addSubview(b)
                shelfViews.append(b)
            }
            if hiddenItems.isEmpty {
                let none = label(L("все плитки на месте"), size: 9, color: PanelPalette.gray(0.58,alpha:1))
                none.frame = NSRect(x: 0, y: 24, width: 160, height: 12)
                shelf.addSubview(none)
                shelfViews.append(none)
            }
        }
        needsLayout = true
    }

    @objc private func customAppTapped(_ sender:NSButton) {
        guard let id=sender.identifier?.rawValue,
              let app=Preferences.shared.applications.first(where:{$0.id==id}) else{return}
        if editing { Preferences.shared.removeApplication(id);return }
        NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:app.path),configuration:NSWorkspace.OpenConfiguration()) { _,error in
            if let error {Dbg.log("launch: \(error.localizedDescription)")}
        }
    }

    @objc private func unhideTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let item = Item(rawValue: raw) else { return }
        Config.shared.unhide(item)
    }

    var mediaText: String { mediaBar.isHidden ? "" : mediaBar.titleText }

    func dumpLayout() -> String {
        var out = "panel bounds=\(bounds) высота контента=\(contentHeight()) плиток=\(tiles.count) кнопок=\(actions.count) приложений=\(apps.count) инструментов=\(tools.count) медиа=\(mediaBar.isHidden ? "нет" : mediaBar.titleText) editing=\(editing)\n"
        for v in subviews where !(v is NotchBackgroundView) {
            let name: String
            if let t = v as? TileView { name = "tile:\(t.item.rawValue)" }
            else if let m = v as? MediaBarView { name = "media:'\(m.titleText)'" }
            else if let a = v as? ActionView { name = "action:\(a.item.rawValue)" }
            else if let a = v as? AppView { name = "app:\(a.item.rawValue)" }
            else { name = String(describing: type(of: v)) }
            out += "  \(name) frame=\(v.frame) hidden=\(v.isHidden)\n"
            if let sh = v as? NSView, !(v is NSImageView) {
                for c in sh.subviews {
                    out += "     · \(type(of: c)) frame=\(c.frame) hidden=\(c.isHidden)\n"
                }
            }
        }
        return out
    }


    func setMedia(_ np: NowPlaying?) {
        let had = !mediaBar.isHidden
        mediaBar.isHidden = (np == nil || (np?.playing != true && !mediaOnly))
        if let np { mediaBar.update(np) }
        if had != !mediaBar.isHidden { needsLayout = true }
    }

    func update(_ s: MetricSnapshot) {
        for t in tiles {
            t.update(s)
            if t.item == .net {t.toolTip=L("Текущий трафик: ↓ %@ · ↑ %@", Fmt.speed(s.down), Fmt.speed(s.up))}
        }
    }

    override func layout() {
        super.layout()
        bg.frame = bounds
        let tileWidth=(layoutWidth-Layout.pad*2-CGFloat(metricColumns-1)*Layout.gap)/CGFloat(metricColumns)
        profileHeader.frame=NSRect(x:Layout.pad,y:notchHeight+2,width:bounds.width-Layout.pad*2,height:28)
        profileHeader.isHidden=mediaOnly
        var y = notchHeight + 2 + profileRowHeight
        var col = 0
        var rowTop = y
        for t in tiles {
            if col == metricColumns { col = 0; y += Layout.tileH + Layout.gap }
            t.frame = NSRect(x: Layout.pad + CGFloat(col) * (tileWidth + Layout.gap), y: y, width: tileWidth, height: Layout.tileH)
            col += 1
        }
        if !tiles.isEmpty { rowTop = y + Layout.tileH + Layout.rowGap }
        if !mediaBar.isHidden {
            mediaBar.frame = NSRect(x: Layout.pad, y: rowTop, width: bounds.width - Layout.pad * 2, height: Layout.mediaH)
            rowTop += Layout.mediaH + Layout.rowGap
        }
        let shortcuts: [NSView] = apps + customApps + tools + actions
        for (index,view) in shortcuts.enumerated() {
            view.frame=NSRect(x:Layout.pad+CGFloat(index%shortcutColumns)*(Layout.appW+Layout.actionGap),
                y:rowTop+CGFloat(index/shortcutColumns)*(Layout.appH+Layout.actionGap),width:Layout.appW,height:Layout.appH)
        }
        let shelfY = rowTop + CGFloat(shortcutRows)*(Layout.appH+Layout.actionGap) + 8
        for view in tiles {view.isHidden=mediaOnly}
        for view in shortcuts {view.isHidden=mediaOnly}
        shelf.isHidden = mediaOnly || !editing
        if mediaOnly { mediaBar.frame=NSRect(x:Layout.pad,y:notchHeight+2,width:bounds.width-Layout.pad*2,height:Layout.mediaH) }
        shelf.frame = NSRect(x: Layout.pad, y: shelfY, width: bounds.width - Layout.pad * 2, height: Layout.shelfH)
        shelfTitle.frame = NSRect(x: 0, y: 2, width: shelf.frame.width - 60, height: 12)
        doneButton.frame = NSRect(x: shelf.frame.width - 56, y: 0, width: 56, height: 16)
    }
}

// MARK: - HUD
final class HUDContentView: NSView {
    private let icon = NSImageView()
    private let track = NSView()
    private let fill = NSView()
    private let valueLabel = label("0%", size: 11, weight: .semibold)
    private var value: CGFloat = 0
    private var muted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 0.96).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = PanelPalette.gray(1,alpha:0.08).cgColor
        for v in [track, fill] {
            v.wantsLayer = true
            addSubview(v)
        }
        track.layer?.cornerRadius = 2.5
        track.layer?.backgroundColor = PanelPalette.gray(1,alpha:0.15).cgColor
        fill.layer?.cornerRadius = 2.5
        fill.layer?.backgroundColor = PanelPalette.gray(0.95,alpha:1).cgColor
        addSubview(icon)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbolName: String, value: Float, muted: Bool) {
        self.value = CGFloat(max(0, min(1, value)))
        self.muted = muted
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = PanelPalette.foreground
        valueLabel.stringValue = muted ? L("выкл") : "\(Int((self.value * 100).rounded()))%"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: 10, width: 18, height: 15)
        track.frame = NSRect(x: 38, y: 14.5, width: 110, height: 5)
        fill.frame = NSRect(x: 38, y: 14.5, width: max(3, 110 * (muted ? 0 : value)), height: 5)
        fill.layer?.backgroundColor = (muted ? NSColor.gray : PanelPalette.gray(0.95,alpha:1)).cgColor
        valueLabel.frame = NSRect(x: 156, y: 9, width: 42, height: 16)
    }
}

// MARK: - Настройки
final class SettingsContentView: NSView {
    private let hudSwitch: NSButton
    private let loginSwitch: NSButton
    private let captureSwitch: NSButton
    private let onLogin: (Bool) -> Void

    init(onLogin: @escaping (Bool) -> Void) {
        self.onLogin = onLogin
        let d = UserDefaults.standard
        hudSwitch = NSButton(checkboxWithTitle: L("HUD яркости и громкости"), target: nil, action: nil)
        hudSwitch.state = (d.object(forKey: "NotchDeck.hudEnabled") == nil || d.bool(forKey: "NotchDeck.hudEnabled")) ? .on : .off
        captureSwitch = NSButton(checkboxWithTitle: L("Показывать в скриншотах"), target: nil, action: nil)
        captureSwitch.state = (d.object(forKey: "NotchDeck.showInCapture") == nil || d.bool(forKey: "NotchDeck.showInCapture")) ? .on : .off
        loginSwitch = NSButton(checkboxWithTitle: L("Запускать при входе"), target: nil, action: nil)
        loginSwitch.state = LaunchAtLogin.isEnabled ? .on : .off
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 200))
        let title = label("NotchDeck", size: 15, weight: .semibold, color: .labelColor)
        title.frame = NSRect(x: 16, y: 156, width: 200, height: 20)
        addSubview(title)
        hudSwitch.frame = NSRect(x: 16, y: 120, width: 300, height: 20)
        loginSwitch.frame = NSRect(x: 16, y: 92, width: 300, height: 20)
        captureSwitch.frame = NSRect(x: 16, y: 64, width: 300, height: 20)
        for b in [hudSwitch, loginSwitch, captureSwitch] {
            b.font = NSFont.systemFont(ofSize: 12)
            b.target = self
            b.action = #selector(toggled(_:))
            addSubview(b)
        }
        let reset = NSButton(title: L("Вернуть все плитки"), target: self, action: #selector(resetTiles))
        reset.frame = NSRect(x: 16, y: 20, width: 160, height: 24)
        reset.bezelStyle = .rounded
        addSubview(reset)
        let quit = NSButton(title: L("Выход"), target: self, action: #selector(quitApp))
        quit.frame = NSRect(x: 246, y: 20, width: 70, height: 24)
        quit.bezelStyle = .rounded
        addSubview(quit)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled(_ sender: NSButton) {
        let d = UserDefaults.standard
        switch sender {
        case hudSwitch:
            d.set(sender.state == .on, forKey: "NotchDeck.hudEnabled")
        case captureSwitch:
            d.set(sender.state == .on, forKey: "NotchDeck.showInCapture")
            NotificationCenter.default.post(name: .init("NotchDeck.sharingChanged"), object: nil)
        case loginSwitch:
            onLogin(sender.state == .on)
        default:
            break
        }
    }

    @objc private func resetTiles() { Config.shared.resetAll() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Пилюля-сигнал
final class SignalContentView: NSVisualEffectView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // полупрозрачное стекло вместо плотной чёрной плашки
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        layer?.backgroundColor = PanelPalette.gray(0.10,alpha:0.35).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = PanelPalette.gray(1,alpha:0.14).cgColor
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = PanelPalette.gray(0.95,alpha:1)
        label.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = PanelPalette.gray(0.97,alpha:1)
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func measure(_ text: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]
        let w = (text as NSString).size(withAttributes: attrs).width
        return min(340, max(104, ceil(w) + 52))
    }

    func set(symbol: String, text: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        label.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: (bounds.height - 14) / 2, width: 15, height: 14)
        label.frame = NSRect(x: 33, y: (bounds.height - 15) / 2, width: bounds.width - 45, height: 15)
    }
}

// MARK: - «Крыло» чёлки для яркости и громкости
/// Тёмная плашка, растущая влево от чёлки: иконка слева, полоса в середине, значение справа.
final class LevelWingView: NSView {
    private let icon = NSImageView()
    private let pct = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var progress: CGFloat = 0

    static let width: CGFloat = 132

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = PanelPalette.gray(0.97,alpha:1)

        pct.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        pct.textColor = PanelPalette.gray(0.98,alpha:1)
        pct.alignment = .right

        track.wantsLayer = true
        track.layer?.cornerRadius = 2
        track.layer?.backgroundColor = PanelPalette.gray(1,alpha:0.20).cgColor
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 2
        fill.layer?.backgroundColor = PanelPalette.gray(1,alpha:0.95).cgColor

        addSubview(icon)
        addSubview(pct)
        addSubview(track)
        track.addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Тёмный фон чёлки: скругление только снизу, сверху плашка сливается с рамкой экрана.
    override func draw(_ dirtyRect: NSRect) {
        let r: CGFloat = 11
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - r))
        path.appendArc(withCenter: NSPoint(x: bounds.maxX - r, y: bounds.maxY - r), radius: r,
                       startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: bounds.minX + r, y: bounds.maxY))
        path.appendArc(withCenter: NSPoint(x: bounds.minX + r, y: bounds.maxY - r), radius: r,
                       startAngle: 90, endAngle: 180)
        path.close()
        NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 0.97).setFill()
        path.fill()
    }

    func set(kind: LevelKind, value v: Float, muted: Bool) {
        let symbol: String
        switch kind {
        case .brightness:
            symbol = v > 0.55 ? "sun.max.fill" : (v > 0.2 ? "sun.min.fill" : "sun.min")
        case .volume:
            symbol = muted || v <= 0.001 ? "speaker.slash.fill"
                : (v > 0.55 ? "speaker.wave.3.fill" : (v > 0.2 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"))
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        pct.stringValue = muted ? L("выкл") : String(format: "%.0f%%", v * 100)
        progress = CGFloat(max(0, min(1, muted ? 0 : v)))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 14) / 2, width: 15, height: 14)
        pct.frame = NSRect(x: bounds.width - 52, y: (h - 14) / 2, width: 40, height: 14)
        let trackX: CGFloat = 33
        let trackW = bounds.width - trackX - 60
        track.frame = NSRect(x: trackX, y: (h - 4) / 2, width: max(20, trackW), height: 4)
        fill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * progress, height: 4)
    }
}
