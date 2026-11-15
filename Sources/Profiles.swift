import AppKit

// Profile data stays in the current user's preferences; no app lists ship in the bundle.
struct ProfileLayout:Codable,Equatable {
    var hidden:[String]
    var order:[String]
    var applications:[AppShortcut]
    var style:String
    var compact:Bool
    var autoPlayer:Bool
    static func read(_ defaults:UserDefaults)->Self {
        Self(hidden:defaults.stringArray(forKey:"NotchDeck.hiddenItems") ?? Config.cleanHiddenItems,
             order:defaults.stringArray(forKey:"NotchDeck.order") ?? Item.allCases.map(\.rawValue),
             applications:defaults.data(forKey:"NotchDeck.applications").flatMap {try? JSONDecoder().decode([AppShortcut].self,from:$0)} ?? [],
             style:defaults.string(forKey:"NotchDeck.panelStyle") ?? "glass",
             compact:(defaults.object(forKey:"NotchDeck.compactPanel") as? Bool) ?? true,
             autoPlayer:(defaults.object(forKey:"NotchDeck.autoPlayer") as? Bool) ?? true).normalized()
    }
    func normalized()->Self {
        let known=Set(Item.allCases.map(\.rawValue))
        var result=self;result.hidden=Array(Set(hidden).intersection(known)).sorted()
        var seen=Set<String>();result.order=order.filter {known.contains($0) && seen.insert($0).inserted}
        result.order += Item.allCases.map(\.rawValue).filter {!seen.contains($0)}
        result.style=PanelStyle(rawValue:style)?.rawValue ?? "glass"
        return result
    }
    static func preset(visible:[Item],style:PanelStyle,applications:[AppShortcut]=[])->Self {
        Self(hidden:Item.allCases.filter {!visible.contains($0)}.map(\.rawValue),order:Item.allCases.map(\.rawValue),applications:applications,style:style.rawValue,compact:true,autoPlayer:true).normalized()
    }
    func apply(_ defaults:UserDefaults) {
        defaults.set(hidden,forKey:"NotchDeck.hiddenItems");defaults.set(order,forKey:"NotchDeck.order")
        defaults.set(try? JSONEncoder().encode(applications),forKey:"NotchDeck.applications")
        defaults.set(style,forKey:"NotchDeck.panelStyle");defaults.set(compact,forKey:"NotchDeck.compactPanel")
        defaults.set(autoPlayer,forKey:"NotchDeck.autoPlayer");defaults.set(true,forKey:"NotchDeck.actionsR39Migrated")
    }
}
struct DeckProfile:Codable,Equatable,Identifiable {
    var id:String
    var name:String
    var symbol:String
    var layout:ProfileLayout
}

