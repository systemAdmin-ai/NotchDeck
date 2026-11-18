import AppKit

// R1/R3: остров трафика — скорость ↓/↑ в крыльях и график 60 с в полосе под вырезом.
// Отдельное представление: неон яркости/громкости (IslandView) не затрагивается.

struct TrafficScene: Equatable {
    var history: [TrafficPoint] = []
    var down: Double?          // nil → «—» (R7)
    var up: Double?
    var peak: Double = 1
    var top: [TrafficProcess] = []
}

final class TrafficIslandView: NSView {
    private var scene = TrafficScene()
    private var reveal = HUDMotion(response: 24)
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    var onHidden: (() -> Void)?
    /// О скрытии уже сообщено — защита от повторного onHidden.
    private var hiddenNotified = false

    private static let downColor = NSColor(srgbRed: 0.28, green: 0.82, blue: 1.00, alpha: 1)
    private static let upColor = NSColor(srgbRed: 1.00, green: 0.70, blue: 0.28, alpha: 1)

    override var isFlipped: Bool { true }

    /// Высота полосы под вырезом, где рисуется график.
    static let bandHeight: CGFloat = 30

    static func plateSize() -> CGSize {
        let g = Geometry.measure()
        let width = min(g.screen.frame.width - 32, g.notchWidth + 210)
        return CGSize(width: width, height: g.notchHeight + bandHeight + processRowsHeight)
    }

    /// Высота блока топ-3 процессов (R4).
    static var processRowsHeight: CGFloat = 0

    func set(_ scene: TrafficScene, animated: Bool) {
        self.scene = scene
        Self.processRowsHeight = scene.top.isEmpty ? 0 : CGFloat(scene.top.count) * 13 + 6
        if !animated {
            timer?.invalidate(); timer = nil
            hiddenNotified = false
            reveal.reset(1)
            needsDisplay = true
            return
        }
        // Цель ставим до advance(), иначе первый же шаг видит «settled при target=0» и гасит остров.
        hiddenNotified = false
        reveal.target = 1
        advance()
        startTimer()
    }

    func setVisible(_ visible: Bool) {
        if visible { hiddenNotified = false }
        reveal.target = visible ? 1 : 0
        advance()
        startTimer()
    }

