import AppKit

// ponytail: ANSI keycodes; letter actions follow QWERTY positions on other layouts.
enum K {
    static let tab = 48, grave = 50, esc = 53, ret = 36, enter = 76, delete = 51
    static let left = 123, right = 124, down = 125, up = 126
    static let w = 13, m = 46, q = 12, h = 4, f = 3, s = 1
}

/// Session event tap: sees every key before apps do; swallows keys while the switcher is open.
final class HotKeys {
    private var tap: CFMachPort?
    private let sw: Switcher

    init(_ sw: Switcher) { self.sw = sw }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            Unmanaged<HotKeys>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // The modifier release may have been dropped while the tap was off: don't leave the switcher stuck open.
            if sw.isOpen && !sw.sticky && !CGEventSource.flagsState(.combinedSessionState).contains(Prefs.modifier) { sw.commit() }
            return pass
        }
        let mod = Prefs.modifier
        let others = CGEventFlags([.maskCommand, .maskControl, .maskAlternate]).subtracting(mod)
        let held = e.flags.contains(mod)
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .flagsChanged:
            if sw.isOpen && !held && !sw.sticky { sw.commit() }
            return pass
        case .keyDown:
            let trigger = code == K.tab || (code == K.grave && Prefs.sameApp)
            if trigger && held && e.flags.intersection(others).isEmpty {
                if sw.isOpen { sw.move(e.flags.contains(.maskShift) ? -1 : 1) }
                else { sw.open(currentApp: code == K.grave) }
                return nil
            }
            guard sw.isOpen else { return pass }
            sw.key(code, e, modHeld: held)
            return nil
        case .keyUp:
            return sw.isOpen ? nil : pass
        default:
            return pass
        }
    }
}
