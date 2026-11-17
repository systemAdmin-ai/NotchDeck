import AppKit
import ServiceManagement

// MARK: - Отладочный лог (включается defaults write com.notchdeck.app NotchDeck.debugLog -bool true)
enum Dbg {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "NotchDeck.debugLog") }

    static func log(_ message: String) {
        guard enabled else { return }
        NSLog("NotchDeck %@", message)
        let path = "/tmp/notchdeck-debug.log"
        let line = "\(Date()) \(message)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Геометрия чёлки
struct Geometry {
    let screen: NSScreen
    let top: CGFloat
    let notchHeight: CGFloat
    let notchWidth: CGFloat
    let notchRect: CGRect
    let centerX: CGFloat

    static func measure(screen: NSScreen = NSScreen.screens.first ?? NSScreen.main!) -> Geometry {
        let top = screen.frame.maxY
        let h = max(screen.safeAreaInsets.top, 24)
        var width: CGFloat = 190
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, r.minX > l.maxX {
            width = r.minX - l.maxX
        }
        let centerX: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            centerX = (left.maxX + right.minX) / 2
        } else {
            // No physical notch: use a compact virtual notch at the display centre.
            centerX = screen.frame.midX
        }
        let rect = CGRect(x: centerX - width / 2, y: top - h, width: width, height: h)
        return Geometry(screen: screen, top: top, notchHeight: h, notchWidth: width,
                        notchRect: rect, centerX: centerX)
    }

    var collapsedFrame: CGRect {
        CGRect(x: notchRect.minX - 1, y: top - notchHeight, width: notchWidth + 2, height: notchHeight)
    }

    func expandedFrame(height: CGFloat) -> CGRect {
        let width:CGFloat=Preferences.shared.panelWidth
        return CGRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }
}

// MARK: - Модель (без Combine: обновление через замыкания)
final class PanelModel {
    var expanded = false
    var nowPlaying: NowPlaying?
    var editMode = false
    var hudAllowed = true
    var snapshot = MetricSnapshot()
    var onUpdate: ((MetricSnapshot) -> Void)?
    var onEditChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var ticks = 0

    func startRefresh() {
        guard timer == nil else { return }
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopRefresh() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        snapshot = Metrics.shared.snapshot()
        ticks += 1
        if Dbg.enabled && (ticks <= 2 || ticks % 30 == 0) {
            NSLog("NotchDeck metric tick #\(ticks): \(Metrics.shared.dump())")
        }
        onUpdate?(snapshot)
    }

    func enterEdit() {
        guard !editMode else { return }
        editMode = true
        onEditChange?(true)
    }

    func exitEdit() {
        guard editMode else { return }
        editMode = false
        onEditChange?(false)
    }

    func perform(_ item: Item) {
        if item.isApp {
            Launcher.open(item: item)
        } else {
            switch item {
            case .sleep: Power.sleepDisplay()
            case .keyboardBridge:KeyboardMode.shared.toggle()
            case .quickNote:QuickNotes.shared.show()
            case .recordMic:Capture.toggleMicrophone()
            case .recordAudio:Capture.toggleSystemAudio()
            case .lockScreen: Power.lockScreen()
            case .mediaToggle: NowPlayingReader.shared.perform(.toggle)
            case .volumeMute: _ = Volume.shared.toggleMute()
            case .downloads: NSWorkspace.shared.open(FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0])
            case .preferences: NotificationCenter.default.post(name:.init("NotchDeck.openSettings"),object:nil)
            case .clipboard: ClipboardPanelController.shared.toggle()
            case .shelf: ShelfPanelController.shared.toggle()
            case .screenshot: _ = Capture.screenshot()
            case .record: Capture.toggleRecording()
            default: break
            }
        }
        NSLog("NotchDeck action: \(item.rawValue)")
    }
}

// MARK: - Окно панели
final class NotchPanel: NSPanel {
    // панель не должна забирать фокус: клики принимаются через acceptsFirstMouse
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        Dbg.log("hover enter")
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        Dbg.log("hover exit")
        onExit?()
    }
}

