import AppKit

// MARK: - Строка процесса
final class ProcRow: NSView {
    let info: ProcInfo
    let mode: ProcessPanelController.Mode
    let bundleCount: Int

    private let nameLabel = NSTextField(labelWithString: "")
    private let memLabel = NSTextField(labelWithString: "")
    private let killButton = NSButton()
    private let killAppButton = NSButton()
    private var pendingKill: Date?
    private var pendingApp: Date?
    private var timer: Timer?

    var onKill: ((ProcInfo) -> Void)?
    var onKillApp: ((ProcInfo) -> Void)?

    init(info: ProcInfo, mode: ProcessPanelController.Mode, bundleCount: Int) {
        self.info = info
        self.mode = mode
        self.bundleCount = bundleCount
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        wantsLayer = true
        layer?.cornerRadius = 7

        nameLabel.stringValue = info.name
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        memLabel.stringValue = valueText
        memLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        memLabel.textColor = .secondaryLabelColor
        memLabel.alignment = .right

        let protectedProc = Procs.isProtected(info)

        killButton.isBordered = false
        killButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Завершить"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        killButton.contentTintColor = .secondaryLabelColor
        killButton.target = self
        killButton.action = #selector(killTapped)
        killButton.isHidden = protectedProc

        // «закрыть приложение целиком» — только если у бандла больше одного процесса
        killAppButton.isBordered = false
        killAppButton.image = NSImage(systemSymbolName: "rectangle.stack.badge.minus",
                                      accessibilityDescription: L("Закрыть приложение"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        killAppButton.contentTintColor = .secondaryLabelColor
        killAppButton.target = self
        killAppButton.action = #selector(killAppTapped)
        killAppButton.toolTip = L("Закрыть все %d процесса приложения", bundleCount)
        killAppButton.isHidden = protectedProc || bundleCount < 2 || info.bundlePath == nil

        addSubview(nameLabel)
        addSubview(memLabel)
        addSubview(killButton)
        addSubview(killAppButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var valueText: String {
        switch mode {
        case .memory: return String(format: L("%.0f МБ"), info.megabytes)
        case .cpu: return String(format: "%.0f %%", Double(info.cpuTime))
        }
    }

    override func layout() {
        super.layout()
        killButton.frame = NSRect(x: bounds.width - 26, y: 8, width: 18, height: 18)
        killAppButton.frame = NSRect(x: bounds.width - 48, y: 9, width: 16, height: 16)
        memLabel.frame = NSRect(x: bounds.width - 118, y: 9, width: 66, height: 14)
        nameLabel.frame = NSRect(x: 6, y: 9, width: bounds.width - 130, height: 14)
    }

    private func flash(label: NSTextField, button: NSButton, text: String) {
        button.contentTintColor = .systemRed
        label.stringValue = text
        label.textColor = .systemRed
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.killButton.contentTintColor = .secondaryLabelColor
            self.killAppButton.contentTintColor = .secondaryLabelColor
            self.memLabel.stringValue = self.valueText
            self.memLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func killTapped() {
        if let pending = pendingKill, Date().timeIntervalSince(pending) < 3 {
            Dbg.log("procs panel: подтверждено завершение \(info.name) pid=\(info.pid)")
            onKill?(info)
            return
        }
        pendingKill = Date()
        flash(label: memLabel, button: killButton, text: L("точно?"))
    }

    @objc private func killAppTapped() {
        if let pending = pendingApp, Date().timeIntervalSince(pending) < 3 {
            Dbg.log("procs panel: подтверждено закрытие приложения \(info.name) (\(bundleCount) проц.)")
            onKillApp?(info)
            return
        }
        pendingApp = Date()
        flash(label: memLabel, button: killAppButton, text: L("всё (%d)?", bundleCount))
    }
}

// MARK: - Окно процессов (память / CPU, закрытие приложения)
final class ProcessPanelController: NSObject {
    enum Mode { case memory, cpu }

    static let shared = ProcessPanelController()
    private var window: ToolWindow?
    private var doc: FlippedView?
    private var timer: Timer?
    private var switcher: ModeSwitch?
    private var purgeButton: NSButton?
    private let size = NSSize(width: 380, height: 320)
    private(set) var mode: Mode = .memory

    private var closer: OutsideCloser?
    private(set) var justClosedAt: Date?

    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevTime = Date()
    private(set) var lastRows: [ProcInfo] = []

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        // клик по плитке сразу после закрытия «по клику мимо» не должен открывать окно заново
        if let t = justClosedAt, Date().timeIntervalSince(t) < 0.45 { return }
        if let w = window, w.isVisible { close(); return }
        show()
    }

    func close() {
        justClosedAt = Date()
        closer?.stop(); closer = nil
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
        window = nil
        doc = nil
        ToolPanels.post(false)
    }

    private func show() {
        let w = ToolWindow(size: size, title: "")
        let root = ToolBackground(frame: NSRect(origin: .zero, size: size))
        w.contentView = root

        // Названия окна нет: только переключатель RAM / CPU и подсказка про завершение.
        let seg = ModeSwitch(frame: NSRect(x: 12, y: 7, width: 148, height: 22))
        seg.isCPU = mode == .cpu
        seg.onChange = { [weak self] cpu in
            guard let self else { return }
            self.mode = cpu ? .cpu : .memory
            self.prevCPU = Dictionary(uniqueKeysWithValues: Procs.snapshot().map { ($0.pid, $0.cpuTime) })
            self.prevTime = Date()
            Dbg.log("procs panel: режим=\(cpu ? "cpu" : "ram")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reload() }
        }
        root.addSubview(seg)
        switcher = seg

        // кнопка очистки кэша — заметная, с иконкой и подписью
        let purge = NSButton(title: L(" Очистить кэш"), target: self, action: #selector(purgeTapped))
        purge.bezelStyle = .rounded
        purge.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        purge.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        purge.imagePosition = .imageLeading
        purge.contentTintColor = NSColor(srgbRed: 0.42, green: 0.80, blue: 0.71, alpha: 1)
        purge.toolTip = L("Освободить кэш памяти (система попросит права администратора)")
        purge.frame = NSRect(x: 168, y: 5, width: 196, height: 24)
        purge.autoresizingMask = [.minXMargin]
        root.addSubview(purge)
        purgeButton = purge

        let listTop: CGFloat = 36
        let listH = size.height - listTop - 10
        let scroll = NSScrollView(frame: NSRect(x: 8, y: listTop, width: size.width - 16, height: listH))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: scroll.frame.width, height: listH))
        scroll.documentView = doc
        root.addSubview(scroll)
        self.doc = doc

        w.orderFrontRegardless()
        window = w
        ToolPanels.post(true)
        installOutsideClose()

        prevCPU = Dictionary(uniqueKeysWithValues: Procs.snapshot().map { ($0.pid, $0.cpuTime) })
        prevTime = Date()
        reload()

        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reload()
        }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Dbg.log("procs panel: показан режим=\(mode == .memory ? "память" : "cpu")")
    }



    /// Клик мимо окна закрывает его.
    private func installOutsideClose() {
        let c = OutsideCloser(window: { [weak self] in self?.window }, onClose: { [weak self] in self?.close() })
        c.start()
        closer = c
    }

    @objc private func purgeTapped() {
        guard let b = purgeButton else { return }
        b.isEnabled = false
        b.title = L(" Очищаем…")
        Dbg.log("purge: запуск очистки кэша")
        MemoryPurge.run(allowPrompt: true) { ok, message, before, after in
            b.isEnabled = true
            b.title = L(" Очистить кэш")
            let freed = after > before ? after - before : 0
            Dbg.log("purge: \(message), свободно \(MemoryPurge.human(after)) (было \(MemoryPurge.human(before)))")
            Signal.post(ok ? L("Кэш очищен · свободно %@", MemoryPurge.human(after)) : message,
                        symbol: ok ? "memorychip.fill" : "exclamationmark.triangle.fill")
            self.reload()
        }
    }

    private func reload() {
        guard let doc else { return }
        let all = Procs.snapshot()
        var counts: [String: Int] = [:]
        for p in all { if let b = p.bundlePath { counts[b, default: 0] += 1 } }

        let rows: [ProcInfo]
        switch mode {
        case .memory:
            rows = Array(all.sorted { $0.footprint > $1.footprint }.prefix(8))
        case .cpu:
            let now = Date()
            let interval = now.timeIntervalSince(prevTime)
            rows = Array(Procs.topByCPU(previous: prevCPU, current: all, interval: interval).prefix(8))
            prevCPU = Dictionary(uniqueKeysWithValues: all.map { ($0.pid, $0.cpuTime) })
            prevTime = now
        }
        lastRows = rows

        doc.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        for p in rows {
            let count = p.bundlePath.flatMap { counts[$0] } ?? 1
            let row = ProcRow(info: p, mode: mode, bundleCount: count)
            row.onKill = { [weak self] proc in
                Procs.terminate(proc) { ok in
                    Signal.post(ok ? L("Завершён %@", proc.name) : L("Не удалось: %@", proc.name),
                                symbol: ok ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    self?.reload()
                }
            }
            row.onKillApp = { [weak self] proc in
                guard let bundle = proc.bundlePath else { return }
                let n = Procs.terminateBundle(bundle) { count in
                    Signal.post(L("Закрыто процессов: %d", count), symbol: "xmark.octagon.fill")
                    self?.reload()
                }
                Dbg.log("procs panel: закрываю приложение \(bundle) процессов=\(n)")
            }
            row.frame = NSRect(x: 0, y: y, width: doc.frame.width - 2, height: 32)
            doc.addSubview(row)
            y += 34
        }
        doc.frame = NSRect(x: 0, y: 0, width: doc.frame.width, height: max(doc.frame.height, y))
    }

    /// Текстовый дамп для CLI-проверок.
    func dumpRows() -> String {
        let rows = lastRows.isEmpty
            ? Array(Procs.snapshot().sorted { $0.footprint > $1.footprint }.prefix(8))
            : lastRows
        return rows.map {
            let value = mode == .memory
                ? String(format: L("%.0f МБ"), $0.megabytes)
                : String(format: "%.0f %%", Double($0.cpuTime))
            return String(format: "%@ pid=%d %@%@", $0.name, $0.pid, value,
                          Procs.isProtected($0) ? L(" (защищён)") : "")
        }.joined(separator: "\n")
    }

    /// Переключение режима из CLI.
    func setMode(_ m: Mode) {
        mode = m
        switcher?.isCPU = m == .cpu
        prevCPU = Dictionary(uniqueKeysWithValues: Procs.snapshot().map { ($0.pid, $0.cpuTime) })
        prevTime = Date()
    }
}

// MARK: - Переключатель «RAM / CPU»
final class ModeSwitch: NSView {
    var onChange: ((Bool) -> Void)?   // true = CPU
    var isCPU = false { didSet { refresh() } }

    private let ramBtn = NSButton()
    private let cpuBtn = NSButton()

    private let ramColor = NSColor(srgbRed: 0.42, green: 0.80, blue: 0.71, alpha: 1)
    private let cpuColor = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.98, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor

        for (btn, title, sym, isRam) in [(ramBtn, "RAM", "memorychip", true), (cpuBtn, "CPU", "cpu", false)] {
            btn.title = title
            btn.isBordered = false
            btn.bezelStyle = .regularSquare
            btn.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            btn.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold))
            btn.imagePosition = .imageLeading
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 6
            btn.target = self
            btn.action = isRam ? #selector(ramTapped) : #selector(cpuTapped)
            addSubview(btn)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = (bounds.width - 6) / 2
        ramBtn.frame = NSRect(x: 3, y: 2, width: w, height: bounds.height - 4)
        cpuBtn.frame = NSRect(x: w + 3, y: 2, width: w, height: bounds.height - 4)
    }

    private func refresh() {
        style(ramBtn, active: !isCPU, color: ramColor)
        style(cpuBtn, active: isCPU, color: cpuColor)
    }

    private func style(_ b: NSButton, active: Bool, color: NSColor) {
        b.layer?.backgroundColor = active ? color.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        b.contentTintColor = active ? color : NSColor(white: 0.62, alpha: 1)
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: active ? .semibold : .regular),
            .foregroundColor: active ? color : NSColor(white: 0.62, alpha: 1)
        ])
    }

    @objc private func ramTapped() { guard isCPU else { return }; isCPU = false; onChange?(false) }
    @objc private func cpuTapped() { guard !isCPU else { return }; isCPU = true; onChange?(true) }
}
