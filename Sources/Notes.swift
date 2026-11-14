import AppKit

final class QuickNotes:NSObject,NSTextViewDelegate,NSWindowDelegate {
    static let shared=QuickNotes()
    private var window:NSWindow?
    private var editor:NSTextView?
    private var saveWork:DispatchWorkItem?
    func show() {
        if window == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:360),
                styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            window.title="Быстрые заметки · NotchDeck";window.isReleasedWhenClosed=false;window.delegate=self;window.center()
            let root=NSView(frame:NSRect(x:0,y:0,width:440,height:360))
            let scroll=NSScrollView(frame:NSRect(x:16,y:50,width:408,height:294))
            scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
            let text=NSTextView(frame:scroll.bounds)
            text.isRichText=false;text.font = .systemFont(ofSize:14);text.textContainerInset=NSSize(width:10,height:10)
            text.isVerticallyResizable=true;text.isHorizontallyResizable=false
            text.autoresizingMask=[.width];text.textContainer?.widthTracksTextView=true
            text.string=UserDefaults.standard.string(forKey:"NotchDeck.quickNotes") ?? ""
            text.delegate=self;scroll.documentView=text;root.addSubview(scroll)
            let hint=NSTextField(labelWithString:"Сохраняется автоматически на этом Mac")
            hint.font = .systemFont(ofSize:10);hint.textColor = .secondaryLabelColor;hint.frame=NSRect(x:16,y:17,width:220,height:18)
            root.addSubview(hint)
            let apple=NSButton(title:"Заметки Apple ↗",target:self,action:#selector(openAppleNotes))
            apple.bezelStyle = .rounded;apple.frame=NSRect(x:264,y:10,width:160,height:30)
            apple.autoresizingMask=[.minXMargin];root.addSubview(apple)
            window.contentView=root;self.window=window;editor=text
        }
        window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        if let editor {window?.makeFirstResponder(editor)}
    }
    func textDidChange(_ notification:Notification) {
        saveWork?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.save() }
        saveWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.4,execute:work)
    }
    func save() {if let editor {UserDefaults.standard.set(editor.string,forKey:"NotchDeck.quickNotes")}}
    func windowWillClose(_ notification:Notification) {saveWork?.cancel();save()}
    @objc private func openAppleNotes() {
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Notes") else{return}
        NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) { _,_ in }
    }
}