// MARK: - Контроллер
final class DeckController {
    let model = PanelModel()
    let config = Config.shared
    private(set) var geometry = Geometry.measure()
    private var panel: NotchPanel!
    private var host: HoverView!
    private var content: PanelContentView!
    private var collapseWork: DispatchWorkItem?
    private var settingsWindow: NSWindow?
    private var brightnessWatch: Timer?
    private var alertWatch: Timer?
    private var lastBrightness: Float?
    private var mouseMonitor: Any?

    func start() {
        geometry = Geometry.measure()
        let collapsed = geometry.collapsedFrame

        panel = NotchPanel(contentRect: collapsed,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let showCapture = UserDefaults.standard.object(forKey: "NotchDeck.showInCapture") == nil
            || UserDefaults.standard.bool(forKey: "NotchDeck.showInCapture")
        panel.sharingType = showCapture ? .readOnly : .none

        host = HoverView(frame: CGRect(origin: .zero, size: collapsed.size))
        host.autoresizingMask = [.width, .height]
        content = PanelContentView(frame: CGRect(origin: .zero, size: collapsed.size))
        content.notchHeight = geometry.notchHeight
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
        panel.contentView = host

        host.onEnter = { [weak self] in self?.expand() }
        host.onExit = { [weak self] in self?.scheduleCollapse() }

        content.onTapAction = { [weak self] item in self?.model.perform(item) }
        content.onMediaAction = { [weak self] cmd in
            guard self?.demoRunning == false else{return};NowPlayingReader.shared.perform(cmd)
        }
        content.mediaBar.onSeek = { [weak self] frac in
            guard self?.demoRunning == false else{return}
            NowPlayingReader.shared.seek(to: frac) { self?.readNowPlaying() }
        }
        content.onTapTile = { item in
            if item == .ram {ProcessPanelController.shared.toggle()}
            if item == .happStatus || item == .checkpointStatus {ConnectionMonitor.open(item)}
        }
        content.onHideTile = { [weak self] item in
            Config.shared.hide(item)
            self?.relayoutIfExpanded()
        }
        content.onLongPress = { [weak self] in self?.enterEdit() }
        content.onDone = { [weak self] in self?.exitEdit() }

        model.onUpdate = { [weak self] snap in
            guard let self else { return }
            self.content.update(snap)
            self.detectSignals(snap)
        }
        model.onEditChange = { [weak self] editing in
            guard let self else { return }
            self.content.editing = editing
            self.content.needsLayout = true
            if self.model.expanded { self.applySize() }
        }

        NotificationCenter.default.addObserver(forName:ProfileStore.didChange,object:nil,queue:.main) {[weak self] note in
            guard let self else{return}
            if note.userInfo?["selection"] as? Bool == true {self.model.exitEdit();self.content.applyAppearance();self.relayoutIfExpanded()}
        }
        NotificationCenter.default.addObserver(forName:.init("NotchDeck.profileMenuClosed"),object:nil,queue:.main) {[weak self] _ in
            DispatchQueue.main.asyncAfter(deadline:.now()+2.1) {[weak self] in self?.scheduleCollapse()}
        }
        NotificationCenter.default.addObserver(forName:.init("NotchDeck.profilePreview"),object:nil,queue:.main) {[weak self] _ in
            self?.expand()
            DispatchQueue.main.asyncAfter(deadline:.now()+2.1) {[weak self] in self?.scheduleCollapse()}
        }
        NotificationCenter.default.addObserver(forName:.init("NotchDeck.openSettings"),object:nil,queue:.main) { [weak self] _ in self?.showSettings() }
        NotificationCenter.default.addObserver(forName:Preferences.didChange,object:nil,queue:.main) { [weak self] _ in
            guard let self else{return}
            self.content.rebuild();self.content.applyAppearance();self.relayoutIfExpanded()
            self.startBrightnessWatch()
            if !Preferences.shared.autoPlayer, self.content.mediaOnly {self.forceCollapse()}
        }
        NotificationCenter.default.addObserver(forName: Config.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.content.rebuild()
            self.relayoutIfExpanded()
        }
        NotificationCenter.default.addObserver(forName: .init("NotchDeck.sharingChanged"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let show = UserDefaults.standard.object(forKey: "NotchDeck.showInCapture") == nil
                || UserDefaults.standard.bool(forKey: "NotchDeck.showInCapture")
            self.panel.sharingType = show ? .readOnly : .none
        }

        panel.orderFrontRegardless()

        // запасной путь к ховеру: глобальный монитор движения мыши
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.evaluateHover(NSEvent.mouseLocation)
        }

        // Explicit bounded recording test, invoked only when verifying capture.
        let captureDNC=DistributedNotificationCenter.default()
        captureDNC.addObserver(forName:AppIdentity.notification("record-test"),object:nil,queue:.main) {_ in _ = Capture.startRecording(seconds:8,test:true)}
        captureDNC.addObserver(forName:AppIdentity.notification("record-options"),object:nil,queue:.main) {_ in _ = Capture.toggleRecording()}
        captureDNC.addObserver(forName:AppIdentity.notification("record-status"),object:nil,queue:.main) {_ in Dbg.log("RECORD STATUS active=\(Capture.isRecording) started=\(Capture.recordingStarted != nil) elapsed=\(Capture.elapsedText) file=\(Capture.recordingURL?.path ?? "-")")}
        captureDNC.addObserver(forName:AppIdentity.notification("record-stop"),object:nil,queue:.main) {_ in Capture.stopRecording()}
        // внешние триггеры для проверок
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName:AppIdentity.notification("profiles"),object:nil,queue:.main) {_ in ProfileManager.shared.show()}
        dnc.addObserver(forName:AppIdentity.notification("charge-test"),object:nil,queue:.main) {_ in NotchHUD.shared.showCharging()}
        NotificationCenter.default.addObserver(forName:.init("NotchDeck.chargeTest"),object:nil,queue:.main) {_ in NotchHUD.shared.showCharging()}
        dnc.addObserver(forName:AppIdentity.notification("permissions"),object:nil,queue:.main) {_ in
            Dbg.log("PERMISSIONS screen=\(CGPreflightScreenCaptureAccess()) AX=\(AXIsProcessTrusted()) microphoneRequested=false")
        }
        dnc.addObserver(forName:AppIdentity.notification("notes"),object:nil,queue:.main) {_ in QuickNotes.shared.show()}
        dnc.addObserver(forName:AppIdentity.notification("demo"),object:nil,queue:.main) { [weak self] _ in self?.runQuickDemo() }
        dnc.addObserver(forName:AppIdentity.notification("settings"),object:nil,queue:.main) { [weak self] _ in self?.showSettings() }
        dnc.addObserver(forName: AppIdentity.notification("expand"), object: nil, queue: .main) { [weak self] _ in self?.expand() }
        dnc.addObserver(forName: AppIdentity.notification("collapse"), object: nil, queue: .main) { [weak self] _ in self?.collapse() }
        dnc.addObserver(forName: AppIdentity.notification("edit"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.expand()
            self.enterEdit()
        }
        dnc.addObserver(forName: AppIdentity.notification("editoff"), object: nil, queue: .main) { [weak self] _ in self?.exitEdit() }
        dnc.addObserver(forName: AppIdentity.notification("dumplayout"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Dbg.log("LAYOUT\n" + self.content.dumpLayout())
        }
        dnc.addObserver(forName: AppIdentity.notification("hoverin"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.evaluateHover(CGPoint(x: self.geometry.notchRect.midX, y: self.geometry.top - 6))
        }
        dnc.addObserver(forName: AppIdentity.notification("hoverout"), object: nil, queue: .main) { [weak self] _ in
            self?.evaluateHover(CGPoint(x: 200, y: 400))
        }

        startBrightnessWatch()
        startAlertWatch()
        ConnectionMonitor.shared.start()
        PowerEvents.shared.start()
        setupLevelIndicators()
        ClipboardStore.shared.start()
        NotificationCenter.default.addObserver(forName:Preferences.didChange,object:nil,queue:.main) {_ in
            if Preferences.shared.bool("clipboardHistory",fallback:false) {ClipboardStore.shared.start()}
            else {ClipboardStore.shared.stop();ClipboardStore.shared.clear()}
        }
        NotificationCenter.default.addObserver(forName: ToolPanels.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let open = note.userInfo?["open"] as? Bool, !open { self.scheduleCollapse() }
        }
        NotificationCenter.default.addObserver(forName: Signal.didPost, object: nil, queue: .main) { note in
            guard let info = note.userInfo,
                  let text = info["text"] as? String,
                  let symbol = info["symbol"] as? String else { return }
            Signalder.shared.show(text, symbol: symbol)
        }
        NowPlayingReader.shared.startSystemWatch { [weak self] np in self?.acceptNowPlaying(np) }
        startMediaWatch()
        readNowPlaying()

        NSLog("NotchDeck geometry: screen=\(Int(geometry.screen.frame.width))x\(Int(geometry.screen.frame.height)) " +
              "notch=\(Int(geometry.notchWidth))x\(Int(geometry.notchHeight)) notchRect=\(geometry.notchRect) " +
              "collapsed=\(geometry.collapsedFrame)")
    }

    // MARK: медиа
    private var mediaTimer: Timer?

    func startMediaWatch() {
        guard mediaTimer == nil else{return}
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.readNowPlaying() }
        RunLoop.main.add(t, forMode: .common)
        mediaTimer = t
    }

    func stopMediaWatch() {
        mediaTimer?.invalidate()
        mediaTimer = nil
    }

    private var playerHideWork: DispatchWorkItem?
    private var demoRunning = false
    private var demoWork: [DispatchWorkItem] = []

    func readNowPlaying() {
        guard !demoRunning else{return}
        NowPlayingReader.shared.read { [weak self] np in self?.acceptNowPlaying(np) }
    }

    private func acceptNowPlaying(_ np:NowPlaying?) {
        guard !demoRunning else{return}
        updatePlayer(np)
    }

    private func updatePlayer(_ np:NowPlaying?) {
        let changed=(np == nil) != (model.nowPlaying == nil) || np?.title != model.nowPlaying?.title
        model.nowPlaying=np;content.setMedia(np)
        if np?.playing == true && Preferences.shared.autoPlayer {
            playerHideWork?.cancel();playerHideWork=nil
            if !model.expanded {
                content.mediaOnly=true;model.expanded=true
                NotchHUD.shared.panelExpanded=false
                resizeForContent()
            } else if changed {resizeForContent()}
        } else if content.mediaOnly,playerHideWork == nil {
            let work=DispatchWorkItem { [weak self] in
                guard let self else{return};self.playerHideWork=nil
                if self.content.mediaOnly && self.model.nowPlaying?.playing != true {self.forceCollapse()}
            }
            playerHideWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+3,execute:work)
        } else if changed && model.expanded {resizeForContent()}
    }

    private func forceCollapse() {
        NotchHUD.shared.panelExpanded=false
        model.expanded=false;content.mediaOnly=false;model.stopRefresh()
        panel.setFrame(geometry.collapsedFrame,display:true)
    }

    private func resizeForContent() {
        guard model.expanded else { return }
        let target = geometry.expandedFrame(height: contentHeight())
        guard abs(panel.frame.height-target.height)>0.5 || abs(panel.frame.width-target.width)>0.5 else{return}
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: геометрия и состояния
    func contentHeight() -> CGFloat { content.contentHeight() }

    private func currentFrame() -> CGRect {
        model.expanded ? geometry.expandedFrame(height: contentHeight()) : geometry.collapsedFrame
    }

    func refreshGeometry() {
        geometry = Geometry.measure()
        panel.setFrame(currentFrame(), display: true)
    }

    func expand() {
        if content.mediaOnly {
            content.mediaOnly=false
            model.startRefresh();resizeForContent()
        }
        NotchHUD.shared.panelExpanded = true
        collapseWork?.cancel()
        guard !model.expanded else { return }
        model.expanded = true
        let target = geometry.expandedFrame(height: contentHeight())
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
        model.startRefresh()
        startMediaWatch()
        NSLog("NotchDeck expanded h=\(Int(target.height))")
    }

    /// Сворачивание сразу по уходу курсора — как в прежнем виджете, без паузы.
    /// Вызывается только из глобального монитора мыши: tracking-area mouseExited
    /// срабатывает во время анимации раскрытия (окно растёт) и давал мигание.
    func scheduleCollapse() {
        guard !demoRunning,!ProfileInteraction.active else{return}
        collapseWork?.cancel()
        guard !model.editMode else { return }
        guard !ToolPanels.anyVisible else { return }
        // mouseExited приходит и тогда, когда окно меняет размер при раскрытии:
        // сворачиваем, только если курсор действительно вне панели.
        guard !panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
        collapse()
    }

    func collapse() {
        if Preferences.shared.autoPlayer,model.nowPlaying?.playing == true,!model.editMode {
            content.mediaOnly=true;NotchHUD.shared.panelExpanded=false
            model.stopRefresh();resizeForContent();return
        }
        NotchHUD.shared.panelExpanded = false
        guard model.expanded, !model.editMode else { return }
        collapseWork?.cancel()
        model.expanded = false
        model.stopRefresh()
        content.mediaOnly=false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(geometry.collapsedFrame, display: true)
        }
        NSLog("NotchDeck collapsed")
    }

    func enterEdit() {
        model.enterEdit()
        NSLog("NotchDeck edit on")
    }

    func exitEdit() {
        Dbg.log("exitEdit called, editMode=\(model.editMode)")
        model.exitEdit()
        NSLog("NotchDeck edit off")
    }

    private func applySize() {
        guard model.expanded else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().setFrame(geometry.expandedFrame(height: contentHeight()), display: true)
        }
    }

