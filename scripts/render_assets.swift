import AppKit

// Compile as a separate executable with Sources except main.swift.
// The renderer has its own preference domain and never reads the installed app's settings.
_ = NSApplication.shared
let dir=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try! FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
let d=UserDefaults.standard
let domain=ProcessInfo.processInfo.processName
d.removePersistentDomain(forName:domain)
defer {d.removePersistentDomain(forName:domain)}
ProfileLayout.preset(visible:[.cpu,.ram,.temp,.battery,.net,.disk,.quickNote,.screenshot,.record,.preferences],style:.midnight).apply(d)
let snapshot=MetricSnapshot(cpu:18,ramUsed:10.2,ramTotal:24,temp:43,battery:76,down:2457.6,up:184.3,diskFree:256,uptime:"2ч 15м",networkReady:true)
func save(_ view:NSView,_ name:String,background:Bool=false) {
    view.layoutSubtreeIfNeeded();view.displayIfNeeded()
    let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.cacheDisplay(in:view.bounds,to:rep)
    if !background {
        try! rep.representation(using:.png,properties:[:])!.write(to:dir.appendingPathComponent(name));return
    }
    let canvas=NSImage(size:view.bounds.size)
    canvas.lockFocus()
    NSColor(white:0.94,alpha:1).setFill();NSRect(origin:.zero,size:view.bounds.size).fill()
    NSColor(white:0.025,alpha:1).setFill()
    NSRect(x:0,y:view.bounds.height-32,width:view.bounds.width,height:32).fill()
    NSImage(cgImage:rep.cgImage!,size:view.bounds.size).draw(in:NSRect(origin:.zero,size:view.bounds.size))
    canvas.unlockFocus()
    let output=NSBitmapImageRep(data:canvas.tiffRepresentation!)!
    try! output.representation(using:.png,properties:[:])!.write(to:dir.appendingPathComponent(name))
}
for id in ["personal","work","video","recording"] {
    _ = ProfileStore.shared.select(id)
    let view=PanelContentView(frame:NSRect(x:0,y:0,width:360,height:400))
    let w=NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false)
    w.contentView=view
    view.applyAppearance()
    if id=="video" {view.setMedia(NowPlaying(title:"Night Walk",artist:"NotchDeck · Demo",duration:240,elapsed:86,playing:true,source:"Demo"))}
    view.setFrameSize(NSSize(width:360,height:view.contentHeight()))
    view.layoutSubtreeIfNeeded();view.update(snapshot)
    save(view,"profile-\(id).png")
}
_ = ProfileStore.shared.select("personal")
for (kind,name) in [(LevelKind.brightness,"brightness"),(.volume,"volume")] {
    let view=IslandView(frame:NSRect(x:0,y:0,width:760,height:72))
    view.set(kind:kind,value:0.72,muted:false,animated:false)
    save(view,"hud-\(name).png",background:true)
    var level=HUDMotion();level.target=0.72
    for i in 0..<44 {
        if i==30 {level.target=0}
        level.advance(1.0/24)
        view.setAnimationProgressForRender(CGFloat(max(0,level.value)))
        save(view,String(format:"\(name)-%03d.png",i),background:true)
    }
}
for (alert,name) in [(NotchAlert.memory,"memory"),(.battery,"battery")] {
    let view=IslandView(frame:NSRect(x:0,y:0,width:760,height:72))
    view.setWarning(alert,animated:false)
    save(view,"alert-\(name).png",background:true)
}
for i in 0..<36 {
    let view=IslandView(frame:NSRect(x:0,y:0,width:760,height:72))
    view.setChargeRenderPhase(Double(i)/36)
    save(view,String(format:"charge-%03d.png",i),background:true)
}
let settings=PreferencesView(frame:NSRect(x:0,y:0,width:620,height:510))
let settingsWindow=NSWindow(contentRect:settings.bounds,styleMask:.titled,backing:.buffered,defer:false)
settingsWindow.contentView=settings
settings.renderTabs(to:dir.appendingPathComponent("settings").path)
print("Public demo assets rendered; no personal settings loaded")
