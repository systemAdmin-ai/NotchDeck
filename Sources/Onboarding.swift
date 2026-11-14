import AppKit
import ApplicationServices
import CoreGraphics

enum FirstRun {
    static let version=1
    static func completed(in defaults:UserDefaults = .standard)->Bool {defaults.integer(forKey:"NotchDeck.onboardingVersion")>=version}
    static func complete(in defaults:UserDefaults = .standard) {defaults.set(version,forKey:"NotchDeck.onboardingVersion")}
}

final class Onboarding:NSObject,NSWindowDelegate {
    static let shared=Onboarding()
    var onShowPanel:(()->Void)?
    var onDemo:(()->Void)?
    private var window:NSWindow?
    private var page=0
    private var body:FlippedView?
    private var status:NSTextField?
    private var nextButton:NSButton?
    private var backButton:NSButton?
    private var timer:Timer?
    private var selectedStyle=PanelStyle.glass
    private var clipboard=false
    private var login=false
    func showIfNeeded() {if !FirstRun.completed() {show()}}
    func show() {
        page=0;selectedStyle=Preferences.shared.panelStyle
        clipboard=Preferences.shared.bool("clipboardHistory",fallback:false);login=LaunchAtLogin.isEnabled
        if window == nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            w.title="Знакомство с NotchDeck";w.isReleasedWhenClosed=false;w.delegate=self
            w.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
            let root=FlippedView(frame:NSRect(x:0,y:0,width:620,height:500))
            root.wantsLayer=true;root.layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor
            let content=FlippedView(frame:NSRect(x:0,y:0,width:620,height:430));root.addSubview(content);body=content
            let back=NSButton(title:"Назад",target:self,action:#selector(previous));back.frame=NSRect(x:28,y:450,width:100,height:30);root.addSubview(back);backButton=back
            let next=NSButton(title:"Далее",target:self,action:#selector(nextPage));next.bezelStyle = .rounded;next.keyEquivalent="\r";next.frame=NSRect(x:420,y:448,width:172,height:34);root.addSubview(next);nextButton=next
            w.contentView=root;w.center();window=w
        }
        renderPage();NSApp.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil);window?.orderFrontRegardless()
        timer?.invalidate();let t=Timer(timeInterval:1,repeats:true) {[weak self] _ in self?.updatePermissions()};RunLoop.main.add(t,forMode:.common);timer=t
    }
    private func text(_ value:String,x:CGFloat=32,y:CGFloat,width:CGFloat=556,height:CGFloat=50,size:CGFloat=14,bold:Bool=false,color:NSColor = .labelColor) {
        guard let body else{return}
        let field=NSTextField(wrappingLabelWithString:value);field.font = .systemFont(ofSize:size,weight:bold ? .semibold:.regular);field.textColor=color
        field.frame=NSRect(x:x,y:y,width:width,height:height);body.addSubview(field)
    }
    private func button(_ title:String,x:CGFloat=32,y:CGFloat,width:CGFloat=260,action:Selector) {
        let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;b.frame=NSRect(x:x,y:y,width:width,height:32);body?.addSubview(b)
    }
    private func renderPage() {
        body?.subviews.forEach{$0.removeFromSuperview()};status=nil
        text("NOTCHDECK  /  ШАГ \(page+1) ИЗ 4",y:22,height:20,size:11,bold:true,color:.secondaryLabelColor)
        backButton?.isHidden=page==0;nextButton?.title=page==3 ? "Начать пользоваться":"Далее"
        switch page {
        case 0:
            if let path=Bundle.main.path(forResource:"AppIcon",ofType:"icns"),let image=NSImage(contentsOfFile:path) {
                let icon=NSImageView(frame:NSRect(x:32,y:64,width:76,height:76));icon.image=image;body?.addSubview(icon)
            }
            text("Всё важное — у чёлки",x:126,y:70,width:460,height:36,size:25,bold:true)
            text("Компактная панель, которая появляется, когда нужна.",x:126,y:112,width:455,height:45,size:14,color:.secondaryLabelColor)
            text("01   Наведи курсор на чёлку",y:176,height:26,size:17,bold:true)
            text("Показатели, приложения и инструменты раскроются. Уведи курсор — панель свернётся.",y:210,height:48)
            text("02   Добавь своё",y:274,height:26,size:17,bold:true)
            text("Шестерёнка → Приложения и Кнопки. Долгое нажатие на плитку открывает режим редактирования.",y:308,height:48)
            text("03   Всё можно пройти позже",y:368,height:24,size:17,bold:true)
            text("Меню NotchDeck в строке меню → «Знакомство с NotchDeck…».",y:398,height:30,size:12,color:.secondaryLabelColor)
        case 1:
            text("Разрешения — по необходимости",y:65,height:38,size:24,bold:true)
            text("Панель и показатели работают без дополнительных разрешений. Их можно выдать позже в системных настройках.",y:112,height:52,color:.secondaryLabelColor)
            text("Яркость и громкость",y:178,height:26,size:17,bold:true)
            text("Для замены системного индикатора нужен доступ к управлению устройством / Универсальному доступу. Он позволяет приложению обрабатывать клавиши яркости и звука.",y:208,height:64,size:13)
            button("Настройки доступа к клавишам…",y:278,action:#selector(openAccessibility))
            text("Запись экрана и звук",y:326,height:25,size:17,bold:true)
            text("Доступ к экрану нужен только для снимков и записи. Микрофон запрашивается отдельно, когда ты сам включишь его перед записью.",y:357,height:48,size:13)
            button("Настройки записи экрана…",x:320,y:278,width:268,action:#selector(openScreen))
            let field=NSTextField(labelWithString:"");field.font = .systemFont(ofSize:11);field.textColor = .secondaryLabelColor;field.frame=NSRect(x:32,y:409,width:556,height:18);body?.addSubview(field);status=field;updatePermissions()
        case 2:
            text("Настрой под себя",y:65,height:38,size:25,bold:true)
            text("Чистый старт: без чужих приложений, заметок и истории.",y:112,height:42,color:.secondaryLabelColor)
            text("Оформление",y:172,height:24,size:17,bold:true)
            let menu=NSPopUpButton(frame:NSRect(x:32,y:208,width:270,height:30),pullsDown:false)
            menu.addItems(withTitles:PanelStyle.allCases.map(\.title));menu.selectItem(at:PanelStyle.allCases.firstIndex(of:selectedStyle) ?? 0);menu.target=self;menu.action=#selector(styleChanged(_:));body?.addSubview(menu)
            let clip=NSButton(checkboxWithTitle:"Включить историю буфера обмена",target:self,action:#selector(clipboardChanged(_:)));clip.state=clipboard ? .on:.off;clip.frame=NSRect(x:32,y:268,width:550,height:25);body?.addSubview(clip)
            text("Выключена по умолчанию. Если включить, последние 30 записей хранятся только в памяти до выхода из приложения.",y:300,height:50,size:12,color:.secondaryLabelColor)
            let auto=NSButton(checkboxWithTitle:"Запускать NotchDeck при входе",target:self,action:#selector(loginChanged(_:)));auto.state=login ? .on:.off;auto.frame=NSRect(x:32,y:367,width:550,height:25);body?.addSubview(auto)
        default:
            text("Готово. Попробуем?",y:65,height:38,size:25,bold:true)
            text("Музыка и видео",y:124,height:26,size:17,bold:true)
            text("При воспроизведении появляется компактный плеер. Обложка зависит от того, передаёт ли её приложение в macOS.",y:158,height:48)
            text("Запись экрана",y:224,height:26,size:17,bold:true)
            text("Нажми запись → выбери область, микрофон и звук → Начать. Красная кнопка с таймером показывает запись; повторное нажатие останавливает её. Файлы: Рабочий стол → Screenshots.",y:258,height:68,size:13)
            text("Зарядка и предупреждения",y:340,height:26,size:17,bold:true)
            text("Подключение питания — зелёный импульс. Высокая нагрузка или низкий заряд — красное свечение. Пороги меняются в настройках.",y:371,height:45,size:12,color:.secondaryLabelColor)
        }
    }
    private func updatePermissions() {guard page==1 else{return};status?.stringValue="Клавиши: \(AXIsProcessTrusted() ? "доступ есть":"не разрешено")  ·  Экран: \(CGPreflightScreenCaptureAccess() ? "доступ есть":"не разрешено")"}
    @objc private func previous() {page=max(0,page-1);renderPage()}
    @objc private func nextPage() {
        if page<3 {page+=1;renderPage();return}
        Preferences.shared.set(selectedStyle.rawValue,for:"panelStyle")
        Preferences.shared.set(clipboard,for:"clipboardHistory")
        if clipboard {Config.shared.unhide(.clipboard)}
        if login != LaunchAtLogin.isEnabled {LaunchAtLogin.set(login)}
        FirstRun.complete();timer?.invalidate();timer=nil;window?.close();onShowPanel?()
    }
    @objc private func styleChanged(_ sender:NSPopUpButton) {selectedStyle=PanelStyle.allCases[sender.indexOfSelectedItem]}
    @objc private func clipboardChanged(_ sender:NSButton) {clipboard=sender.state == .on}
    @objc private func loginChanged(_ sender:NSButton) {login=sender.state == .on}
    @objc private func openAccessibility() {open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")}
    @objc private func openScreen() {open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")}
    private func open(_ string:String) {if let url=URL(string:string) {NSWorkspace.shared.open(url)}}
    func windowWillClose(_ notification:Notification) {timer?.invalidate();timer=nil}
    func render(to directory:String) {
        show();timer?.invalidate();timer=nil
        try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        guard let view=window?.contentView else{return}
        for i in 0..<4 {
            page=i;renderPage();view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{continue}
            view.cacheDisplay(in:view.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) {try? data.write(to:URL(fileURLWithPath:directory).appendingPathComponent("onboarding-\(i+1).png"))}
        }
        window?.orderOut(nil)
    }
}
