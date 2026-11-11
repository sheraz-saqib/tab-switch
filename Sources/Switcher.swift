import AppKit
import SwiftUI

struct Layout {
    var cols = 1, cellW: CGFloat = 200, cellH: CGFloat = 150
    static let gap: CGFloat = 8, pad: CGFloat = 14, header: CGFloat = 34

    static func make(count: Int, screen: CGSize, style: String, thumb: CGFloat) -> (Layout, CGSize) {
        var l = Layout()
        switch style {
        case "titles": l.cellW = min(720, screen.width * 0.6); l.cellH = 34
        case "icons": l.cellW = 104; l.cellH = 112
        default: l.cellW = thumb; l.cellH = thumb * 0.62 + 34
        }
        let maxCols = max(1, Int((screen.width * 0.9 - 2 * pad + gap) / (l.cellW + gap)))
        l.cols = style == "titles" ? 1 : max(1, min(count, maxCols))
        let rows = (count + l.cols - 1) / l.cols
        let maxRows = max(1, Int((screen.height * 0.8 - 2 * pad - header + gap) / (l.cellH + gap)))
        let vr = CGFloat(max(1, min(rows, maxRows))), c = CGFloat(l.cols)
        return (l, CGSize(width: c * l.cellW + (c - 1) * gap + 2 * pad,
                          height: vr * l.cellH + (vr - 1) * gap + 2 * pad + header))
    }
}

final class SwitcherModel: ObservableObject {
    @Published var items: [WinItem] = []
    @Published var selected = 0
    @Published var query = ""
    @Published var searching = false
    @Published var thumbs: [CGWindowID: NSImage] = [:]
    @Published var layout = Layout()
    @Published var style = "thumbnails"
    var visible: [WinItem] { query.isEmpty ? items : items.filter { fuzzyMatch(query, $0.title + " " + $0.appName) } }
}

final class SwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
    override var canBecomeKey: Bool { true } // needed for hover tracking; nonactivating so the front app keeps focus
}

final class Switcher: NSObject, NSWindowDelegate {
    let model = SwitcherModel()
    private let panel = SwitcherPanel()
    private(set) var isOpen = false
    private var showTask: DispatchWorkItem?
    private var onlyPid: pid_t?
    private var loading = false, pendingCommit = false, gen = 0

    /// Keep the panel open after the modifier is released.
    var sticky: Bool { !Prefs.instant || model.searching }

    override init() {
        super.init()
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = NSImage(size: NSSize(width: 41, height: 41), flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill(); return true
        }
        fx.maskImage?.capInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        fx.maskImage?.resizingMode = .stretch

        let host = NSHostingView(rootView: SwitcherView(
            m: model,
            click: { [weak self] i in self?.model.selected = i; self?.commit() },
            action: { [weak self] i, a in self?.perform(a, at: i) }))
        host.sizingOptions = []
        host.frame = fx.bounds
        host.autoresizingMask = [.width, .height]
        fx.addSubview(host)
        panel.contentView = fx
        panel.delegate = self
    }

    /// Returns immediately (called from the event tap): the window list is built off the main thread.
    /// Tabs / release that arrive before it lands are replayed in `loaded`.
    func open(currentApp: Bool) {
        onlyPid = currentApp ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        model.items = []
        model.query = ""
        model.searching = false
        model.selected = 1
        isOpen = true
        loading = true
        pendingCommit = false
        let opened = DispatchTime.now()
        fetch { [weak self] items in self?.loaded(items, opened: opened) }
    }

    private func fetch(_ done: @escaping ([WinItem]) -> Void) {
        gen += 1
        let g = gen, pid = onlyPid, screen = Prefs.mouseScreenOnly ? Screens.mouseScreenCG() : nil
        DispatchQueue.global(qos: .userInteractive).async {
            let items = Windows.list(onlyPid: pid, screen: screen)
            DispatchQueue.main.async { [weak self] in if self?.gen == g { done(items) } }
        }
    }