    private func relayoutIfExpanded() {
        if model.expanded { applySize() } else { panel.setFrame(geometry.collapsedFrame, display: true) }
    }

    /// Ховер по глобальной позиции курсора.
    func evaluateHover(_ p: CGPoint) {
        guard !demoRunning else{return}
        if !model.expanded {
            let hot = geometry.collapsedFrame.insetBy(dx: -10, dy: -8)
            if hot.contains(p) { expand() }
        } else if !model.editMode {
            if content.mediaOnly,panel.frame.contains(p) {expand();return}
            if !panel.frame.insetBy(dx: -2, dy: -2).contains(p) { scheduleCollapse() }
            else { collapseWork?.cancel() }
        }
    }

    // MARK: HUD
    // Свой HUD показываем только на действия из панели: на аппаратные клавиши macOS рисует
    // системный OSD, и второй виджет рядом выглядел дублем. Поэтому слушатели изменений
    // яркости/громкости больше не запускаются вовсе — заодно минус 5 Гц таймер и AudioObjectListener.
    private var lastSignaledTitle: String?
    private var lastCharging: Bool?
    private var lastNetUp: Bool?

    private var lastMemWarn: Date?

    /// Порог предупреждения о памяти и сигнал не чаще раза в 10 минут.
    private func checkMemoryWarning(_ snap: MetricSnapshot) {
        guard snap.ramTotal > 0 else { return }
        let pct = snap.ramUsed / snap.ramTotal * 100
        guard pct >= MemWarn.threshold else { return }
        if let last = lastMemWarn, Date().timeIntervalSince(last) < 600 { return }
        lastMemWarn = Date()
        Signal.post(String(format: L("Память занята на %.0f %%"), pct), symbol: "memorychip.fill")
    }

