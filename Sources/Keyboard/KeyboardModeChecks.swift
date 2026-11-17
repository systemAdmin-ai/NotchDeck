import AppKit

enum KeyboardModeChecks {
    static func run() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("KEYBOARD FAIL: \(message)\n",stderr);exit(1) }
            count += 1
        }
        var mode=KeyboardModePolicy()
        check(!mode.requested(externalCount:0),"auto should wait without external")
        check(mode.requested(externalCount:1),"auto should enable on connection")
        mode.toggle(externalCount:1)
        check(!mode.requested(externalCount:1),"manual off")
        check(!mode.requested(externalCount:0) && !mode.requested(externalCount:2),"manual off must survive reconnect")
        mode.toggle(externalCount:1)
        check(mode.requested(externalCount:1),"manual on")
        mode.setAutomatic(false)
        check(mode.manualOverride == nil && !mode.requested(externalCount:1),"automatic toggle resets manual preference")
        mode.setAutomatic(true)
        check(mode.requested(externalCount:1),"return to auto")
        func state(permission:Bool=true,ready:Bool=true,blocked:Bool=false,errors:Bool=false,applied:Int=1,excluded:Bool=false)->KeyboardModeState {
            KeyboardModeState.resolve(requested:true,automatic:true,manuallyOff:false,externalCount:1,permission:permission,ready:ready,blocked:blocked,errors:errors,applied:applied,excluded:excluded)
        }
        check(state() == .active,"confirmed map should be active")
        check(state(permission:false) == .permission,"permission must not light active")
        check(state(ready:false) == .permission,"failed HID open must not light active")
        check(state(blocked:true) == .conflict,"standalone conflict")
        check(state(errors:true) == .conflict,"native mapping error")
        check(state(applied:0) == .conflict,"zero applied services must not light active")
        check(state(excluded:true) == .suspended,"terminal exception")
        check(KeyboardModeState.resolve(requested:false,automatic:true,manuallyOff:false,externalCount:0,permission:true,ready:true,blocked:false,errors:false,applied:0,excluded:false) == .waiting,"waiting state")
        check(DBKeyboardPolicy.isExternal(transport:"USB",builtIn:false),"USB external")
        check(DBKeyboardPolicy.isExternal(transport:"Bluetooth",builtIn:false),"Bluetooth external")
        check(!DBKeyboardPolicy.isExternal(transport:"USB",builtIn:true),"built-in excluded")
        check(!DBKeyboardPolicy.isExternal(transport:"FIFO",builtIn:false),"unknown internal transport excluded")
        let keymap=DBKeyMapping.addingControl(to:[])
        check(keymap == [.controlToCommand],"left Ctrl map")
        check(DBKeyMapping.addingControl(to:[.controlToCommand])==nil,"preserve other mapper")
        check(Config.shared.visible(Item.actions).contains(.keyboardBridge),"keyboard action visible by default")
        let action=ActionView(item:.keyboardBridge)
        action.updateKeyboard(state:.active)
        check((action.layer?.shadowOpacity ?? 0)>0,"active keyboard glow")
        action.updateKeyboard(state:.permission)
        check(action.layer?.shadowOpacity==0,"permission must not glow green")
        action.updateKeyboard(state:.off)
        check(action.layer?.shadowOpacity==0,"off must not glow green")
        print("KEYBOARD PASS: \(count) checks — auto/manual priority, connection policy, permissions, map ownership, action and glow")
    }
}
