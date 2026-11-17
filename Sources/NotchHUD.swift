import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreImage

// Only the narrow strip behind the halo is sampled, in memory, with existing permission.
// Excluding this process prevents the glow from feeding back into its own brightness.
private final class HaloBackdrop {
    static let shared=HaloBackdrop()
    private var busy=false
    private var requested=Double(-100)
    private var values=[Double]()
    private var columns=[Double]()
    private let w=256,h=24
    static func gain(_ brightness:Double)->Double {1+0.70*max(0,min(1,brightness))}
    var sampleCount:Int {values.count}
    var sampleRange:String {"\(values.min() ?? 0)...\(values.max() ?? 0)"}
    static func smoothedColumns(_ values:[Double],width:Int,height:Int)->[Double] {
        guard values.count==width*height,width>0,height>0 else{return []}
        let means=(0..<width).map {x in (0..<height).reduce(0.0) {$0+values[$1*width+x]}/Double(height)}
        return (0..<width).map {x in
            var sum=0.0,weight=0.0
            for offset in -9...9 {
                let k=exp(-Double(offset*offset)/18)
                sum+=means[max(0,min(width-1,x+offset))]*k;weight+=k
            }
            return sum/weight
        }
    }
    func brightness(x:Double,y:Double)->Double {
        // One gain through the complete height of each contour column: the
        // menu bar boundary must never become a brightness step in the halo.
        guard columns.count==w else{return 0}
        let fx=max(0,min(Double(w-1),x*Double(w-1)))
        let i=Int(fx),j=min(w-1,i+1),a=fx-Double(i)
        return columns[i]*(1-a)+columns[j]*a
    }
    func setRenderBackground() {
        values=(0..<w*h).map {$0/w < h/2 ? 0:1}
        columns=Self.smoothedColumns(values,width:w,height:h)
    }
    func refresh() {
        let now=ProcessInfo.processInfo.systemUptime
        guard !busy,now-requested>0.8,CGPreflightScreenCaptureAccess() else{return}
        requested=now;busy=true
        let geometry=Geometry.measure(),rect=NotchHUD.overlayFrame()
        let displayID=(geometry.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        Task { @MainActor in
            defer {self.busy=false}
            do {
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                guard let display=content.displays.first(where:{$0.displayID==displayID}) else{return}
                let own=content.windows.filter {$0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier}
                let filter=SCContentFilter(display:display,excludingWindows:own)
                let config=SCStreamConfiguration();config.width=self.w;config.height=self.h;config.showsCursor=false
                config.sourceRect=CGRect(x:rect.minX-geometry.screen.frame.minX,
                    y:geometry.screen.frame.maxY-rect.maxY,width:rect.width,height:rect.height)
                let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                let info=CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                guard let context=CGContext(data:nil,width:self.w,height:self.h,bitsPerComponent:8,
                    bytesPerRow:self.w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info),let data=context.data else{return}
                context.draw(image,in:CGRect(x:0,y:0,width:self.w,height:self.h))
                let bytes=data.bindMemory(to:UInt8.self,capacity:self.w*self.h*4)
                var next=[Double](repeating:0,count:self.w*self.h)
                for i in next.indices {
                    let luma=(0.2126*Double(bytes[i*4])+0.7152*Double(bytes[i*4+1])+0.0722*Double(bytes[i*4+2]))/255
                    next[i]=self.values.count == next.count ? self.values[i]*0.65+luma*0.35:luma
                }
                self.values=next
                self.columns=Self.smoothedColumns(next,width:self.w,height:self.h)
            } catch {self.values=[];self.columns=[]}
        }
    }
}

// MARK: - Индикатор яркости и громкости у чёлки
//
// Плашка центрируется по вырезу; глиф и уровень занимают левое и правое крылья.

enum NotchAlert {
    case off, memory, temperature, battery, cpu

