import AppKit

enum Prefs {
    static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "modifier": "option",       // option | control | command
            "style": "thumbnails",      // thumbnails | icons | titles
            "instant": true,            // release modifier = switch
            "sameApp": true,            // modifier + ` = current app only
            "showMinimized": true,
            "showHidden": true,
            "mouseScreenOnly": false,
            "thumbSize": 220.0,
            "delay": 0.1,
            "blacklist": "",
        ])
    }

    static var modifierName: String { d.string(forKey: "modifier") ?? "option" }
    static var modifier: CGEventFlags {
        switch modifierName {
        case "command": return .maskCommand
        case "control": return .maskControl
        default: return .maskAlternate
        }
    }
    static var style: String { d.string(forKey: "style") ?? "thumbnails" }
    static var instant: Bool { d.bool(forKey: "instant") }
    static var sameApp: Bool { d.bool(forKey: "sameApp") }
    static var showMinimized: Bool { d.bool(forKey: "showMinimized") }
    static var showHidden: Bool { d.bool(forKey: "showHidden") }
    static var mouseScreenOnly: Bool { d.bool(forKey: "mouseScreenOnly") }
    static var thumbSize: CGFloat { d.double(forKey: "thumbSize") }
    static var delay: Double { d.double(forKey: "delay") }
    static var blacklist: Set<String> {
        Set((d.string(forKey: "blacklist") ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

// Private SkyLight call (AltTab uses the same) to free ⌘Tab from the system switcher.
// IDs: 1 = ⌘Tab, 2 = ⌘⇧Tab. Re-enabled on quit; a crash leaves them off until relaunch/logout.
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ key: Int32, _ enabled: Bool) -> Int32

func applyCmdTab(forceEnable: Bool = false) {
    let systemOn = forceEnable || Prefs.modifierName != "command"
    CGSSetSymbolicHotKeyEnabled(1, systemOn)
    CGSSetSymbolicHotKeyEnabled(2, systemOn)
}