    /// События для пилюли: зарядка и сеть (смена трека — в readNowPlaying).
    func detectSignals(_ snap: MetricSnapshot) {
        if let lc = lastCharging, lc != snap.charging, snap.battery != nil {
            Signal.post(snap.charging ? L("Зарядка подключена") : L("Зарядка отключена"),
                        symbol: snap.charging ? "bolt.fill" : "bolt.slash")
        }
        lastCharging = snap.charging
        checkMemoryWarning(snap)

        let netUp = !snap.ip.isEmpty && snap.ip != "—"
        if let ln = lastNetUp, ln != netUp {
            Signal.post(netUp ? L("Сеть активна") : L("Сети нет"),
                        symbol: netUp ? "wifi" : "wifi.slash")
        }
        lastNetUp = netUp
    }

    /// Яркость/громкость система меняет сама; приложение только наблюдает и рисует свою плашку.
    func setupLevelIndicators() {
        let handler: (LevelKind, Float, Bool) -> Void = { kind, value, muted in
            guard Preferences.shared.bool("hudEnabled") else{return}
            NotchHUD.shared.showLevel(kind: kind, value: value, muted: muted)
        }
        MediaKeyTap.shared.onChange = handler
        let tapOn = MediaKeyTap.shared.start()
        // Poll external changes; handled key writes synchronize the baseline to avoid duplicates.
        LevelWatch.shared.onChange = handler
        LevelWatch.shared.start()
        NotchHUD.shared.showIdle()
        Dbg.log("level: наблюдение включено (перехват=\(tapOn ? "да" : "нет"), доступ AX=\(AXIsProcessTrusted()))")
    }

