import AppKit

// R10: остров трафика по наведению на чёлку, отдельное окно поверх панели.
final class TrafficHUD {
    static let shared = TrafficHUD()

    private var window: NSPanel?
    private var view: TrafficIslandView?
    private var hideWork: DispatchWorkItem?
    private var hoverTimer: Timer?
    private(set) var isShowing = false
    /// Открыт по наведению (а не по таймеру).
    private var hoverOpened = false
    /// До этого момента панель не перехватывает наведение.
    private var holdUntil: TimeInterval = 0
    /// Сколько секунд остров держит приоритет над раскрытием панели.
    static let holdSeconds: TimeInterval = 2.0

    /// R10: при раскрытой панели остров не рисуется.
    static var suppressedByPanel: Bool { NotchHUD.shared.panelExpanded }

    static var hoverEnabled: Bool {
        let key = "NotchDeck.trafficOnHover"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Зона наведения совпадает с зоной раскрытия панели — привычное поведение чёлки.
    static var hotZone: CGRect {
        Geometry.measure().collapsedFrame.insetBy(dx: -10, dy: -8)
    }

    private func makeWindow() -> NSPanel {
        let size = TrafficIslandView.plateSize()
        let frame = NotchHUD.overlayFrame()
        let w = NSPanel(contentRect: CGRect(origin: frame.origin, size: frame.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        w.sharingType = .readOnly
        _ = size
        return w
    }

    private func build() {
        guard window == nil else { return }
        let w = makeWindow()
        let frame = NotchHUD.overlayFrame()
        let v = TrafficIslandView(frame: CGRect(origin: .zero, size: frame.size))
        v.onHidden = { [weak self] in
            self?.window?.orderOut(nil)
            self?.isShowing = false
            TrafficMonitor.shared.stop()
        }
        w.contentView = v
        w.orderOut(nil)
        window = w
        view = v
    }

    /// Показать остров с текущими значениями.
    func show(hold seconds: TimeInterval = 3, byHover: Bool = true) {
        guard !Self.suppressedByPanel else {
            Dbg.log("traffic: show skipped — панель раскрыта (R10)")
            return
        }
        guard Self.hoverEnabled else {
            Dbg.log("traffic: show skipped — режим выключен")
            return
        }
        build()
        guard let w = window, let v = view else { return }
        hoverOpened = byHover
        holdUntil = ProcessInfo.processInfo.systemUptime + Self.holdSeconds
        TrafficMonitor.shared.start()
        let scene = Self.scene()
        v.set(scene, animated: true)
        if !w.isVisible { w.orderFrontRegardless() }
        isShowing = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in v.setVisible(false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        view?.setVisible(false)
    }

    /// Обновление графика, пока остров виден (1 Гц, вместе с TrafficMonitor).
    func refresh() {
        guard isShowing, let v = view else { return }
        v.set(Self.scene(), animated: false)
    }

    static func scene() -> TrafficScene {
        let monitor = TrafficMonitor.shared
        let display = monitor.display
        return TrafficScene(history: monitor.history.points,
                            down: display?.down,
                            up: display?.up,
                            peak: monitor.history.peak,
                            top: monitor.processes)
    }

    /// R10: слежение за курсором; пока остров виден, панель не раскрывается (иначе наведение
    /// сразу открывает панель и остров не увидеть). Через holdAfter секунд панель работает как обычно.
    func startHoverWatch() {
        guard hoverTimer == nil, Self.hoverEnabled else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard Self.hoverEnabled else { return }
            let inside = Self.hotZone.contains(NSEvent.mouseLocation)
            if inside, !self.isShowing, !Self.suppressedByPanel {
                self.show()
            } else if !inside, self.isShowing, self.hoverOpened {
                // Курсор ушёл — остров убираем, не дожидаясь таймера.
                self.hide()
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
        Dbg.log("traffic: hover watch on, zone=\(Int(Self.hotZone.width))x\(Int(Self.hotZone.height))")
    }

    /// Панель спрашивает: удерживаем ли мы раскрытие ради показа острова.
    var shouldHoldPanelExpand: Bool {
        guard isShowing, hoverOpened else { return false }
        return ProcessInfo.processInfo.systemUptime < holdUntil
    }

    func stopHoverWatch() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }
}