final class ProfileStore {
    static let shared=ProfileStore()
    static let didChange=Notification.Name("NotchDeck.profilesChanged")
    private let defaults:UserDefaults
    private let runtime:Bool
    private var applying=false
    private var observers:[NSObjectProtocol]=[]
    private(set) var profiles:[DeckProfile]
    private(set) var activeID:String
    var active:DeckProfile {profiles.first(where:{$0.id==activeID}) ?? profiles[0]}
    init(defaults:UserDefaults = .standard,runtime:Bool=true) {
        self.defaults=defaults;self.runtime=runtime
        let initial=ProfileLayout.read(defaults)
        let decoded=defaults.data(forKey:"NotchDeck.profiles.v2").flatMap {try? JSONDecoder().decode([DeckProfile].self,from:$0)} ?? []
        var seen=Set<String>()
        profiles=Array(decoded.filter {!$0.id.isEmpty && seen.insert($0.id).inserted}.prefix(32)).map {
            var p=$0;p.layout=p.layout.normalized();p.name=Self.cleanName(p.name);if p.name.isEmpty {p.name="Профиль"};return p
        }
        if profiles.isEmpty {
            profiles=[
                DeckProfile(id:"personal",name:"Мой профиль",symbol:"person.crop.circle",layout:initial),
                DeckProfile(id:"work",name:"Работа",symbol:"briefcase",layout:.preset(visible:[.ram,.cpu,.battery,.net,.quickNote,.clipboard,.downloads,.preferences],style:.graphite,applications:initial.applications)),
                DeckProfile(id:"video",name:"Видео",symbol:"play.rectangle",layout:.preset(visible:[.battery,.net,.mediaToggle,.volumeMute,.preferences],style:.midnight)),
                DeckProfile(id:"recording",name:"Запись",symbol:"record.circle",layout:.preset(visible:[.ram,.cpu,.disk,.battery,.record,.screenshot,.quickNote,.preferences],style:.neon))]
        }
        let selected=defaults.string(forKey:"NotchDeck.activeProfile.v2") ?? "personal"
        activeID=profiles.contains(where:{$0.id==selected}) ? selected:profiles[0].id
        if defaults.data(forKey:"NotchDeck.profiles.original") == nil {defaults.set(try? JSONEncoder().encode(initial),forKey:"NotchDeck.profiles.original")}
        persist()
        if runtime {
            for name in [Config.didChange,Preferences.didChange] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) {[weak self] _ in self?.saveCurrent()})
            }
        }
    }
    deinit {observers.forEach {NotificationCenter.default.removeObserver($0)}}
    private static func cleanName(_ value:String)->String {String(value.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40))}
    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles),forKey:"NotchDeck.profiles.v2")
        defaults.set(activeID,forKey:"NotchDeck.activeProfile.v2")
    }
    private func emit(selection:Bool=false) {
        if runtime {NotificationCenter.default.post(name:Self.didChange,object:nil,userInfo:["selection":selection])}
    }
    func saveCurrent() {
        guard !applying,let i=profiles.firstIndex(where:{$0.id==activeID}) else{return}
        let state=ProfileLayout.read(defaults)
        guard profiles[i].layout != state else{return}
        profiles[i].layout=state;persist();emit()
    }
    @discardableResult func select(_ id:String)->Bool {
        guard id != activeID,profiles.contains(where:{$0.id==id}) else{return false}
        saveCurrent();activeID=id;applying=true
        active.layout.apply(defaults);persist()
        if runtime {
            Config.shared.reloadFromDefaults();Preferences.shared.reloadFromDefaults()
            NotificationCenter.default.post(name:Config.didChange,object:nil)
            NotificationCenter.default.post(name:Preferences.didChange,object:nil)
        }
        applying=false;emit(selection:true);return true
    }
    @discardableResult func duplicate(name:String)->String? {
        saveCurrent();return create(name:name,layout:active.layout)
    }
    @discardableResult private func create(name:String,layout:ProfileLayout)->String? {
        let clean=Self.cleanName(name);guard !clean.isEmpty,profiles.count<32 else{return nil}
        let id=UUID().uuidString;profiles.append(DeckProfile(id:id,name:clean,symbol:"square.stack",layout:layout))
        persist();_ = select(id);return id
    }
    @discardableResult func rename(_ id:String,to value:String)->Bool {
        let name=Self.cleanName(value);guard !name.isEmpty,let i=profiles.firstIndex(where:{$0.id==id}) else{return false}
        profiles[i].name=name;persist();emit();return true
    }
    @discardableResult func remove(_ id:String)->Bool {
        guard profiles.count>1,profiles.contains(where:{$0.id==id}) else{return false}
        if id==activeID,let next=profiles.first(where:{$0.id != id}) {_ = select(next.id)}
        profiles.removeAll {$0.id==id};persist();emit();return true
    }
    @discardableResult func restoreOriginal()->String? {
        guard let data=defaults.data(forKey:"NotchDeck.profiles.original"),let state=try? JSONDecoder().decode(ProfileLayout.self,from:data) else{return nil}
        saveCurrent();return create(name:"Исходные настройки",layout:state.normalized())
    }
}

enum ProfileInteraction {
    static var menuOpen=false
    static var holdUntil=Date.distantPast
    static var active:Bool {menuOpen || Date()<holdUntil}
}

private final class ProfilePopup:NSPopUpButton {override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}}