    private func startBrightnessWatch() {
        let d = UserDefaults.standard
        model.hudAllowed = d.object(forKey: "NotchDeck.hudEnabled") == nil || d.bool(forKey: "NotchDeck.hudEnabled")
    }

    private var cpuHighSince: Date?
    private var resolvedAlert:NotchAlert = .off

    private func startAlertWatch() {
        func refreshAlert() {
            guard !self.demoRunning else{return}
            var snapshot=Metrics.shared.alertSnapshot()
            let prefs=Preferences.shared
            if snapshot.cpu>=prefs.cpuThreshold {
                if self.cpuHighSince == nil {self.cpuHighSince=Date()}
                if Date().timeIntervalSince(self.cpuHighSince!)<10 {snapshot.cpu=0}
            } else {self.cpuHighSince=nil}
            let next=NotchAlert.resolve(snapshot)
            // Hysteresis avoids rapid on/off at a noisy boundary.
            var keep=false
            if next == .off {
                switch self.resolvedAlert {
                case .memory:keep=prefs.bool("memoryAlerts") && snapshot.ramTotal>0 && snapshot.ramUsed/snapshot.ramTotal*100>=prefs.memoryThreshold-3
                case .cpu:keep=prefs.bool("cpuAlerts") && snapshot.cpu>=prefs.cpuThreshold-5
                case .temperature:keep=prefs.bool("temperatureAlerts") && (snapshot.temp ?? 0)>=prefs.temperatureThreshold-3
                case .battery:keep=prefs.bool("batteryAlerts") && !snapshot.charging && (snapshot.battery ?? 100)<=prefs.batteryThreshold+3
                case .off:break
                }
            }
            if !keep {self.resolvedAlert=next}
            NotchHUD.shared.setAlert(self.resolvedAlert)
        }
        refreshAlert()
        let timer=Timer(timeInterval:5,repeats:true) {_ in refreshAlert()}
        timer.tolerance=0.5;RunLoop.main.add(timer,forMode:.common);alertWatch=timer
    }