    private func loaded(_ items: [WinItem], opened: DispatchTime) {
        guard isOpen else { return }
        loading = false
        guard !items.isEmpty else { close(); return }
        let n = items.count
        model.items = items
        model.selected = n > 1 ? (model.selected % n + n) % n : 0
        if pendingCommit { commit(); return }
        // Start capturing now, during the show delay, so the panel mostly appears with fresh thumbnails
        // instead of showing last time's and then swapping them.
        if Prefs.style == "thumbnails" {
            Thumbs.capture(Set(items.map(\.wid)), maxPixels: Prefs.thumbSize) { [weak self] id, img in self?.model.thumbs[id] = img }
        }
        // Small delay: a quick ⌥⇥ tap switches to the previous window without flashing the UI.
        let t = DispatchWorkItem { [weak self] in self?.show() }
        showTask = t
        DispatchQueue.main.asyncAfter(deadline: opened + Prefs.delay, execute: t)
    }

    private func show() {
        guard isOpen, !loading, !panel.isVisible else { return }
        showTask?.cancel()
        let screen = Screens.mouse.visibleFrame
        let (l, size) = Layout.make(count: model.items.count, screen: screen.size, style: Prefs.style, thumb: Prefs.thumbSize)
        model.layout = l
        model.style = Prefs.style
        let ids = Set(model.items.map(\.wid))
        Thumbs.cache = Thumbs.cache.filter { ids.contains($0.key) }
        model.thumbs = Thumbs.cache
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        panel.contentView?.layoutSubtreeIfNeeded() // render this open's items now, not last open's for a frame
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func move(_ d: Int) {
        let n = model.visible.count
        guard n > 0 else { if loading { model.selected += d }; return }
        model.selected = ((model.selected + d) % n + n) % n
    }

    func commit() {
        guard isOpen else { return }
        if loading { pendingCommit = true; return }
        let v = model.visible
        let target = v.indices.contains(model.selected) ? v[model.selected] : nil
        close()
        if let target { DispatchQueue.main.async { Windows.focus(target) } } // let the event tap return first
    }

    func close() {
        showTask?.cancel()
        gen += 1 // drop any in-flight fetch
        isOpen = false
        loading = false
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ n: Notification) { if isOpen && panel.isVisible { close() } }

    func perform(_ a: WinAction, at i: Int? = nil) {
        let v = model.visible, idx = i ?? model.selected
        guard v.indices.contains(idx) else { return }
        if a == .fullscreen { close() }
        Windows.act(a, v[idx])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard isOpen, !loading else { return }
        fetch { [weak self] items in
            guard let self, self.isOpen else { return }
            self.model.items = items
            if items.isEmpty { self.close(); return }
            self.model.selected = max(0, min(self.model.selected, self.model.visible.count - 1))
        }
    }

    /// Keys while open. Modifier+letter = action; plain typing = search (when panel is sticky).
    func key(_ code: Int, _ e: CGEvent, modHeld: Bool) {
        let cols = model.layout.cols
        switch code {
        case K.esc: close(); return
        case K.ret, K.enter: commit(); return
        case K.tab: move(e.flags.contains(.maskShift) ? -1 : 1); return
        case K.left: move(-1); return
        case K.right: move(1); return
        case K.up: move(-cols); return
        case K.down: move(cols); return
        default: break
        }
        if modHeld {
            switch code {
            case K.w: perform(.close)
            case K.m: perform(.minimize)
            case K.q: perform(.quit)
            case K.h: perform(.hide)
            case K.f: perform(.fullscreen)
            case K.s: model.searching = true; show()
            default: break
            }
            return
        }
        guard sticky else { return }
        if code == K.delete {
            if !model.query.isEmpty { model.query.removeLast() }
        } else if let s = NSEvent(cgEvent: e)?.characters, !s.isEmpty,
                  s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && $0.value < 0xF700 }) {
            model.query += s
            model.searching = true
            show()
        }
        model.selected = 0
    }
}