final class ProfileHeaderView:NSView,NSMenuDelegate {
    override var isFlipped:Bool {true}
    private let caption=NSTextField(labelWithString:"ПРОФИЛЬ")
    private let profilePopup=ProfilePopup(frame:.zero,pullsDown:false)
    private let manage=FirstMouseButton(title:"…",target:nil,action:nil)
    private var observer:NSObjectProtocol?
    override init(frame:NSRect) {
        super.init(frame:frame)
        caption.font = .systemFont(ofSize:9,weight:.medium);caption.textColor = PanelPalette.gray(0.65,alpha:1)
        profilePopup.font = .systemFont(ofSize:12,weight:.semibold);profilePopup.isBordered=false;profilePopup.appearance=PanelPalette.appearance
        profilePopup.target=self;profilePopup.action=#selector(selected);profilePopup.setAccessibilityLabel("Профиль панели")
        manage.target=self;manage.action=#selector(openManager);manage.isBordered=false;manage.font = .boldSystemFont(ofSize:18);manage.contentTintColor = PanelPalette.foreground;manage.toolTip="Управление профилями"
        addSubview(caption);addSubview(profilePopup);addSubview(manage);reload()
        observer=NotificationCenter.default.addObserver(forName:ProfileStore.didChange,object:nil,queue:.main) {[weak self] _ in self?.reload()}
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
    func reload() {
        profilePopup.appearance=PanelPalette.appearance
        profilePopup.removeAllItems()
        for p in ProfileStore.shared.profiles {
            profilePopup.addItem(withTitle:p.name);profilePopup.lastItem?.representedObject=p.id
            let image=NSImage(systemSymbolName:p.symbol,accessibilityDescription:nil);image?.size=NSSize(width:13,height:13);profilePopup.lastItem?.image=image
            if p.id==ProfileStore.shared.activeID {profilePopup.select(profilePopup.lastItem)}
        }
        profilePopup.menu?.delegate=self
    }
    override func layout() {
        super.layout();caption.frame=NSRect(x:0,y:8,width:63,height:15)
        profilePopup.frame=NSRect(x:67,y:1,width:max(80,bounds.width-100),height:29)
        manage.frame=NSRect(x:bounds.width-30,y:0,width:30,height:28)
    }
    func menuWillOpen(_ menu:NSMenu) {ProfileInteraction.menuOpen=true}
    func menuDidClose(_ menu:NSMenu) {
        ProfileInteraction.menuOpen=false;ProfileInteraction.holdUntil=Date().addingTimeInterval(2)
        NotificationCenter.default.post(name:.init("NotchDeck.profileMenuClosed"),object:nil)
    }
    @objc private func selected() {if let id=profilePopup.selectedItem?.representedObject as? String {_ = ProfileStore.shared.select(id)}}
    @objc private func openManager() {ProfileManager.shared.show()}
}

final class ProfileManager:NSObject,NSWindowDelegate {
    static let shared=ProfileManager()
    private var window:NSWindow?
    private var picker:NSPopUpButton?
    private var summary:NSTextField?
    private var observer:NSObjectProtocol?
    func show() {
        if window == nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:360),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            w.title="Профили NotchDeck · Preview 2";w.isReleasedWhenClosed=false;w.delegate=self;w.center()
            let root=FlippedView(frame:NSRect(x:0,y:0,width:500,height:360));w.contentView=root
            func text(_ title:String,_ y:CGFloat,_ height:CGFloat,_ size:CGFloat=13)->NSTextField {
                let t=NSTextField(wrappingLabelWithString:title);t.frame=NSRect(x:24,y:y,width:452,height:height);t.font = .systemFont(ofSize:size);root.addSubview(t);return t
            }
            _=text("Панель под текущую задачу",20,28,20)
            _=text("Выбери профиль — чёлка сразу покажет его приложения, кнопки, показатели и оформление.",58,44)
            let select=NSPopUpButton(frame:NSRect(x:24,y:112,width:452,height:30),pullsDown:false);select.target=self;select.action=#selector(selected);select.setAccessibilityLabel("Активный профиль");root.addSubview(select);picker=select
            summary=text("",156,52);summary?.textColor = .secondaryLabelColor
            func button(_ title:String,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ action:Selector) {
                let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;b.frame=NSRect(x:x,y:y,width:width,height:30);root.addSubview(b)
            }
            button("Создать копию…",24,218,144,#selector(duplicate))
            button("Переименовать…",178,218,156,#selector(rename))
            button("Удалить…",344,218,132,#selector(remove))
            button("Настроить выбранный профиль…",24,261,290,#selector(settings))
            button("Вернуть исходный…",322,261,154,#selector(restore))
            let note=text("Изменения сохраняются автоматически в выбранный профиль. Разрешения, микрофон и история буфера остаются общими.",307,42,11);note.textColor = .secondaryLabelColor
            window=w
            observer=NotificationCenter.default.addObserver(forName:ProfileStore.didChange,object:nil,queue:.main) {[weak self] _ in self?.reload()}
        }
        reload()
        window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        NotificationCenter.default.post(name:.init("NotchDeck.profilePreview"),object:nil)
    }
    private func reload() {
        let store=ProfileStore.shared;picker?.removeAllItems()
        for p in store.profiles {picker?.addItem(withTitle:p.name);picker?.lastItem?.representedObject=p.id;if p.id==store.activeID {picker?.select(picker?.lastItem)}}
        let layout=store.active.layout;let shown=Item.allCases.filter {!layout.hidden.contains($0.rawValue)}
        summary?.stringValue="Приложения: \(layout.applications.count)  ·  Показатели: \(shown.filter(\.isMetric).count)  ·  Кнопки: \(shown.filter {!$0.isMetric}.count)\nОформление: \(PanelStyle(rawValue:layout.style)?.title ?? "Стекло")"
    }
    private func ask(_ title:String,initial:String,action:(String)->Void) {
        let alert=NSAlert();alert.messageText=title;alert.addButton(withTitle:"Сохранить");alert.addButton(withTitle:"Отмена")
        let field=NSTextField(string:initial);field.frame=NSRect(x:0,y:0,width:300,height:26);alert.accessoryView=field;alert.window.initialFirstResponder=field
        if alert.runModal() == .alertFirstButtonReturn {action(field.stringValue)}
    }
    @objc private func selected() {if let id=picker?.selectedItem?.representedObject as? String {_ = ProfileStore.shared.select(id)}}
    @objc private func duplicate() {ask("Название нового профиля",initial:ProfileStore.shared.active.name+" — копия") {if ProfileStore.shared.duplicate(name:$0)==nil {Signal.post("Укажи имя · максимум 32 профиля",symbol:"square.stack")}}}
    @objc private func rename() {ask("Переименовать профиль",initial:ProfileStore.shared.active.name) {_ = ProfileStore.shared.rename(ProfileStore.shared.activeID,to:$0)}}
    @objc private func remove() {
        let store=ProfileStore.shared;guard store.profiles.count>1 else{Signal.post("Нужен хотя бы один профиль",symbol:"square.stack");return}
        let alert=NSAlert();alert.messageText="Удалить профиль «\(store.active.name)»?";alert.informativeText="Удаляются только настройки этого профиля. Приложения и файлы остаются на Mac.";alert.addButton(withTitle:"Удалить профиль");alert.addButton(withTitle:"Отмена")
        if alert.runModal() == .alertFirstButtonReturn {_ = store.remove(store.activeID)}
    }
    @objc private func restore() {if ProfileStore.shared.restoreOriginal()==nil {Signal.post("Не удалось создать профиль · максимум 32",symbol:"square.stack")}}
    @objc private func settings() {NotificationCenter.default.post(name:.init("NotchDeck.openSettings"),object:nil)}
    func windowWillClose(_ notification:Notification) {ProfileInteraction.holdUntil=Date().addingTimeInterval(2);NotificationCenter.default.post(name:.init("NotchDeck.profileMenuClosed"),object:nil)}
}

enum AppIdentity {
    static var bundleID:String {Bundle.main.bundleIdentifier ?? "com.notchdeck.app"}
    static func notification(_ suffix:String)->Notification.Name {.init(bundleID+"."+suffix)}
}
