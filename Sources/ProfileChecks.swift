import AppKit

enum ProfileChecks {
    static func run() {
        func check(_ ok:Bool,_ message:String) {if !ok {fputs("PROFILES FAIL: \(message)\n",stderr);exit(1)}}
        let suite="NotchDeck.profiles.test."+UUID().uuidString
        let d=UserDefaults(suiteName:suite)!
        defer {d.removePersistentDomain(forName:suite)}
        let app=AppShortcut(id:"example",path:"/Applications/Example.app",name:"Example")
        d.set(try! JSONEncoder().encode([app]),forKey:"NotchDeck.applications")
        d.set(["cpu","net"],forKey:"NotchDeck.hiddenItems")
        d.set(["ram","battery","quickNote"],forKey:"NotchDeck.order")
        d.set("midnight",forKey:"NotchDeck.panelStyle");d.set(false,forKey:"NotchDeck.compactPanel")
        d.set(false,forKey:"NotchDeck.autoPlayer")
        d.set(true,forKey:"NotchDeck.recordMicrophone");d.set(false,forKey:"NotchDeck.clipboardHistory")
        d.set("local note",forKey:"NotchDeck.quickNotes")
        let initial=ProfileLayout.read(d)
        let store=ProfileStore(defaults:d,runtime:false)
        check(store.activeID=="personal" && store.active.layout==initial,"initial configuration lost")
        check(store.profiles.count==4,"built-in profiles missing")
        check(store.select("work"),"work selection")
        check(ProfileLayout.read(d).applications==[app],"work shortcuts")
        d.set(["ram"],forKey:"NotchDeck.hiddenItems");d.set("aurora",forKey:"NotchDeck.panelStyle")
        store.saveCurrent();let work=ProfileLayout.read(d)
        check(store.select("video"),"video selection")
        check(ProfileLayout.read(d).applications.isEmpty,"video inherited unrelated shortcuts")
        check(!store.active.layout.hidden.contains("mediaToggle"),"video controls missing")
        d.set(false,forKey:"NotchDeck.autoPlayer");store.saveCurrent()
        check(store.select("recording"),"record selection")
        check(!store.active.layout.hidden.contains("record"),"record button missing")
        check(d.bool(forKey:"NotchDeck.recordMicrophone") && !d.bool(forKey:"NotchDeck.clipboardHistory"),"switch changes microphone/privacy")
        check(d.string(forKey:"NotchDeck.quickNotes")=="local note","notes changed")
        check(store.select("work") && ProfileLayout.read(d)==work,"per-profile edits not restored")
        let reopened=ProfileStore(defaults:d,runtime:false)
        check(reopened.activeID=="work" && reopened.active.layout==work,"restart persistence")
        guard let duplicate=store.duplicate(name:"  Тестовый профиль  ") else {check(false,"copy failed");return}
        check(store.active.name=="Тестовый профиль" && store.active.layout==work,"copy differs")
        check(store.rename(duplicate,to:"Проверка") && store.active.name=="Проверка","rename")
        check(!store.rename(duplicate,to:"  ") && store.duplicate(name:"")==nil,"empty names accepted")
        check(store.remove(duplicate) && store.profiles.allSatisfy{$0.id != duplicate},"remove active")
        guard let restored=store.restoreOriginal() else {check(false,"backup missing");return}
        check(store.activeID==restored && ProfileLayout.read(d)==initial,"initial snapshot not restored")
        check(!store.select("does-not-exist"),"unknown profile accepted")
        while store.profiles.count>1 {check(store.remove(store.profiles.last!.id),"remove failed")}
        check(!store.remove(store.activeID),"last profile deleted")
        d.set(Data("broken-json".utf8),forKey:"NotchDeck.profiles.v2")
        let repaired=ProfileStore(defaults:d,runtime:false)
        check(repaired.profiles.count==4,"corrupt profile storage not recovered")
        var malformed=initial;malformed.hidden=["unknown","ram","ram"];malformed.order=["unknown","ram","ram"];malformed.style="missing"
        let normalized=malformed.normalized()
        check(normalized.hidden==["ram"] && Set(normalized.order).count==Item.allCases.count && normalized.style=="glass","unknown/stale values")
        print("PROFILES PASS: migration, independent apps/layout/style, persistence, clone/rename/delete, original backup, privacy isolation, corrupt storage recovery")
    }
}