// MARK: - Views

struct SwitcherView: View {
    @ObservedObject var m: SwitcherModel
    let click: (Int) -> Void
    let action: (Int, WinAction) -> Void

    var body: some View {
        let items = m.visible, l = m.layout
        VStack(spacing: Layout.gap) {
            header(items).frame(height: Layout.header - Layout.gap)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(l.cellW), spacing: Layout.gap), count: l.cols),
                              spacing: Layout.gap) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, w in
                            Cell(w: w, thumb: m.thumbs[w.wid], selected: i == m.selected, style: m.style, l: l,
                                 click: { click(i) }, action: { action(i, $0) })
                                .id(i)
                        }
                    }
                }
                .onChange(of: m.selected) { _, s in proxy.scrollTo(s) }
            }
        }
        .padding(Layout.pad)
    }

    @ViewBuilder func header(_ items: [WinItem]) -> some View {
        HStack(spacing: 8) {
            if m.searching || !m.query.isEmpty {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(m.query.isEmpty ? "Type to search windows…" : m.query)
                    .foregroundStyle(m.query.isEmpty ? .secondary : .primary)
                Spacer()
                Text(items.isEmpty ? "No matches" : "\(items.count)").foregroundStyle(.secondary)
            } else if items.indices.contains(m.selected) {
                let w = items[m.selected]
                Text(w.title).fontWeight(.semibold).lineLimit(1)
                Text("— \(w.appName)").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 6)
    }
}

struct Cell: View {
    let w: WinItem, thumb: NSImage?, selected: Bool, style: String, l: Layout
    let click: () -> Void, action: (WinAction) -> Void
    @State private var hover = false

    var body: some View {
        content
            .padding(6)
            .frame(width: l.cellW, height: l.cellH)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.3) : hover ? Color.primary.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .overlay(alignment: .topLeading) { if hover && style != "titles" { buttons.padding(10) } }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: click)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(w.title), \(w.appName)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder var content: some View {
        switch style {
        case "titles":
            HStack(spacing: 10) {
                icon(20)
                Text(w.title).lineLimit(1)
                Spacer(minLength: 4)
                badges
                Text(w.appName).foregroundStyle(.secondary).lineLimit(1)
                if hover { buttons }
            }
        case "icons":
            VStack(spacing: 6) {
                icon(64).overlay(alignment: .bottomTrailing) { badges }
                Text(w.appName).font(.caption).lineLimit(1)
            }
        default:
            VStack(spacing: 6) {
                ZStack {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            .transition(.opacity) // fades in only over the app icon; a fresh capture swaps in place
                    } else {
                        icon(64).transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.18), value: thumb != nil)
                HStack(spacing: 6) {
                    icon(16)
                    Text(w.title).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    badges
                }
            }
        }
    }

    func icon(_ s: CGFloat) -> some View {
        Image(nsImage: w.app.icon ?? NSImage()).resizable().frame(width: s, height: s)
    }

    var badges: some View {
        HStack(spacing: 2) {
            if w.minimized { Image(systemName: "minus.circle.fill").help("Minimized") }
            if w.hidden { Image(systemName: "eye.slash.circle.fill").help("App hidden") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    var buttons: some View {
        HStack(spacing: 6) {
            btn("xmark", .red, .close, "Close window")
            btn("minus", .yellow, .minimize, w.minimized ? "Restore" : "Minimize")
            btn("arrow.up.left.and.arrow.down.right", .green, .fullscreen, "Toggle full screen")
        }
    }

    func btn(_ sym: String, _ c: Color, _ a: WinAction, _ tip: String) -> some View {
        Button { action(a) } label: {
            Image(systemName: sym).font(.system(size: 8, weight: .heavy))
                .frame(width: 14, height: 14)
                .background(Circle().fill(c))
                .foregroundStyle(.black.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}
