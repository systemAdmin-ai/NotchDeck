import AppKit
import IOKit.ps

struct PowerTransition {
    private(set) var last:Bool?
    mutating func update(_ connected:Bool)->Bool {
        defer {last=connected}
        return last == false && connected
    }
}

final class PowerEvents {
    static let shared=PowerEvents()
    private var source:CFRunLoopSource?
    private var transition=PowerTransition()
    func start() {
        guard source == nil else{return}
        if let connected=Self.connected() {_=transition.update(connected)}
        let info=Unmanaged.passUnretained(self).toOpaque()
        guard let source=IOPSNotificationCreateRunLoopSource({ context in
            guard let context else{return}
            Unmanaged<PowerEvents>.fromOpaque(context).takeUnretainedValue().changed()
        },info)?.takeRetainedValue() else{return}
        self.source=source;CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
    }
    private func changed() {
        guard let connected=Self.connected() else{return}
        if transition.update(connected) {
            DispatchQueue.main.async {NotchHUD.shared.showCharging()}
        }
    }
    private static func connected()->Bool? {
        guard let blob=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list=IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else{return nil}
        for item in list {
            guard let data=IOPSGetPowerSourceDescription(blob,item)?.takeUnretainedValue() as? [String:Any],
                  data[kIOPSTransportTypeKey] as? String == kIOPSInternalType else{continue}
            return data[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        }
        return nil
    }
}
