import AppKit
import UniformTypeIdentifiers

enum PanelStyle:String,CaseIterable {
    case auto, light, dark, glass, graphite, midnight, aurora, neon
    var title:String {
        switch self {
        case .auto:return L("Авто")
        case .light:return L("Светлый")
        case .dark:return L("Тёмный")
        case .glass:return L("Стекло")
        case .graphite:return L("Графит")
        case .midnight:return L("Полночь")
        case .aurora:return L("Сияние")
        case .neon:return L("Неон")
        }
    }
    var detail:String {
        switch self {
        case .auto:return L("Адаптивное стекло macOS: фон просвечивает, а контраст следует светлой или тёмной теме системы.")
        case .light:return L("Молочное стекло с тёмными значками и текстом.")
        case .dark:return L("Затемнённое стекло со светлыми значками и текстом.")
        case .glass:return L("Размытый фон, лёгкая прозрачность и тонкая светлая кромка.")
        case .graphite:return L("Матовая тёмная поверхность с мягкими контрастами.")
        case .midnight:return L("Глубокий чёрный фон: минимализм без отвлекающих эффектов.")
        case .aurora:return L("Стекло с сине-фиолетовым переливом и мягким цветным акцентом.")
        case .neon:return L("Тёмное стекло и тонкая бирюзовая светящаяся кромка.")
        }
    }
}

struct AppShortcut: Codable, Equatable, Identifiable {
    var id: String
    var path: String
    var name: String
}

final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("NotchDeck.preferencesChanged")
    private let defaults: UserDefaults
    private(set) var applications: [AppShortcut]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        applications = defaults.data(forKey: "NotchDeck.applications")
            .flatMap { try? JSONDecoder().decode([AppShortcut].self, from: $0) } ?? []
    }
    func reloadFromDefaults() {
        applications=defaults.data(forKey:"NotchDeck.applications").flatMap {try? JSONDecoder().decode([AppShortcut].self,from:$0)} ?? []
    }
    func bool(_ key: String, fallback: Bool = true) -> Bool {
        defaults.object(forKey: "NotchDeck."+key) == nil ? fallback : defaults.bool(forKey: "NotchDeck."+key)
    }
    func number(_ key: String, fallback: Double) -> Double {
        (defaults.object(forKey: "NotchDeck."+key) as? NSNumber)?.doubleValue ?? fallback
    }
    func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: "NotchDeck."+key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    var compactPanel:Bool {bool("compactPanel")}
    var panelWidth:CGFloat {compactPanel ? 360:460}
    var panelStyle:PanelStyle {PanelStyle(rawValue:defaults.string(forKey:"NotchDeck.panelStyle") ?? "glass") ?? .glass}
    var autoPlayer: Bool { bool("autoPlayer") }
    var memoryThreshold: Double { min(99,max(50,number("memoryThreshold",fallback:85))) }
    var cpuThreshold: Double { min(100,max(50,number("cpuThreshold",fallback:85))) }
    var temperatureThreshold: Double { min(110,max(50,number("temperatureThreshold",fallback:85))) }
    var batteryThreshold: Int { Int(min(50,max(5,number("batteryThreshold",fallback:20)))) }
    @discardableResult func addApplication(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.pathExtension.lowercased()=="app", FileManager.default.fileExists(atPath:path),
              !applications.contains(where: { $0.path==path }),
              !Item.allCases.contains(where: { $0.appPath==path }) else { return false }
        let name = Bundle(url:url)?.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        applications.append(AppShortcut(id:UUID().uuidString,path:path,name:name))
        saveApps(); return true
    }
    func removeApplication(_ id: String) { applications.removeAll { $0.id==id }; saveApps() }
    func moveApplication(_ id: String, by delta: Int) {
        guard let i=applications.firstIndex(where:{$0.id==id}), applications.indices.contains(i+delta) else {return}
        applications.swapAt(i,i+delta); saveApps()
    }
    private func saveApps() {
        defaults.set(try? JSONEncoder().encode(applications),forKey:"NotchDeck.applications")
        NotificationCenter.default.post(name:Self.didChange,object:nil)
    }
}

