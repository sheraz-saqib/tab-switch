import AppKit
import ApplicationServices
import ScreenCaptureKit

// Private but stable API (used by AltTab, Hammerspoon, yabai): AXUIElement -> CGWindowID.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func attr<T>(_ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success else { return nil }
        return v as? T
    }
    func set(_ name: String, _ value: Bool) {
        AXUIElementSetAttributeValue(self, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }
    func perform(_ action: String) { AXUIElementPerformAction(self, action as CFString) }
}

struct WinItem: Identifiable {
    let id: Int
    let wid: CGWindowID
    let ax: AXUIElement
    let app: NSRunningApplication
    let title: String
    let minimized: Bool
    var hidden: Bool { app.isHidden }
    var appName: String { app.localizedName ?? "?" }
}

enum WinAction { case close, minimize, fullscreen, quit, hide }

/// Subsequence match, case-insensitive: "gchr" matches "Google Chrome".
func fuzzyMatch(_ query: String, _ text: String) -> Bool {
    var rest = Substring(text.lowercased())
    for c in query.lowercased() where c != " " {
        guard let i = rest.firstIndex(of: c) else { return false }
        rest = rest[rest.index(after: i)...]
    }
    return true
}

enum Screens {
    static var mouse: NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    /// Mouse screen frame in CG (top-left origin) coordinates.
    static func mouseScreenCG() -> CGRect {
        let f = mouse.frame, h = NSScreen.screens[0].frame.height
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }
}

enum Windows {
    // ponytail: AX only sees windows on the current Space (plus minimized/hidden). Other-Space windows
    // need private SkyLight brute-forcing like AltTab does; add if you live in many Spaces.
    static func list(onlyPid: pid_t? = nil) -> [WinItem] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var rank: [CGWindowID: Int] = [:], bounds: [CGWindowID: CGRect] = [:]
        for (i, w) in info.enumerated() {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            rank[id] = i // front-to-back = most recently used first
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) { bounds[id] = r }
        }
        let screen = Prefs.mouseScreenOnly ? Screens.mouseScreenCG() : nil
        let blocked = Prefs.blacklist
        var out: [(item: WinItem, rank: Int)] = []
        var n = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let pid = onlyPid, app.processIdentifier != pid { continue }
            if blocked.contains(app.bundleIdentifier ?? "") { continue }
            if app.isHidden && !Prefs.showHidden { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let wins: [AXUIElement] = axApp.attr(kAXWindowsAttribute) else { continue }
            for w in wins {
                guard (w.attr(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole else { continue }
                let mini = (w.attr(kAXMinimizedAttribute) as Bool?) ?? false
                if mini && !Prefs.showMinimized { continue }
                var wid: CGWindowID = 0
                _AXUIElementGetWindow(w, &wid)
                if let s = screen, let b = bounds[wid], !s.contains(CGPoint(x: b.midX, y: b.midY)) { continue }
                n += 1
                let t = (w.attr(kAXTitleAttribute) as String?) ?? ""
                let item = WinItem(id: wid != 0 ? Int(wid) : -n, wid: wid, ax: w, app: app,
                                   title: t.isEmpty ? (app.localizedName ?? "") : t, minimized: mini)
                out.append((item, rank[wid] ?? 1_000_000 + n))
            }
        }
        return out.sorted { $0.rank < $1.rank }.map(\.item)
    }

    static func focus(_ w: WinItem) {
        if w.app.isHidden { w.app.unhide() }
        if w.minimized { w.ax.set(kAXMinimizedAttribute, false) }
        AXUIElementCreateApplication(w.app.processIdentifier).set(kAXFrontmostAttribute, true)
        w.ax.set(kAXMainAttribute, true)
        w.ax.perform(kAXRaiseAction)
        w.app.activate()
    }

    static func act(_ a: WinAction, _ w: WinItem) {
        switch a {
        case .close:
            if let b: AXUIElement = w.ax.attr(kAXCloseButtonAttribute) { b.perform(kAXPressAction) }
        case .minimize:
            w.ax.set(kAXMinimizedAttribute, !w.minimized)
        case .fullscreen:
            focus(w)
            let fs = (w.ax.attr("AXFullScreen") as Bool?) ?? false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { w.ax.set("AXFullScreen", !fs) }
        case .quit:
            w.app.terminate()
        case .hide:
            _ = w.app.isHidden ? w.app.unhide() : w.app.hide()
        }
    }
}

enum Thumbs {
    static var cache: [CGWindowID: NSImage] = [:]

    /// Captures windows concurrently via ScreenCaptureKit; calls `each` on main as each lands.
    static func capture(_ ids: Set<CGWindowID>, maxPixels: CGFloat, each: @escaping @MainActor (CGWindowID, NSImage) -> Void) {
        Task.detached {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            await withTaskGroup(of: Void.self) { g in
                for w in content.windows where ids.contains(w.windowID) {
                    g.addTask {
                        let cfg = SCStreamConfiguration()
                        let s = min(1, maxPixels / max(w.frame.width, w.frame.height, 1))
                        cfg.width = max(1, Int(w.frame.width * s * 2))
                        cfg.height = max(1, Int(w.frame.height * s * 2))
                        cfg.showsCursor = false
                        guard let cg = try? await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { return }
                        let img = NSImage(cgImage: cg, size: .zero)
                        await MainActor.run { cache[w.windowID] = img; each(w.windowID, img) }
                    }
                }
            }
        }
    }
}