    static func resolve(_ snapshot: MetricSnapshot, prefs:Preferences = .shared) -> NotchAlert {
        if prefs.bool("batteryAlerts"),let battery=snapshot.battery,battery<=prefs.batteryThreshold,!snapshot.charging {return .battery}
        if prefs.bool("temperatureAlerts"),let temperature=snapshot.temp,temperature>=prefs.temperatureThreshold {return .temperature}
        if prefs.bool("memoryAlerts"),snapshot.ramTotal>0,snapshot.ramUsed/snapshot.ramTotal*100>=prefs.memoryThreshold {return .memory}
        if prefs.bool("cpuAlerts"),snapshot.cpu>=prefs.cpuThreshold {return .cpu}
        return .off
    }
}

final class NotchHUD {
    static let shared = NotchHUD()

    private var window: NSWindow?
    private var island: IslandView?
    private var hideWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var alertWindow: NSWindow?
    private var alertOutline: IslandView?
    private var currentAlert: NotchAlert = .off
    private static let alertGlowPadding: CGFloat = 11

    var panelExpanded = false {
        didSet {
            applyVisibility()
            applyAlertVisibility()
        }
    }
    private var levelUntil: Date?
    private var chargingOverlay=false

    // MARK: калибровка (без пересборки)
    //
    //   defaults write com.notchdeck.app NotchDeck.islandExtraWidth -float 84
    //   defaults write com.notchdeck.app NotchDeck.islandOffsetX -float 0
    //   defaults write com.notchdeck.app NotchDeck.islandExtraHeight -float 5
    static var extraWidth: CGFloat {
        let v = UserDefaults.standard.object(forKey: "NotchDeck.islandExtraWidth") as? Double
        let text = ("100%" as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        ]).width
        // Each wing must fit the widest label plus inner/outer padding.
        return max(ceil(text + 20) * 2, CGFloat(v ?? 108))
    }
    static var offsetX: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: "NotchDeck.islandOffsetX"))
    }
    static var extraHeight: CGFloat {
        let v = UserDefaults.standard.object(forKey: "NotchDeck.islandExtraHeight") as? Double
        return max(3, CGFloat(v ?? 5))
    }

    static func islandFrame() -> CGRect {
        let g = Geometry.measure()
        let width = min(g.screen.frame.width - 32, g.notchWidth + extraWidth)
        let height = g.notchHeight + extraHeight
        return CGRect(x: g.notchRect.midX - width / 2 + offsetX,
                      y: g.top - height, width: width, height: height)
    }

    // Прозрачная область не расширяет чёрную плашку.
    static func overlayFrame() -> CGRect {
        let g = Geometry.measure()
        let height = islandFrame().height + 32
        return CGRect(x: g.screen.frame.minX, y: g.top - height,
                      width: g.screen.frame.width, height: height)
    }

    private func makeWindow(size: CGSize, origin: CGPoint) -> NSWindow {
        let w = NSPanel(contentRect: CGRect(origin: origin, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        w.sharingType = .readOnly
        return w
    }

    private func build() {
        guard window == nil else { return }
        let frame = NotchHUD.overlayFrame()
        let w = makeWindow(size: frame.size, origin: frame.origin)
        let v = IslandView(frame: CGRect(origin: .zero, size: frame.size))
        v.onHidden = { [weak self] in
            self?.window?.orderOut(nil);self?.applyAlertVisibility()
        }
        w.contentView = v
        w.orderOut(nil)
        window = w
        island = v
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let frame = Self.overlayFrame()
                self.window?.setFrame(frame, display: true)
                self.island?.frame = CGRect(origin: .zero, size: frame.size)
                self.island?.needsDisplay = true
                self.setAlert(self.currentAlert)
            }
        }
        Dbg.log("island: \(Int(frame.width))x\(Int(frame.height)) в \(Int(frame.minX)),\(Int(frame.minY))")
    }

    private func applyVisibility() {
        guard let w = window else { return }
        let showing = (levelUntil.map { $0 > Date() } ?? false) && (!panelExpanded || chargingOverlay)
        if showing {
            w.setFrame(NotchHUD.overlayFrame(), display: true)
            island?.frame = CGRect(origin: .zero, size: w.frame.size)
            if !w.isVisible { w.orderFrontRegardless() }
            island?.setVisible(true)
        } else if panelExpanded {
            island?.resetContour()
            w.orderOut(nil)
        } else if w.isVisible {
            island?.setVisible(false)
        }
    }

    func setAlert(_ alert: NotchAlert) {
        if currentAlert == alert,alertWindow != nil {applyAlertVisibility();return}
        currentAlert=alert
        guard alert != .off else {alertOutline?.setVisible(false);return}
        if alertWindow == nil {
            let frame=Self.alertFrame()
            let w=makeWindow(size:frame.size,origin:frame.origin)
            let view=IslandView(frame:CGRect(origin:.zero,size:frame.size))
            view.autoresizingMask=[.width,.height]
            view.onHidden = { [weak self] in self?.alertWindow?.orderOut(nil) }
            w.contentView=view;alertWindow=w;alertOutline=view
        }
        alertOutline?.setWarning(alert)
        alertWindow?.setFrame(Self.alertFrame(),display:true)
        applyAlertVisibility()
    }

    private static func alertFrame()->CGRect {overlayFrame()}

    private func applyAlertVisibility() {
        guard let window=alertWindow else{return}
        let hasLevel=(levelUntil.map{$0>Date()} ?? false)
        if currentAlert != .off && !hasLevel && !panelExpanded {
            window.orderFrontRegardless();alertOutline?.setVisible(true)
        } else {alertOutline?.setVisible(false);window.orderOut(nil)}
    }

    /// Покой: ничего не показываем.
    func showIdle() {
        hideWork?.cancel()
        levelUntil = nil
        applyVisibility()
    }

    func showLevel(kind: LevelKind, value: Float, muted: Bool) {
        chargingOverlay=false
        build()
        let wasHidden = !(window?.isVisible ?? false)
        if wasHidden { island?.resetContour() }
        island?.set(kind: kind, value: value, muted: muted)
        alertWindow?.orderOut(nil)
        levelUntil = Date().addingTimeInterval(1.2)
        applyVisibility()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyVisibility() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func showCharging() {
        build();chargingOverlay=true
        if !(window?.isVisible ?? false) {island?.resetContour()}
        island?.setCharging()
        alertWindow?.orderOut(nil)
        levelUntil=Date().addingTimeInterval(2.4);applyVisibility()
        hideWork?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.applyVisibility() }
        hideWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+2.4,execute:work)
        Dbg.log("charging: green sweep started")
    }

    func rebuild() {
        window?.orderOut(nil)
        window = nil
        island = nil
        build()
        applyVisibility()
    }

    /// Exercise the real timer/window lifecycle without writing system levels.
    static func testHalo() {
        precondition(HaloBackdrop.gain(0)==1 && abs(HaloBackdrop.gain(1)-1.7)<0.0001)
        precondition(HaloBackdrop.gain(-1)==1 && abs(HaloBackdrop.gain(2)-1.7)<0.0001)
        let sampler=HaloBackdrop.shared
        precondition(sampler.brightness(x:0.5,y:0.5)==0)
        let split=(0..<64).map {$0/8<4 ? 0.0:1.0}
        let smooth=HaloBackdrop.smoothedColumns(split,width:8,height:8)
        precondition(smooth.count==8 && smooth.allSatisfy {abs($0-0.5)<0.00001},"Black/white boundary changes halo gain")
        if CGPreflightScreenCaptureAccess() {
            sampler.refresh()
            let deadline=Date().addingTimeInterval(5)
            while sampler.sampleCount==0 && Date()<deadline {RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
            precondition(sampler.sampleCount>0,"Backdrop sampling failed")
        }
        print("HALO PASS: bounded contrast gain, safe fallback; backdrop samples=\(sampler.sampleCount), range=\(sampler.sampleRange)")
    }

    static func testLifecycle() {
        let hud = shared
        func wait(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002)) }
        }
        func check(_ ok: Bool, _ message: String) {
            if !ok { fputs("HUD LIFECYCLE FAIL: \(message)\n", stderr); exit(1) }
        }
        let samples=(0...480).map {IslandView.batteryGlow(at:Double($0)/100)}
        check(samples.allSatisfy {$0 >= 0.44 && $0 <= 0.54}, "battery glow too strong")
        check(abs(IslandView.batteryGlow(at:0)-IslandView.batteryGlow(at:4.8))<0.00001,"battery pulse loop jumps")
        hud.showLevel(kind: .brightness, value: 1, muted: false)
        wait(0.30)
        check(hud.window?.isVisible == true, "not visible after opening")
        check((hud.island?.revealAmount ?? 0) > 0.99, "opening exceeds 300ms")
        for i in 0..<12 {
            hud.showLevel(kind: i % 2 == 0 ? .volume : .brightness,
                          value: Float(i % 4)/3, muted: i == 4)
            wait(0.04)
            check(hud.window?.isVisible == true, "repeat/switch hides window")
            check((hud.island?.revealAmount ?? 0) > 0.99, "repeat resets opening")
        }
        wait(1.28)
        let closing = hud.island?.revealAmount ?? 0
        check(closing > 0 && closing < 0.99, "not contracting after timeout")
        hud.showLevel(kind: .volume, value: 1, muted: false)
        let resumed = hud.island?.revealAmount ?? 0
        check(abs(resumed-closing) < 0.05, "interrupted hide jumps")
        wait(0.3)
        check(hud.window?.isVisible == true, "stale hide removes new event")
        wait(1.7)
        check(hud.window?.isVisible == false, "window remains after close")
        print("HUD LIFECYCLE PASS: opening, hold, switch, 0/100/mute, interrupted hide, idle")
    }

    static func renderCharge(to directory:String) {
        try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        for (index,phase) in [0.2,0.5,0.8].enumerated() {
            let view=IslandView(frame:CGRect(origin:.zero,size:overlayFrame().size))
            view.setChargeRenderPhase(phase)
            guard let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{continue}
            view.cacheDisplay(in:view.bounds,to:rep)
            if let data=rep.representation(using:.png,properties:[:]) {
                try? data.write(to:URL(fileURLWithPath:directory).appendingPathComponent("charge-\(index).png"))
            }
        }
    }

    /// Офскрин-рендер плашки в PNG: проверка вида без ожидания события и скриншотов.
    @discardableResult
    static func renderSample(to path: String, kind: LevelKind, value: Float, muted: Bool = false) -> Bool {
        _ = NSApplication.shared
        let f = overlayFrame()
        if ProcessInfo.processInfo.arguments.contains("--contrast-sample") {HaloBackdrop.shared.setRenderBackground()}
        let v = IslandView(frame: CGRect(origin: .zero, size: f.size))
        v.set(kind: kind, value: value, muted: muted, animated: false)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Офскрин-рендер кадров раскрытия неона для проверки направления и плавности.
    @discardableResult
    static func renderSequence(to directory: String, kind: LevelKind, value: Float, frames: Int = 9) -> Bool {
        _ = NSApplication.shared
        let f = overlayFrame()
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = max(2, frames)
        for i in 0..<total {
            let amount = CGFloat(i) / CGFloat(total - 1)
            let v = IslandView(frame: CGRect(origin: .zero, size: f.size))
            v.set(kind: kind, value: value, muted: false, animated: false)
            v.setAnimationProgressForRender(amount * CGFloat(value))
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
            v.cacheDisplay(in: v.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return false }
            let name = String(format: "frame-%02d.png", i)
            guard (try? data.write(to: dir.appendingPathComponent(name))) != nil else { return false }
        }
        return true
    }

    /// Кадры от настоящего таймера IslandView; время каждого кадра сохраняется рядом.
    static func renderMotion(to directory: String, kind: LevelKind, value: Float) -> Bool {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v = IslandView(frame: CGRect(origin: .zero, size: overlayFrame().size))
        v.resetContour()
        v.set(kind: kind, value: value, muted: false)
        let start = ProcessInfo.processInfo.systemUptime
        var times: [Double] = []
        for i in 0...60 {
            let deadline = start + Double(i)/60
            while ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
            }
            times.append(ProcessInfo.processInfo.systemUptime-start)
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
            v.cacheDisplay(in: v.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]),
                  (try? data.write(to: dir.appendingPathComponent(String(format: "frame-%03d.png", i)))) != nil else { return false }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: times),
              (try? data.write(to: dir.appendingPathComponent("times.json"))) != nil else { return false }
        return true
    }

    /// Офскрин-рендер U-контура для проверки цвета и геометрии.
    @discardableResult
    static func renderAlertSample(to path: String, alert: NotchAlert) -> Bool {
        _ = NSApplication.shared
        let frame = alertFrame()
        let v=IslandView(frame:CGRect(origin:.zero,size:frame.size))
        v.setWarning(alert,animated:false)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Для CLI-проверки калибровки.
    static func describe() -> String {
        let g = Geometry.measure()
        let f = islandFrame()
        return String(format: "экран %.0fx%.0f | вырез x=%.0f…%.0f (w=%.0f, h=%.0f) | остров x=%.0f…%.0f (w=%.0f, h=%.0f)",
                      g.screen.frame.width, g.screen.frame.height,
                      g.notchRect.minX, g.notchRect.maxX, g.notchWidth, g.notchHeight,
                      f.minX, f.maxX, f.width, f.height)
            + String(format: " | прозрачное окно %.0fx%.0f | линия 100%% w=%.0f",
                     overlayFrame().width, overlayFrame().height, (g.screen.frame.width - 32) / 2)
    }
}

