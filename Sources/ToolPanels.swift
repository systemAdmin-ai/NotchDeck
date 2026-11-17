import AppKit

// MARK: - Общее окно инструментов (под чёлкой)
class ToolWindow: NSPanel {
    init(size: NSSize, title _: String) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        positionUnderNotch(size: size)
    }

    /// Чуть ниже раскрытой панели (её высота 178 pt), чтобы не перекрывать её.
    static let topOffset: CGFloat = 190

    func positionUnderNotch(size: NSSize) {
        guard let screen = NSScreen.screens.first else { return }
        let y = screen.frame.maxY - ToolWindow.topOffset - size.height
        setFrame(NSRect(x: (screen.frame.width - size.width) / 2, y: y,
                        width: size.width, height: size.height), display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Стеклянный фон инструмента (Liquid Glass) с тонкой светлой обводкой.
class ToolBackground: NSView {
    private var glass: NSView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if glass == nil {
            glass = makeBackground()
            if let g = glass {
                g.autoresizingMask = [.width, .height]
                g.wantsLayer = true
                addSubview(g, positioned: .below, relativeTo: nil)
            }
        }
        glass?.frame = bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        NSColor(white: 1, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Liquid Glass на macOS 26+, размытие материала на более старых системах.
    private func makeBackground() -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: bounds)
            g.cornerRadius = 16
            return g
        }
        let v = NSVisualEffectView(frame: bounds)
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = Self.roundedMask(radius: 16)
        return v
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Строка списка: иконка + заголовок + подпись, тап и перетаскивание.
final class ToolRow: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var fileURL: URL?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private var hover = false

    init(symbol: String, title t: String, subtitle s: String, fileURL: URL? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 34))
        self.fileURL = fileURL
        wantsLayer = true
        layer?.cornerRadius = 8
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyDown
        title.stringValue = t
        title.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        sub.stringValue = s
        sub.font = NSFont.systemFont(ofSize: 9)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(title)
        addSubview(sub)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: 10, width: 16, height: 15)
        title.frame = NSRect(x: 32, y: 6, width: bounds.width - 44, height: 14)
        sub.frame = NSRect(x: 32, y: 19, width: bounds.width - 44, height: 12)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private var dragStarted = false

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted { onClick?() }
    }

    // отдать файл наружу перетаскиванием
    override func mouseDragged(with event: NSEvent) {
        guard let url = fileURL else { return }
        dragStarted = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// MARK: - Панель буфера обмена
final class ClipboardPanelController: NSObject {
    static let shared = ClipboardPanelController()
    private var window: ToolWindow?
    private let size = NSSize(width: 380, height: 300)
    private var closer: OutsideCloser?
    private var justClosedAt: Date?
    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if let t = justClosedAt, Date().timeIntervalSince(t) < 0.45 { return }
        if let w = window, w.isVisible { close(); return }
        show()
    }

    func close() {
        justClosedAt = Date()
        closer?.stop(); closer = nil
        window?.orderOut(nil)
        window = nil
        ToolPanels.post(false)
    }

    private func show() {
        let w = ToolWindow(size: size, title: L("Буфер обмена"))
        let root = ToolBackground(frame: NSRect(origin: .zero, size: size))
        w.contentView = root

        let head = NSTextField(labelWithString: L("Буфер обмена"))
        head.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        head.textColor = .labelColor
        head.frame = NSRect(x: 14, y: 8, width: 200, height: 16)
        root.addSubview(head)

        let clearBtn = NSButton(title: L("Очистить"), target: self, action: #selector(clearAll))
        clearBtn.isBordered = false
        clearBtn.font = NSFont.systemFont(ofSize: 10)
        clearBtn.contentTintColor = .secondaryLabelColor
        clearBtn.frame = NSRect(x: size.width - 90, y: 7, width: 76, height: 16)
        root.addSubview(clearBtn)

        let listTop: CGFloat = 30
        let listH = size.height - listTop - 10
        let scroll = NSScrollView(frame: NSRect(x: 8, y: listTop, width: size.width - 16, height: listH))
        scroll.registerForDraggedTypes([.fileURL])
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: scroll.frame.width, height: listH))
        let items = ClipboardStore.shared.items
        var y: CGFloat = 0
        if items.isEmpty {
            let none = NSTextField(labelWithString: L("Пока пусто — скопируй что-нибудь"))
            none.font = NSFont.systemFont(ofSize: 10)
            none.textColor = .secondaryLabelColor
            none.frame = NSRect(x: 8, y: 8, width: 300, height: 14)
            doc.addSubview(none)
        }
        for (i, it) in items.enumerated() {
            let row = ToolRow(symbol: it.symbol, title: it.preview,
                              subtitle: i == 0 ? L("последнее") : L("%d-е", i + 1))
            row.frame = NSRect(x: 0, y: y, width: scroll.frame.width - 2, height: 34)
            row.onClick = { [weak self] in
                ClipboardStore.shared.restore(it)
                Signal.post(L("Скопировано из истории"), symbol: "doc.on.doc.fill")
                self?.close()
            }
            doc.addSubview(row)
            y += 36
        }
        doc.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: max(listH, y))
        scroll.documentView = doc
        root.addSubview(scroll)

        w.orderFrontRegardless()
        window = w
        ToolPanels.post(true)
        let c = OutsideCloser(window: { [weak self] in self?.window }, onClose: { [weak self] in self?.close() })
        c.start()
        closer = c
        Dbg.log("clipboard panel: показан, записей=\(items.count)")
    }

    @objc private func clearAll() {
        ClipboardStore.shared.clear()
        close()
        show()
    }
}