final class PreferencesView: NSView, NSTextFieldDelegate {
    private let tabs = NSTabView()
    private var appList: NSView!
    private var controls: [String:NSControl] = [:]
    var onDemo: (() -> Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true;layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor
        tabs.frame=bounds.insetBy(dx:16,dy:16)
        tabs.autoresizingMask=[.width,.height]
        addSubview(tabs)
        buildTabs()
        NotificationCenter.default.addObserver(forName:Preferences.didChange,object:nil,queue:.main) { [weak self] _ in self?.rebuildApplications() }
        NotificationCenter.default.addObserver(forName:Config.didChange,object:nil,queue:.main) { [weak self] _ in self?.syncItems(); self?.rebuildApplications() }
        // Смена языка: вкладки пересоздаются на месте, окно не перезапускается.
        NotificationCenter.default.addObserver(forName:L10n.didChange,object:nil,queue:.main) { [weak self] _ in self?.buildTabs() }
    }
    required init?(coder:NSCoder) {fatalError()}
    private func buildTabs() {
        while tabs.numberOfTabViewItems > 0 { tabs.removeTabViewItem(tabs.tabViewItem(at:0)) }
        controls.removeAll();appList=nil;stylePreview=nil;styleDescription=nil
        makeGeneral(); makeKeyboard(); makeApplications(); makeButtons(); makeAppearance(); makeBehavior(); makeAlerts()
    }
    private func tab(_ name:String)->NSView {
        let item=NSTabViewItem(identifier:name);item.label=name
        let view=FlippedView(frame:NSRect(x:0,y:0,width:560,height:450))
        item.view=view;tabs.addTabViewItem(item);return view
    }
    private func text(_ title:String,at point:NSPoint,in view:NSView,size:CGFloat=12)->NSTextField {
        let label=NSTextField(wrappingLabelWithString:title)
        label.font = .systemFont(ofSize:size); label.frame=NSRect(x:point.x,y:point.y,width:520,height:size>=15 ? 26:56)
        view.addSubview(label);return label
    }
    private func button(_ title:String,frame:NSRect,in view:NSView,action:Selector,id:String?=nil)->NSButton {
        let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;b.frame=frame
        b.identifier=id.map { NSUserInterfaceItemIdentifier($0) };view.addSubview(b);return b
    }
    private func toggle(_ title:String,key:String,y:CGFloat,in view:NSView,value:Bool?=nil) {
        let b=NSButton(checkboxWithTitle:title,target:self,action:#selector(toggled(_:)))
        b.identifier=NSUserInterfaceItemIdentifier(key)
        b.state=(value ?? Preferences.shared.bool(key)) ? .on:.off
        b.frame=NSRect(x:18,y:y,width:520,height:24);view.addSubview(b);controls[key]=b
    }
    // MARK: - Общие
    private func makeGeneral() {
        let view=tab(L("Общие"))
        _=text(L("Настройки приложения"),at:NSPoint(x:18,y:16),in:view,size:16)
        let label=NSTextField(labelWithString:L("Язык интерфейса"))
        label.font = .systemFont(ofSize:13,weight:.semibold);label.frame=NSRect(x:18,y:66,width:520,height:20);view.addSubview(label)
        let menu=NSPopUpButton(frame:NSRect(x:18,y:92,width:280,height:30),pullsDown:false)
        for language in AppLanguage.allCases {menu.addItem(withTitle:language.nativeTitle);menu.lastItem?.representedObject=language.rawValue}
        menu.selectItem(at:AppLanguage.allCases.firstIndex(of:L10n.shared.mode) ?? 0)
        menu.target=self;menu.action=#selector(languageChanged(_:));view.addSubview(menu)
        _=text(L("Язык применяется сразу и сохраняется. По умолчанию — язык системы."),at:NSPoint(x:18,y:132),in:view)
        _=text(L("Требования: Apple Silicon и macOS 26 или новее."),at:NSPoint(x:18,y:206),in:view)
        _=button(L("Завершить NotchDeck"),frame:NSRect(x:18,y:300,width:240,height:32),in:view,action:#selector(quitApplication),id:"quitApplication")
    }
    @objc private func quitApplication() {NSApp.terminate(nil)}
    @objc private func languageChanged(_ sender:NSPopUpButton) {
        guard let raw=sender.selectedItem?.representedObject as? String,let language=AppLanguage(rawValue:raw) else{return}
        L10n.shared.set(language)
    }
    private func makeKeyboard() {
        let item = NSTabViewItem(identifier: "keyboard")
        item.label = L("Клавиатура")
        item.view = KeyboardModeSettingsView(frame: NSRect(x:0,y:0,width:560,height:450))
        tabs.addTabViewItem(item)
    }
    // MARK: - Приложения
    private func makeApplications() {
        let view=tab(L("Приложения"))
        _=text(L("Приложения в чёлке"),at:NSPoint(x:18,y:16),in:view,size:16)
        _=text(L("Добавляй приложения, убирай их из панели и меняй порядок. Удаление из списка не удаляет приложение с Mac."),at:NSPoint(x:18,y:48),in:view)
        _=button(L("Добавить приложение…"),frame:NSRect(x:18,y:98,width:220,height:30),in:view,action:#selector(addApp))
        _=button(L("Профили панели…"),frame:NSRect(x:258,y:98,width:220,height:30),in:view,action:#selector(openProfiles))
        let scroll=NSScrollView(frame:NSRect(x:18,y:142,width:524,height:280))
        scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
        appList=FlippedView(frame:NSRect(x:0,y:0,width:500,height:280))
        scroll.documentView=appList;view.addSubview(scroll);rebuildApplications()
    }
    private func rebuildApplications() {
        guard let appList else{return};appList.subviews.forEach{$0.removeFromSuperview()}
        var y:CGFloat=10
        for item in Item.allCases where item.isApp {
            let b=NSButton(checkboxWithTitle:item.title,target:self,action:#selector(itemToggled(_:)))
            b.identifier=NSUserInterfaceItemIdentifier(item.rawValue);b.state=Config.shared.hidden.contains(item.rawValue) ? .off:.on
            b.frame=NSRect(x:12,y:y,width:420,height:26);appList.addSubview(b);y+=34
        }
        for (index,app) in Preferences.shared.applications.enumerated() {
            let icon=NSImageView(frame:NSRect(x:12,y:y,width:24,height:24));icon.image=NSWorkspace.shared.icon(forFile:app.path);appList.addSubview(icon)
            let name=NSTextField(labelWithString:app.name);name.frame=NSRect(x:44,y:y+4,width:220,height:20);name.toolTip=app.path;appList.addSubview(name)
            let up=button("↑",frame:NSRect(x:276,y:y,width:36,height:26),in:appList,action:#selector(shortcutUp(_:)),id:app.id);up.isEnabled=index>0
            let down=button("↓",frame:NSRect(x:316,y:y,width:36,height:26),in:appList,action:#selector(shortcutDown(_:)),id:app.id);down.isEnabled=index+1<Preferences.shared.applications.count
            _=button(L("Убрать"),frame:NSRect(x:364,y:y,width:92,height:26),in:appList,action:#selector(removeApp(_:)),id:app.id);y+=36
        }
        appList.frame.size.height=max(280,y+10)
    }
    private func makeButtons() {
        let view=tab(L("Кнопки"))
        _=text(L("Кнопки и показатели"),at:NSPoint(x:18,y:16),in:view,size:16)
        _=text(L("Выбери, что показывать в развёрнутой панели."),at:NSPoint(x:18,y:48),in:view)
        let items=Item.allCases.filter{!$0.isApp}
        let rows=Int(ceil(Double(items.count)/2))
        let gap=min(CGFloat(30),CGFloat(280)/CGFloat(max(1,rows)))
        for (i,item) in items.enumerated() {
            let b=NSButton(checkboxWithTitle:item.title,target:self,action:#selector(itemToggled(_:)))
            b.identifier=NSUserInterfaceItemIdentifier(item.rawValue);b.state=Config.shared.hidden.contains(item.rawValue) ? .off:.on
            b.frame=NSRect(x:18+CGFloat(i/rows)*260,y:92+CGFloat(i%rows)*gap,width:245,height:24)
            controls["item:"+item.rawValue]=b;view.addSubview(b)
        }
        _=button(L("Вернуть все кнопки"),frame:NSRect(x:18,y:386,width:210,height:30),in:view,action:#selector(resetItems))
    }
    private func syncItems() {
        for item in Item.allCases { (controls["item:"+item.rawValue] as? NSButton)?.state=Config.shared.hidden.contains(item.rawValue) ? .off:.on }
    }
    private var stylePreview:NotchBackgroundView?
    private var styleDescription:NSTextField?
    private func makeAppearance() {
        let view=tab(L("Дизайн"))
        _=text(L("Оформление панели"),at:NSPoint(x:18,y:16),in:view,size:16)
        toggle(L("Компактная панель (рекомендуется)"),key:"compactPanel",y:62,in:view)
        _=text(L("Компактная ширина — 360 pt. Высота всегда подстраивается под содержимое, без пустого пространства снизу."),at:NSPoint(x:38,y:96),in:view)
        let menu=NSPopUpButton(frame:NSRect(x:18,y:164,width:260,height:30),pullsDown:false)
        for style in PanelStyle.allCases {menu.addItem(withTitle:style.title);menu.lastItem?.representedObject=style.rawValue}
        menu.selectItem(at:PanelStyle.allCases.firstIndex(of:Preferences.shared.panelStyle) ?? 0)
        menu.target=self;menu.action=#selector(styleChanged(_:));view.addSubview(menu)
        let description=text(Preferences.shared.panelStyle.detail,at:NSPoint(x:18,y:210),in:view)
        styleDescription=description
        let preview=NotchBackgroundView(frame:NSRect(x:92,y:288,width:360,height:112))
        let title=NSTextField(labelWithString:"NotchDeck")
        title.font = .systemFont(ofSize:15,weight:.semibold);title.textColor = PanelPalette.foreground
        title.frame=NSRect(x:20,y:66,width:300,height:24)
        let subtitle=NSTextField(labelWithString:L("RAM  17,3 ГБ     ·     Батарея  46%"))
        subtitle.font = .systemFont(ofSize:12);subtitle.textColor=PanelPalette.gray(1,alpha:0.8)
        subtitle.frame=NSRect(x:20,y:32,width:320,height:22)
        preview.addSubview(title);preview.addSubview(subtitle);view.addSubview(preview);stylePreview=preview
        _=text(L("Выбранный стиль применяется сразу и сохраняется после перезапуска."),at:NSPoint(x:18,y:416),in:view)
    }
    @objc private func styleChanged(_ sender:NSPopUpButton) {
        guard let raw=sender.selectedItem?.representedObject as? String,let style=PanelStyle(rawValue:raw) else{return}
        Preferences.shared.set(raw,for:"panelStyle")
        stylePreview?.applyStyle();styleDescription?.stringValue=style.detail
    }

    private func makeBehavior() {
        let view=tab(L("Поведение"))
        _=text(L("Поведение чёлки"),at:NSPoint(x:18,y:16),in:view,size:16)
        toggle(L("Заменять системный индикатор яркости и громкости"),key:"hudEnabled",y:64,in:view)
        toggle(L("Автоматически открывать плеер при воспроизведении"),key:"autoPlayer",y:106,in:view)
        _=text(L("Во время воспроизведения виден компактный плеер. Наведи курсор, чтобы открыть всю панель. После паузы он свернётся через 3 секунды."),at:NSPoint(x:38,y:140),in:view)
        toggle(L("Показывать чёлку на скриншотах"),key:"showInCapture",y:208,in:view)
        toggle(L("Запускать при входе"),key:"launchAtLogin",y:250,in:view,value:LaunchAtLogin.isEnabled)
        toggle(L("История буфера обмена — только в памяти до выхода"),key:"clipboardHistory",y:282,in:view,value:Preferences.shared.bool("clipboardHistory",fallback:false))
        _=button(L("Быстрый тест чёлки — 12 секунд"),frame:NSRect(x:18,y:320,width:340,height:34),in:view,action:#selector(demo))
        _=button(L("Тест зарядки"),frame:NSRect(x:372,y:320,width:170,height:34),in:view,action:#selector(chargeDemo))
        _=text(L("Демо показывает RAM, батарею, CPU и плеер. Настоящая нагрузка, заряд и громкость не меняются."),at:NSPoint(x:18,y:368),in:view)
    }
    private func makeAlerts() {
        let view=tab(L("Предупреждения"))
        _=text(L("Красное свечение"),at:NSPoint(x:18,y:16),in:view,size:16)
        let rows:[(String,String,String,Double,Double,Double)] = [
            (L("Оперативная память"),"memoryAlerts","memoryThreshold",85,50,99),
            (L("Загрузка процессора"),"cpuAlerts","cpuThreshold",85,50,100),
            (L("Температура процессора, °C"),"temperatureAlerts","temperatureThreshold",85,50,110),
            (L("Низкий заряд батареи, %"),"batteryAlerts","batteryThreshold",20,5,50)]
        for (i,row) in rows.enumerated() {
            let y=CGFloat(66+i*66)
            toggle(row.0,key:row.1,y:y,in:view)
            let field=NSTextField(frame:NSRect(x:410,y:y,width:56,height:26))
            let formatter=NumberFormatter();formatter.minimum=NSNumber(value:row.4);formatter.maximum=NSNumber(value:row.5);formatter.maximumFractionDigits=0
            field.delegate=self;field.formatter=formatter;field.integerValue=Int(Preferences.shared.number(row.2,fallback:row.3));field.identifier=NSUserInterfaceItemIdentifier(row.2);field.target=self;field.action=#selector(thresholdChanged(_:));view.addSubview(field)
            let stepper=NSStepper(frame:NSRect(x:476,y:y,width:18,height:26));stepper.minValue=row.4;stepper.maxValue=row.5;stepper.increment=1;stepper.doubleValue=field.doubleValue;stepper.identifier=field.identifier;stepper.target=self;stepper.action=#selector(stepped(_:));view.addSubview(stepper)
            controls[row.2]=field;controls[row.2+":stepper"]=stepper
        }
        _=text(L("CPU: предупреждение после 10 секунд высокой нагрузки. Батарея: только без зарядки. Приоритет: батарея → температура → RAM → CPU. При нормализации свечение гаснет."),at:NSPoint(x:18,y:348),in:view)
        _=button(L("Показать тест предупреждений"),frame:NSRect(x:18,y:404,width:300,height:30),in:view,action:#selector(demo))
    }
    func controlTextDidEndEditing(_ notification:Notification) {
        if let field=notification.object as? NSTextField {thresholdChanged(field)}
    }
    func renderTabs(to directory:String) {
        try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        for i in 0..<tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at:i);layoutSubtreeIfNeeded();displayIfNeeded()
            guard let rep=bitmapImageRepForCachingDisplay(in:bounds) else {continue}
            cacheDisplay(in:bounds,to:rep)
            if let data=rep.representation(using:.png,properties:[:]) {
                try? data.write(to:URL(fileURLWithPath:directory).appendingPathComponent("settings-\(i).png"))
            }
        }
    }
    @objc private func openProfiles() {ProfileManager.shared.show()}
    @objc private func addApp() {
        let panel=NSOpenPanel();panel.title=L("Добавить приложение в NotchDeck");panel.allowedContentTypes=[.applicationBundle]
        panel.directoryURL=URL(fileURLWithPath:"/Applications");panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        panel.beginSheetModal(for:window!) { response in
            if response == .OK { for url in panel.urls {
                if let item=Item.allCases.first(where:{$0.appPath==url.path}) {Config.shared.unhide(item)}
                else {_=Preferences.shared.addApplication(url)}
            }}
        }
    }
    @objc private func removeApp(_ b:NSButton) {if let id=b.identifier?.rawValue {Preferences.shared.removeApplication(id)}}
    @objc private func shortcutUp(_ b:NSButton) {if let id=b.identifier?.rawValue {Preferences.shared.moveApplication(id,by:-1)}}
    @objc private func shortcutDown(_ b:NSButton) {if let id=b.identifier?.rawValue {Preferences.shared.moveApplication(id,by:1)}}
    @objc private func itemToggled(_ b:NSButton) {guard let raw=b.identifier?.rawValue,let item=Item(rawValue:raw) else{return};if b.state == .on {Config.shared.unhide(item)} else {Config.shared.hide(item)}}
    @objc private func toggled(_ b:NSButton) {
        guard let key=b.identifier?.rawValue else{return}
        if key=="launchAtLogin" {LaunchAtLogin.set(b.state == .on);b.state=LaunchAtLogin.isEnabled ? .on:.off;return}
        Preferences.shared.set(b.state == .on,for:key)
        if key=="showInCapture" {NotificationCenter.default.post(name:.init("NotchDeck.sharingChanged"),object:nil)}
    }
    @objc private func thresholdChanged(_ field:NSTextField) {
        guard let key=field.identifier?.rawValue,let step=controls[key+":stepper"] as? NSStepper else{return}
        let value=min(step.maxValue,max(step.minValue,field.doubleValue));field.doubleValue=value;step.doubleValue=value;Preferences.shared.set(value,for:key)
    }
    @objc private func stepped(_ step:NSStepper) {guard let key=step.identifier?.rawValue,let field=controls[key] as? NSTextField else{return};field.doubleValue=step.doubleValue;Preferences.shared.set(step.doubleValue,for:key)}
    @objc private func resetItems() {Config.shared.resetAll()}
    @objc private func chargeDemo() {NotificationCenter.default.post(name:.init("NotchDeck.chargeTest"),object:nil)}
    @objc private func demo() {window?.makeFirstResponder(nil);onDemo?()}
}
