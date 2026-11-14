import AppKit
import AVFoundation

/// Owns the recording process and publishes its lifecycle on the main thread.
/// A region is chosen before launch, so the recording clock never includes selection time.
final class ScreenRecording {
    private var process:Process?
    private var timer:Timer?
    private var began:Date?
    private var finished=false
    let url:URL
    var onChange:(()->Void)?
    var onFinish:((Error?)->Void)?
    private(set) var started=false
    var duration:Double {began.map {max(0,Date().timeIntervalSince($0))} ?? 0}
    init(url:URL) {self.url=url}
    func start(systemAudio:Bool,microphone:Bool,rect:CGRect?,seconds:Int?) {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
        var args=["-v","-x"]
        if systemAudio {args.append("-A")};if microphone {args.append("-g")}
        if let rect {args += ["-R",String(format:"%d,%d,%d,%d",Int(rect.minX),Int(rect.minY),Int(rect.width),Int(rect.height))]}
        else {args += ["-D","1"]}
        if let seconds {args += ["-V",String(max(1,seconds))]}
        p.arguments=args+[url.path]
        p.terminationHandler = { [weak self] proc in DispatchQueue.main.async {
            guard let self else{return}
            let error:Error?=proc.terminationStatus == 0 ? nil:NSError(domain:"NotchDeck.Recording",code:Int(proc.terminationStatus),userInfo:[NSLocalizedDescriptionKey:"Запись завершилась с кодом \(proc.terminationStatus)"])
            self.finish(error)
        }}
        do {
            try p.run();process=p;began=Date();started=true;onChange?()
            let t=Timer(timeInterval:0.25,repeats:true) {[weak self] _ in self?.onChange?()}
            timer=t;RunLoop.main.add(t,forMode:.common)
            Dbg.log("record: capture process started pid=\(p.processIdentifier)")
        } catch {finish(error)}
    }
    func stop() {guard let process,process.isRunning else{return};process.interrupt()}
    private func finish(_ error:Error?) {
        guard !finished else{return};finished=true
        timer?.invalidate();timer=nil;process=nil
        onFinish?(error)
    }
}

private final class RecordingSelectionWindow:NSPanel {override var canBecomeKey:Bool {true}}
private final class RecordingSelectionView:NSView {
    var result:CGRect?
    private var anchor:CGPoint?
    private var selection:CGRect = .zero
    override var acceptsFirstResponder:Bool {true}
    override func resetCursorRects() {addCursorRect(bounds,cursor:.crosshair)}
    override func mouseDown(with event:NSEvent) {anchor=convert(event.locationInWindow,from:nil)}
    override func mouseDragged(with event:NSEvent) {
        guard let anchor else{return};let p=convert(event.locationInWindow,from:nil)
        selection=CGRect(x:min(anchor.x,p.x),y:min(anchor.y,p.y),width:abs(p.x-anchor.x),height:abs(p.y-anchor.y));needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        mouseDragged(with:event)
        guard selection.width>=16,selection.height>=16 else{return}
        result=CGRect(x:selection.minX,y:bounds.height-selection.maxY,width:selection.width,height:selection.height)
        NSApp.stopModal()
    }
    override func keyDown(with event:NSEvent) {if event.keyCode==53 {NSApp.stopModal()} else {super.keyDown(with:event)}}
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill();bounds.fill()
        if !selection.isEmpty {NSColor.white.withAlphaComponent(0.12).setFill();selection.fill();NSColor.systemGreen.setStroke();let p=NSBezierPath(rect:selection);p.lineWidth=2;p.stroke()}
        let text="Выдели область для записи · Esc — отмена"
        text.draw(at:NSPoint(x:24,y:bounds.height-80),withAttributes:[.font:NSFont.systemFont(ofSize:18,weight:.medium),.foregroundColor:NSColor.white])
    }
}

enum RecordingRegion {
    static func choose()->CGRect? {
        guard let screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==CGMainDisplayID()}) else{return nil}
        let window=RecordingSelectionWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.level = .screenSaver;window.isOpaque=false;window.backgroundColor = .clear
        let view=RecordingSelectionView(frame:NSRect(origin:.zero,size:screen.frame.size));window.contentView=view
        window.makeKeyAndOrderFront(nil);window.makeFirstResponder(view)
        NSApp.runModal(for:window);window.orderOut(nil)
        return view.result
    }
}