// MARK: - Панель полки
final class ShelfPanelController: NSObject {
    static let shared = ShelfPanelController()
    private var window: ToolWindow?
    private let size = NSSize(width: 380, height: 280)
    private var closer: OutsideCloser?
    private var justClosedAt: Date?
    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if let t = justClosedAt, Date().timeIntervalSince(t) < 0.45 { return }
        if let w = window, w.isVisible { close(); return }
        show()
    }

    func close() {
        justClosedAt = Date()
        closer?.stop(); closer = nil
        window?.orderOut(nil)
        window = nil
        ToolPanels.post(false)
    }

    private func show() {
        let w = ToolWindow(size: size, title: L("Полка"))
        let root = ShelfDropView(frame: NSRect(origin: .zero, size: size))
        root.onDrop = { [weak self] urls in
            ShelfStore.shared.add(urls)
            Signal.post(L("На полке: %d", ShelfStore.shared.urls.count), symbol: "tray.full.fill")
            self?.close()
            self?.show()
        }
        w.contentView = root

        let head = NSTextField(labelWithString: L("Полка — перетащи файл сюда"))
        head.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        head.textColor = .labelColor
        head.frame = NSRect(x: 14, y: 8, width: 300, height: 16)
        root.addSubview(head)

        let listTop: CGFloat = 30
        let listH = size.height - listTop - 10
        let scroll = NSScrollView(frame: NSRect(x: 8, y: listTop, width: size.width - 16, height: listH))
        scroll.registerForDraggedTypes([.fileURL])
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: scroll.frame.width, height: listH))
        let files = ShelfStore.shared.urls
        var y: CGFloat = 0
        if files.isEmpty {
            let none = NSTextField(labelWithString: L("Пусто. Перетащи файл в это окно."))
            none.font = NSFont.systemFont(ofSize: 10)
            none.textColor = .secondaryLabelColor
            none.frame = NSRect(x: 8, y: 8, width: 300, height: 14)
            doc.addSubview(none)
        }
        for u in files {
            let row = ToolRow(symbol: "doc.fill", title: u.lastPathComponent,
                              subtitle: u.deletingLastPathComponent().path, fileURL: u)
            row.frame = NSRect(x: 0, y: y, width: scroll.frame.width - 2, height: 34)
            row.onClick = { NSWorkspace.shared.open(u) }
            doc.addSubview(row)
            y += 36
        }
        doc.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: max(listH, y))
        scroll.documentView = doc
        root.addSubview(scroll)

        w.orderFrontRegardless()
        window = w
        ToolPanels.post(true)
        let c = OutsideCloser(window: { [weak self] in self?.window }, onClose: { [weak self] in self?.close() })
        c.start()
        closer = c
        Dbg.log("shelf panel: показан, файлов=\(files.count)")
    }
}

/// Окно полки, принимающее перетаскивание файлов.
final class ShelfDropView: ToolBackground {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let u = urls(from: sender)
        Dbg.log("shelf drag entered: файлов=\(u.count) types=\(sender.draggingPasteboard.types?.map { $0.rawValue } ?? [])")
        return u.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = urls(from: sender)
        Dbg.log("shelf drop: файлов=\(u.count)")
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}


// MARK: - Закрытие кликом мимо окна
/// Клик в любом месте вне окна закрывает его. Ловим mouseUp, а не mouseDown:
/// иначе перетаскивание файла из Finder в полку закрывало бы окно до самого броска.
final class OutsideCloser {
    private var global: Any?
    private var local: Any?
    private let windowProvider: () -> NSWindow?
    private var onClose: () -> Void

    init(window: @escaping () -> NSWindow?, onClose: @escaping () -> Void) {
        windowProvider = window
        self.onClose = onClose
    }

    func start() {
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            self?.check()
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.check()
            return event
        }
    }

    func stop() {
        if let m = global { NSEvent.removeMonitor(m); global = nil }
        if let m = local { NSEvent.removeMonitor(m); local = nil }
    }

    private func check() {
        guard let w = windowProvider(), w.isVisible else { return }
        if !w.frame.contains(NSEvent.mouseLocation) { onClose() }
    }
}

enum ToolPanels {
    static let didChange = Notification.Name("NotchDeck.toolPanels")

    static var anyVisible: Bool {
        ClipboardPanelController.shared.isVisible || ShelfPanelController.shared.isVisible
            || ProcessPanelController.shared.isVisible
    }

    static func post(_ open: Bool) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["open": open])
    }
}