    var revealAmount: Double { advance(); return reveal.value }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.advance() }
        t.tolerance = 0.002
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func advance() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0, now - lastTick)
        lastTick = now
        reveal.advance(dt)
        needsDisplay = true
        if reveal.settled {
            timer?.invalidate(); timer = nil
            if reveal.target == 0, !hiddenNotified {
                hiddenNotified = true
                // Вызывать onHidden строго вне advance(): внутри уже открыт mutating-доступ
                // к reveal, а stop() трогает те же объекты — Swift падает на эксклюзивности.
                DispatchQueue.main.async { [weak self] in self?.onHidden?() }
            }
        }
    }

    deinit { timer?.invalidate() }

    // MARK: рисование

    private func platePath(center: CGFloat, width: CGFloat, height: CGFloat) -> NSBezierPath {
        let radius: CGFloat = 14
        let corner = radius * 0.5522847498
        let ear: CGFloat = 14
        let earControl = ear * 0.5522847498
        let plate = CGRect(x: center - width / 2, y: 0, width: width, height: height)
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: plate.minX - ear, y: 0))
        shape.line(to: NSPoint(x: plate.maxX + ear, y: 0))
        shape.curve(to: NSPoint(x: plate.maxX, y: ear),
                    controlPoint1: NSPoint(x: plate.maxX + ear - earControl, y: 0),
                    controlPoint2: NSPoint(x: plate.maxX, y: ear - earControl))
        shape.line(to: NSPoint(x: plate.maxX, y: plate.maxY - radius))
        shape.curve(to: NSPoint(x: plate.maxX - radius, y: plate.maxY),
                    controlPoint1: NSPoint(x: plate.maxX, y: plate.maxY - radius + corner),
                    controlPoint2: NSPoint(x: plate.maxX - radius + corner, y: plate.maxY))
        shape.line(to: NSPoint(x: plate.minX + radius, y: plate.maxY))
        shape.curve(to: NSPoint(x: plate.minX, y: plate.maxY - radius),
                    controlPoint1: NSPoint(x: plate.minX + radius - corner, y: plate.maxY),
                    controlPoint2: NSPoint(x: plate.minX, y: plate.maxY - radius + corner))
        shape.line(to: NSPoint(x: plate.minX, y: ear))
        shape.curve(to: NSPoint(x: plate.minX - ear, y: 0),
                    controlPoint1: NSPoint(x: plate.minX, y: ear - earControl),
                    controlPoint2: NSPoint(x: plate.minX - ear + earControl, y: 0))
        shape.close()
        return shape
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = Geometry.measure()
        let center = g.notchRect.midX - g.screen.frame.minX + NotchHUD.offsetX
        let expansion = CGFloat(max(0, min(1, reveal.value)))
        guard expansion > 0.01 else { return }
        let full = Self.plateSize()
        let width = g.notchWidth + (full.width - g.notchWidth) * expansion
        let height = g.notchHeight + (Self.bandHeight * expansion) + (Self.processRowsHeight * expansion)
        let shape = platePath(center: center, width: width, height: height)
        NSColor.black.setFill()
        shape.fill()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let opacity = expansion
        drawLabels(center: center, notchWidth: g.notchWidth, height: height, opacity: opacity)
        drawGraph(center: center, width: width, notchHeight: g.notchHeight, height: height, opacity: opacity)
        drawProcesses(center: center, width: width, top: g.notchHeight + Self.bandHeight, opacity: opacity)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLabels(center: CGFloat, notchWidth: CGFloat, height: CGFloat, opacity: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let downText = scene.down.map { "↓" + Fmt.speed($0) } ?? "↓—"
        let upText = scene.up.map { "↑" + Fmt.speed($0) } ?? "↑—"
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let downSize = (downText as NSString).size(withAttributes: attrs)
        let upSize = (upText as NSString).size(withAttributes: attrs)
        let y = (height - Self.bandHeight - downSize.height) / 2
        var downAttrs = attrs
        downAttrs[.foregroundColor] = Self.downColor.withAlphaComponent(opacity)
        var upAttrs = attrs
        upAttrs[.foregroundColor] = Self.upColor.withAlphaComponent(opacity)
        (downText as NSString).draw(at: NSPoint(x: center - notchWidth / 2 - 8 - downSize.width, y: y),
                                    withAttributes: downAttrs)
        (upText as NSString).draw(at: NSPoint(x: center + notchWidth / 2 + 8, y: y), withAttributes: upAttrs)
    }

    private func drawGraph(center: CGFloat, width: CGFloat, notchHeight: CGFloat,
                           height: CGFloat, opacity: CGFloat) {
        let points = scene.history
        guard !points.isEmpty else { return }
        let pad: CGFloat = 16
        let top = notchHeight + 4
        let bottom = height - 6
        let graphWidth = width - pad * 2
        guard graphWidth > 8, bottom > top else { return }
        let peak = max(scene.peak, 1)
        let step = points.count > 1 ? graphWidth / CGFloat(TrafficHistory.capacity - 1) : 0
        let startX = center - graphWidth / 2 + graphWidth - CGFloat(points.count - 1) * step

        func line(_ value: (TrafficPoint) -> Double, color: NSColor, fill: Bool) {
            let path = NSBezierPath()
            for (i, p) in points.enumerated() {
                let x = startX + CGFloat(i) * step
                let ratio = CGFloat(min(1, value(p) / peak))
                let y = bottom - ratio * (bottom - top)
                if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
            }
            if fill, points.count > 1 {
                let area = path.copy() as! NSBezierPath
                area.line(to: NSPoint(x: startX + CGFloat(points.count - 1) * step, y: bottom))
                area.line(to: NSPoint(x: startX, y: bottom))
                area.close()
                color.withAlphaComponent(0.22 * opacity).setFill()
                area.fill()
            }
            color.withAlphaComponent(0.95 * opacity).setStroke()
            path.lineWidth = 1.2
            path.lineJoinStyle = .round
            path.stroke()
        }
        line({ $0.down }, color: Self.downColor, fill: true)
        line({ $0.up }, color: Self.upColor, fill: false)
    }

    /// R4: до трёх строк «имя ↓ ↑» под графиком.
    private func drawProcesses(center: CGFloat, width: CGFloat, top: CGFloat, opacity: CGFloat) {
        guard !scene.top.isEmpty else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let nameFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let x = center - width / 2 + 16
        var y = top + 2
        for p in scene.top {
            var nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont]
            nameAttrs[.foregroundColor] = NSColor.white.withAlphaComponent(0.85 * opacity)
            (p.name as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: nameAttrs)
            let rights = "↓" + Fmt.speed(p.down) + "  ↑" + Fmt.speed(p.up)
            let size = (rights as NSString).size(withAttributes: [.font: font])
            var rightAttrs: [NSAttributedString.Key: Any] = [.font: font]
            rightAttrs[.foregroundColor] = NSColor.white.withAlphaComponent(0.55 * opacity)
            (rights as NSString).draw(at: NSPoint(x: center + width / 2 - 16 - size.width, y: y),
                                      withAttributes: rightAttrs)
            y += 13
        }
    }

    /// Демо-сцена для офскрин-проверки R3/R7 (без сети).
    static func demoScene(empty: Bool) -> TrafficScene {
        if empty { return TrafficScene(history: [], down: nil, up: nil, peak: 1, top: []) }
        var points: [TrafficPoint] = []
        for i in 0..<60 {
            let t = Double(i) / 60
            let d = 40 + 90 * (0.5 + 0.5 * sin(t * 6.28 * 2))
            let u = 8 + 14 * (0.5 + 0.5 * sin(t * 6.28 * 3 + 1))
            points.append(TrafficPoint(down: d, up: u))
        }
        let top = [TrafficProcess(name: "Mail", pid: 85892, down: 266.5, up: 0.3),
                   TrafficProcess(name: "Safari", pid: 4121, down: 88.2, up: 12.4),
                   TrafficProcess(name: "Hermes", pid: 45843, down: 3.8, up: 0.0)]
        return TrafficScene(history: points, down: 130.4, up: 22.1, peak: 130.4, top: top)
    }

    /// R3: офскрин-рендер для проверки без окна.
    @discardableResult
    static func render(to path: String, scene: TrafficScene) -> Bool {
        _ = NSApplication.shared
        let frame = CGRect(origin: .zero, size: NotchHUD.overlayFrame().size)
        let v = TrafficIslandView(frame: frame)
        v.set(scene, animated: false)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