// MARK: - Компактная плашка и линия в прозрачной области экрана
final class IslandView: NSView {
    private var kind: LevelKind = .volume
    // A restrained four-second breath, never flashing or disappearing completely.
    static func batteryGlow(at time:Double)->Double {
        0.44 + 0.10 * (1-cos(2*Double.pi*time/4.8))/2
    }
    private var batteryBreathing:Bool {
        warning == .battery && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var warning: NotchAlert?
    private static let haloContext=CIContext(options:[.cacheIntermediates:false])
    private var haloMaskKey=""
    private var haloMask=[Float]()
    private var charging=false
    private var chargeStarted=ProcessInfo.processInfo.systemUptime
    private var progress: CGFloat = 0
    private var muted = false
    private var motion = HUDMotion()
    private var reveal = HUDMotion(response: 28)
    var onHidden: (() -> Void)?
    // Sample at the current clock time, rather than the last display timer tick.
    var revealAmount: Double {advanceAnimation();return reveal.value}
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var animationTimer: Timer?
    private var animationProgress: CGFloat { CGFloat(max(0, min(1, motion.value))) }

    private var accent: NSColor {
        switch kind {
        case .brightness: return NSColor(srgbRed: 1.00, green: 0.70, blue: 0.28, alpha: 1)
        case .volume: return NSColor(srgbRed: 0.28, green: 0.82, blue: 1.00, alpha: 1)
        }
    }
    override var isFlipped: Bool { true }

    func setCharging() {
        set(kind:.brightness,value:1,muted:false)
        charging=true;chargeStarted=ProcessInfo.processInfo.systemUptime
        startAnimationTimer()
    }

    func setChargeRenderPhase(_ phase:Double) {
        set(kind:.brightness,value:1,muted:false,animated:false)
        charging=true;chargeStarted=ProcessInfo.processInfo.systemUptime-phase*1.2
    }

    func setWarning(_ alert:NotchAlert,animated:Bool=true) {
        set(kind:.brightness,value:0.46,muted:false,animated:animated)
        warning=alert
        if animated && batteryBreathing {startAnimationTimer()}
    }

    func set(kind: LevelKind, value: Float, muted: Bool, animated: Bool = true) {
        self.kind = kind
        warning=nil;charging=false
        self.muted = kind == .volume && muted
        progress = CGFloat(max(0, min(1, self.muted ? 0 : value)))
        if !animated {
            animationTimer?.invalidate()
            animationTimer = nil
            motion.reset(Double(progress))
            reveal.reset(1)
            needsDisplay = true
            return
        }
        advanceAnimation()
        motion.target = Double(progress)
        reveal.target = 1
        startAnimationTimer()
    }

    func setVisible(_ visible: Bool) {
        advanceAnimation()
        reveal.target = visible ? 1 : 0
        startAnimationTimer()
    }

    private func startAnimationTimer() {
        if animationTimer == nil {
            lastTick = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: batteryBreathing ? 1.0 / 24 : 1.0 / 60, repeats: true) { [weak self] _ in
                self?.advanceAnimation()
            }
            timer.tolerance = 0.001
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
    }

    private func advanceAnimation() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0, now - lastTick)
        lastTick = now
        motion.advance(dt)
        reveal.advance(dt)
        needsDisplay = true
        if motion.settled && reveal.settled && !(charging && now-chargeStarted<2.8) && !(batteryBreathing && reveal.target > 0) {
            animationTimer?.invalidate()
            animationTimer = nil
            if reveal.target == 0 { onHidden?() }
        }
    }
    deinit { animationTimer?.invalidate() }

    func resetContour() {
        animationTimer?.invalidate()
        animationTimer = nil
        motion.reset()
        reveal.reset()
        lastTick = ProcessInfo.processInfo.systemUptime
        needsDisplay = true
    }
    func setAnimationProgressForRender(_ amount: CGFloat) {
        motion.reset(Double(max(0, min(1, amount))))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = Geometry.measure()
        let center = g.notchRect.midX - g.screen.frame.minX + NotchHUD.offsetX
        let expansion = CGFloat(max(0, min(1, reveal.value)))
        let width = g.notchWidth + (NotchHUD.islandFrame().width - g.notchWidth) * expansion
        let height = g.notchHeight + NotchHUD.extraHeight * expansion
        let plate = CGRect(x: center - width/2, y: 0, width: width, height: height)
        let radius: CGFloat = 14
        let cornerControl = radius * 0.5522847498
        let shape = NSBezierPath()
        let ear:CGFloat=14
        let earControl=ear*0.5522847498
        shape.move(to: NSPoint(x: plate.minX-ear, y: 0))
        shape.line(to: NSPoint(x: plate.maxX+ear, y: 0))
        shape.curve(to: NSPoint(x: plate.maxX, y: ear),
                    controlPoint1: NSPoint(x: plate.maxX+ear-earControl, y:0),
                    controlPoint2: NSPoint(x:plate.maxX,y:ear-earControl))
        shape.line(to: NSPoint(x: plate.maxX, y: plate.maxY-radius))
        shape.curve(to: NSPoint(x: plate.maxX-radius, y: plate.maxY),
                    controlPoint1: NSPoint(x: plate.maxX, y: plate.maxY-radius+cornerControl),
                    controlPoint2: NSPoint(x: plate.maxX-radius+cornerControl, y: plate.maxY))
        shape.line(to: NSPoint(x: plate.minX+radius, y: plate.maxY))
        shape.curve(to: NSPoint(x: plate.minX, y: plate.maxY-radius),
                    controlPoint1: NSPoint(x: plate.minX+radius-cornerControl, y: plate.maxY),
                    controlPoint2: NSPoint(x: plate.minX, y: plate.maxY-radius+cornerControl))
        shape.line(to:NSPoint(x:plate.minX,y:ear))
        shape.curve(to:NSPoint(x:plate.minX-ear,y:0),
                    controlPoint1:NSPoint(x:plate.minX,y:ear-earControl),
                    controlPoint2:NSPoint(x:plate.minX-ear+earControl,y:0))
        shape.close()
        NSColor.black.setFill()
        shape.fill()

        let maximumHalfLength = max(0, min(center-16, bounds.maxX-center-16))
        let halfLength = maximumHalfLength * animationProgress * expansion
        if halfLength > 0.2 {
            drawHalo(center: center, width: width, height: height,
                     halfLength: halfLength, opacity: expansion, outline: shape)
            // Keep the camera and wings completely black; light spills outwards only.
            NSColor.black.setFill()
            shape.fill()
        }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        drawContent(center: center, notchWidth: g.notchWidth, height: height, opacity: expansion)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Rasterize the smooth field once per frame. Computing opacity directly avoids
    // accumulating dozens of 8-bit gradient layers, which introduces visible grain.
    private func drawHalo(center: CGFloat, width: CGFloat, height: CGFloat,
                          halfLength: CGFloat, opacity: CGFloat, outline:NSBezierPath) {
        let scale = window?.backingScaleFactor ?? Geometry.measure().screen.backingScaleFactor
        let pixelsWide = Int(ceil(bounds.width*scale)), pixelsHigh = Int(ceil(bounds.height*scale))
        // Linear floating-point pixels avoid repeated 8-bit alpha quantization.
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB),
              let raster=CGContext(data:nil,width:pixelsWide,height:pixelsHigh,bitsPerComponent:32,
                  bytesPerRow:pixelsWide*16,space:space,bitmapInfo:info),let data=raster.data else{return}
        memset(data,0,pixelsWide*pixelsHigh*16)
        let pixels=data.bindMemory(to:Float.self,capacity:pixelsWide*pixelsHigh*4)
        // Blur the exact silhouette used above, rather than piecing together
        // independent distance fields whose bisectors create visible sharp seams.
        let padding=32*scale
        let key="\(pixelsWide):\(pixelsHigh):\(Int((width*scale*10).rounded())):\(Int((height*scale*10).rounded())):\(center)"
        if haloMaskKey != key {
            let maskHeight=pixelsHigh+Int(padding)
            guard let mask=CGContext(data:nil,width:pixelsWide,height:maskHeight,bitsPerComponent:8,
                bytesPerRow:pixelsWide*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return}
            mask.translateBy(x:0,y:CGFloat(maskHeight)-padding)
            mask.scaleBy(x:scale,y:-scale)
            let contour=CGMutablePath()
            contour.move(to:CGPoint(x:bounds.width,y:0))
            contour.addLine(to:CGPoint(x:center+width/2+14,y:0))
            var elementIndex=0
            outline.cgPath.applyWithBlock {pointer in
                defer {elementIndex+=1}
                guard elementIndex>=2 else{return}
                let element=pointer.pointee
                switch element.type {
                case .addLineToPoint:contour.addLine(to:element.points[0])
                case .addCurveToPoint:contour.addCurve(to:element.points[2],control1:element.points[0],control2:element.points[1])
                case .addQuadCurveToPoint:contour.addQuadCurve(to:element.points[1],control:element.points[0])
                default:break
                }
            }
            contour.addLine(to:CGPoint(x:0,y:0))
            mask.addPath(contour)
            mask.setStrokeColor(NSColor.white.cgColor);mask.setLineWidth(8)
            mask.setLineCap(.round);mask.setLineJoin(.round);mask.strokePath()
            guard let source=mask.makeImage() else{return}
            let input=CIImage(cgImage:source)
            let blurred=input.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:8.5*scale])
            var values=[Float](repeating:0,count:pixelsWide*pixelsHigh*4)
            Self.haloContext.render(blurred,toBitmap:&values,rowBytes:pixelsWide*16,
                bounds:CGRect(x:0,y:0,width:pixelsWide,height:pixelsHigh),format:.RGBAf,colorSpace:space)
            haloMask=values;haloMaskKey=key
        }
        let extent = Double(halfLength)
        let first = max(0, Int((center-halfLength-1)*scale))
        let last = min(pixelsWide-1, Int((center+halfLength+1)*scale))
        guard last >= first else { return }
        if window?.isVisible == true && motion.settled && reveal.settled {HaloBackdrop.shared.refresh()}
        let batteryOpacity = warning == .battery
            ? (batteryBreathing ? Self.batteryGlow(at:ProcessInfo.processInfo.systemUptime) : 0.49) : 1.0
        for px in first...last {
            let signedX=(Double(px)+0.5)/Double(scale)-Double(center)
            let x=abs(signedX)
            let phase=(ProcessInfo.processInfo.systemUptime-chargeStarted).truncatingRemainder(dividingBy:1.2)/1.2
            let travelX = -extent+2*extent*phase
            let pulse=charging ? 0.30+0.70*exp(-pow((signedX-travelX)/55,2)/2):1.0
            let t = min(1, max(0, (x/extent-0.55)/0.45))
            let envelope = 1-t*t*(3-2*t)
            if envelope <= 0 { continue }
            for py in 0..<pixelsHigh {
                let index = (py*pixelsWide+px)*4
                let density=Double(haloMask[index+3])
                if density<0.00001 {continue}
                let backdrop=HaloBackdrop.shared.brightness(x:(Double(px)+0.5)/Double(pixelsWide),y:(Double(py)+0.5)/Double(pixelsHigh))
                let contrastGain=HaloBackdrop.gain(backdrop)
                let uniformDensity=0.30*tanh(density/0.30)
                let alpha = min(0.75,1.8*uniformDensity*contrastGain*envelope*Double(opacity)*pulse*batteryOpacity)
                let fringe = max(0,min(0.65,(1-density/0.36)*0.65))
                let warm = kind == .brightness
                let inner = charging ? (0.22,1.0,0.50) : (warning != nil ? (1.0,0.25,0.29) : (warm ? (1.0,0.79,0.56) : (0.55,0.79,1.0)))
                let outer = charging ? (0.03,0.72,0.25) : (warning != nil ? (0.94,0.05,0.16) : (warm ? (0.94,0.45,0.48) : (0.40,0.47,0.98)))
                pixels[index] = Float((inner.0*(1-fringe)+outer.0*fringe)*alpha)
                pixels[index+1] = Float((inner.1*(1-fringe)+outer.1*fringe)*alpha)
                pixels[index+2] = Float((inner.2*(1-fringe)+outer.2*fringe)*alpha)
                pixels[index+3] = Float(alpha)
            }
        }
        guard let cgImage=raster.makeImage() else{return}
        let image=NSImage(cgImage:cgImage,size:bounds.size)
        image.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1,
                   respectFlipped:true,hints:nil)
    }

    private func drawContent(center: CGFloat, notchWidth: CGFloat, height: CGFloat, opacity: CGFloat) {
        let color = NSColor.white.withAlphaComponent(opacity)
        var symbol: String
        switch kind {
        case .brightness:
            symbol = progress > 0.55 ? "sun.max.fill" : (progress > 0.2 ? "sun.min.fill" : "sun.min")
        case .volume:
            symbol = muted || progress <= 0.001 ? "speaker.slash.fill"
                : (progress > 0.55 ? "speaker.wave.3.fill" : (progress > 0.2 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"))
        }
        if let warning {
            switch warning {
            case .memory:symbol="memorychip"
            case .cpu:symbol="cpu"
            case .temperature:symbol="thermometer.high"
            case .battery:symbol="battery.0percent"
            case .off:break
            }
        }
        if charging {symbol="bolt.fill"}
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) {
            let size = base.size
            let rect = NSRect(x: center-notchWidth/2-7-size.width, y: height/2-size.height/2,
                              width: size.width, height: size.height)
            let palette = NSImage.SymbolConfiguration(paletteColors: [color])
            (base.withSymbolConfiguration(palette) ?? base).draw(in: rect)
        }
        var text = muted ? L("выкл") : String(format: "%.0f%%", progress*100)
        if let warning {
            switch warning {
            case .memory:text="RAM"
            case .cpu:text="CPU"
            case .temperature:text=L("Жарко")
            case .battery:text=L("Заряд")
            case .off:text=""
            }
        }
        if charging {text=L("Заряд")}
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: center+notchWidth/2+6, y: height/2-size.height/2), withAttributes: attrs)
    }
}

