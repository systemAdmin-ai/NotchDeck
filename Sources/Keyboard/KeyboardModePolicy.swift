import Foundation

struct KeyboardModePolicy {
    var automatic = true
    var manualOverride: Bool?
    func requested(externalCount: Int) -> Bool { manualOverride ?? (automatic && externalCount > 0) }
    mutating func toggle(externalCount: Int) { manualOverride = !requested(externalCount: externalCount) }
    mutating func setAutomatic(_ value: Bool) { automatic = value; manualOverride = nil }
}

enum KeyboardModeState: Equatable {
    case off, waiting, permission, conflict, suspended, active
    static func resolve(requested: Bool, automatic: Bool, manuallyOff: Bool, externalCount: Int, permission: Bool, ready: Bool, blocked: Bool, errors: Bool, applied: Int, excluded: Bool) -> Self {
        if blocked { return .conflict }
        if !requested { return automatic && !manuallyOff && externalCount == 0 ? .waiting : .off }
        if externalCount == 0 { return .waiting }
        if !permission || !ready { return .permission }
        if errors { return .conflict }
        if excluded { return .suspended }
        return applied > 0 ? .active : .conflict
    }
}
