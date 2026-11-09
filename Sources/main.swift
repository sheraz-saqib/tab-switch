import AppKit
import SwiftUI
import ServiceManagement

// MARK: - CLI:  TabSwitch list | focus <id> | selftest

if CommandLine.arguments.count > 1 {
    Prefs.register()
    let a = CommandLine.arguments
    switch a[1] {
    case "list":
        for w in Windows.list() { print("\(w.wid)\t\(w.appName)\t\(w.title)") }
    case "focus":
        guard a.count > 2, let id = UInt32(a[2]), let w = Windows.list().first(where: { $0.wid == id }) else {
            print("usage: TabSwitch focus <window-id>   (ids from `TabSwitch list`)"); exit(1)
        }
        Windows.focus(w)
    case "selftest":
        precondition(fuzzyMatch("gchr", "Google Chrome"))
        precondition(fuzzyMatch("", "anything"))
        precondition(fuzzyMatch("VS code", "Visual Studio Code"))
        precondition(!fuzzyMatch("xyz", "Safari"))
        precondition(!fuzzyMatch("fiars", "Safari")) // order matters
        let (l, size) = Layout.make(count: 10, screen: CGSize(width: 1440, height: 900), style: "thumbnails", thumb: 220)
        precondition(l.cols == 5 && size.width <= 1440 * 0.9 && size.height <= 900 * 0.8)
        precondition(Layout.make(count: 3, screen: CGSize(width: 1440, height: 900), style: "titles", thumb: 220).0.cols == 1)
        print("selftest ok")
    default:
        print("usage: TabSwitch [list | focus <window-id> | selftest]"); exit(1)
    }
    exit(0)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let switcher = Switcher()
    private lazy var hotkeys = HotKeys(switcher)
    private var settings: NSWindow?
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.register()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25) // one hung app can't freeze the switcher

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "TabSwitch")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TabSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.first?.target = self
        status.menu = menu

        applyCmdTab()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            applyCmdTab()
        }

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) || !hotkeys.start() {
            openSettings()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
                guard let self, AXIsProcessTrusted(), self.hotkeys.start() else { return }
                t.invalidate()
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) { applyCmdTab(forceEnable: true) }

    @objc func openSettings() {
        if settings == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "TabSwitch Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settings = w
        }
        NSApp.activate()
        settings?.center()
        settings?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("modifier") private var modifier = "option"
    @AppStorage("style") private var style = "thumbnails"
    @AppStorage("instant") private var instant = true
    @AppStorage("sameApp") private var sameApp = true
    @AppStorage("showMinimized") private var showMinimized = true
    @AppStorage("showHidden") private var showHidden = true
    @AppStorage("mouseScreenOnly") private var mouseScreenOnly = false
    @AppStorage("thumbSize") private var thumbSize = 220.0
    @AppStorage("delay") private var delay = 0.1
    @AppStorage("blacklist") private var blacklist = ""
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var ax = AXIsProcessTrusted()
    @State private var rec = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("Permissions") {
                perm("Accessibility (switching & shortcuts)", ax, "Privacy_Accessibility")
                perm("Screen Recording (live thumbnails)", rec, "Privacy_ScreenCapture")
                Button("Re-check") { ax = AXIsProcessTrusted(); rec = CGPreflightScreenCaptureAccess() }
            }
            Section("Shortcut") {
                Picker("Hold", selection: $modifier) {
                    Text("⌥ Option").tag("option")
                    Text("⌃ Control").tag("control")
                    Text("⌘ Command (replaces system ⌘⇥)").tag("command")
                }
                Toggle("Release key to switch (off: stays open, ⏎ to switch)", isOn: $instant)
                Toggle("Hold + ` shows only the current app's windows", isOn: $sameApp)
                LabeledContent("Appear delay") {
                    Slider(value: $delay, in: 0...0.5) { Text("") }
                    Text("\(Int(delay * 1000)) ms").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            Section("Appearance") {
                Picker("Style", selection: $style) {
                    Text("Thumbnails").tag("thumbnails")
                    Text("App Icons").tag("icons")
                    Text("Titles").tag("titles")
                }
                .pickerStyle(.segmented)
                if style == "thumbnails" {
                    LabeledContent("Thumbnail size") { Slider(value: $thumbSize, in: 140...380) { Text("") } }
                }
            }
            Section("Show windows") {
                Toggle("Minimized windows", isOn: $showMinimized)
                Toggle("Windows of hidden apps", isOn: $showHidden)
                Toggle("Only from the screen with the mouse", isOn: $mouseScreenOnly)
            }
            Section("Exceptions — apps never shown (one bundle ID per line)") {
                TextEditor(text: $blacklist).font(.system(.body, design: .monospaced)).frame(height: 70)
                Menu("Add running app") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil },
                            id: \.processIdentifier) { a in
                        Button(a.localizedName ?? a.bundleIdentifier!) {
                            blacklist += (blacklist.isEmpty || blacklist.hasSuffix("\n") ? "" : "\n") + a.bundleIdentifier!
                        }
                    }
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { login }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    login = SMAppService.mainApp.status == .enabled
                }))
            }
            Section("While the switcher is open") {
                Text("""
                ⇥ / ⇧⇥ / arrows — move    ⏎ or click — switch    esc — cancel
                hold + W close · M minimize · F full screen · H hide app · Q quit app · S search
                Hover a window for close / minimize / full-screen buttons.
                CLI: TabSwitch.app/Contents/MacOS/TabSwitch list | focus <id>
                """).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
    }

    func perm(_ label: String, _ ok: Bool, _ pane: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label)
            Spacer()
            if !ok {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