    func runQuickDemo() {
        guard !demoRunning else{return}
        playerHideWork?.cancel();playerHideWork=nil
        demoRunning=true;demoWork.forEach{$0.cancel()};demoWork.removeAll()
        let savedPlayer=model.nowPlaying
        let wasExpanded=model.expanded,wasMediaOnly=content.mediaOnly
        forceCollapse();NotchHUD.shared.showIdle()
        func stage(_ seconds:Double,_ action:@escaping()->Void) {
            let work=DispatchWorkItem(block:action);demoWork.append(work)
            DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:work)
        }
        stage(0) {NotchHUD.shared.setAlert(.memory);Signal.post(L("Тест 1/4 · RAM заполнена"),symbol:"memorychip")}
        stage(3) {NotchHUD.shared.setAlert(.battery);Signal.post(L("Тест 2/4 · Низкий заряд"),symbol:"battery.0percent")}
        stage(6) {NotchHUD.shared.setAlert(.cpu);Signal.post(L("Тест 3/4 · Высокая нагрузка CPU"),symbol:"cpu")}
        stage(9) { [weak self] in
            guard let self else{return};NotchHUD.shared.setAlert(.off)
            let np=NowPlaying(title:L("Демонстрация плеера"),artist:L("NotchDeck · тест без воспроизведения"),duration:180,elapsed:48,playing:true,source:"demo")
            self.model.nowPlaying=np;self.content.setMedia(np)
            self.content.mediaOnly=true;self.model.expanded=true;self.resizeForContent()
            Signal.post(L("Тест 4/4 · Контент играет"),symbol:"play.fill")
        }
        stage(12) { [weak self] in
            guard let self else{return};self.demoRunning=false
            self.forceCollapse();self.model.nowPlaying=savedPlayer;self.content.setMedia(savedPlayer)
            NotchHUD.shared.setAlert(self.resolvedAlert)
            if wasExpanded {self.content.mediaOnly=wasMediaOnly;self.model.expanded=true;NotchHUD.shared.panelExpanded = !wasMediaOnly;self.resizeForContent();if !wasMediaOnly {self.model.startRefresh()}}
            else {self.updatePlayer(savedPlayer)}
            self.demoWork.removeAll()
            Signal.post(L("Тест завершён"),symbol:"checkmark.circle")
        }
    }

    // MARK: Настройки
    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:510),
                             styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            w.title=L("Настройки NotchDeck");w.isReleasedWhenClosed=false;w.center()
            let view=PreferencesView(frame:NSRect(x:0,y:0,width:620,height:510))
            view.onDemo = { [weak self] in w.orderOut(nil);self?.runQuickDemo() }
            w.contentView=view
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Пилюля-сигнал у чёлки
final class Signalder {
    static let shared = Signalder()
    private var panel: NSWindow?
    private var content: SignalContentView?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String) {
        let size = CGSize(width: SignalContentView.measure(text), height: 26)
        guard let screen = NSScreen.screens.first else { return }
        let g = Geometry.measure(screen: screen)
        // справа-сверху, под строкой меню: чёлку не закрываем
        let rightMargin: CGFloat = 14
        let frame = CGRect(x: screen.frame.maxX - size.width - rightMargin,
                           y: screen.frame.maxY - g.notchHeight - 8 - size.height,
                           width: size.width, height: size.height)

        if panel == nil {
            let p = NSWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.animationBehavior = .none
            p.sharingType = .readOnly
            let c = SignalContentView(frame: CGRect(origin: .zero, size: size))
            p.contentView = c
            panel = p
            content = c
        }
        guard let p = panel, let c = content else { return }
        c.set(symbol: symbol, text: text)
        p.setFrame(frame, display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

// MARK: - HUD-окно
final class HUDder {
    static let shared = HUDder()
    private var panel: NotchPanel?
    private var content: HUDContentView?
    private var hideWork: DispatchWorkItem?

    func show(symbol: String, value: Float, muted: Bool) {
        let d = UserDefaults.standard
        guard d.object(forKey: "NotchDeck.hudEnabled") == nil || d.bool(forKey: "NotchDeck.hudEnabled") else { return }
        let g = Geometry.measure()
        let size = CGSize(width: 210, height: 34)
        let frame = CGRect(x: g.centerX - size.width / 2,
                           y: g.top - g.notchHeight - 10 - size.height,
                           width: size.width, height: size.height)

        if panel == nil {
            let p = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.animationBehavior = .none
            p.sharingType = .readOnly
            let c = HUDContentView(frame: CGRect(origin: .zero, size: size))
            p.contentView = c
            panel = p
            content = c
        }
        content?.set(symbolName: symbol, value: value, muted: muted)
        panel?.setFrame(frame, display: true)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

// MARK: - Автозапуск
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("NotchDeck launchAtLogin error: \(error)")
        }
    }
}

// MARK: - Плашка яркости и громкости у чёлки
final class Levelder {
    static let shared = Levelder()
    private var panel: NSWindow?
    private var content: LevelWingView?
    private var hideWork: DispatchWorkItem?

    func show(kind: LevelKind, value: Float, muted: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        let g = Geometry.measure(screen: screen)
        // растёт влево от чёлки, по высоте совпадает с ней
        let size = CGSize(width: LevelWingView.width, height: g.notchHeight)
        let frame = CGRect(x: g.notchRect.minX - size.width + 6,
                           y: g.top - size.height,
                           width: size.width, height: size.height)

        if panel == nil {
            let p = NSWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.animationBehavior = .none
            p.sharingType = .readOnly
            let c = LevelWingView(frame: CGRect(origin: .zero, size: size))
            p.contentView = c
            panel = p
            content = c
        }
        guard let p = panel, let c = content else { return }
        c.set(kind: kind, value: value, muted: muted)
        p.setFrame(frame, display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
}
