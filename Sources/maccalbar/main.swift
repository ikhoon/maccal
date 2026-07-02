// maccalbar — a menu-bar app that runs maccal's calendar sync on a schedule.
//
// It reuses maccalCore.runSync (no duplicated sync logic). The menu holds the
// settings (sources / target / interval / detail), a manual "Sync now", a
// "Run in background" toggle that installs a launchd job invoking the installed
// `maccal sync … --yes` CLI every N minutes, and "Start at login" (SMAppService).
//
// Not unit-tested here (UI + launchctl, like EKCalendarStore); the pure argv /
// plist builder lives in maccalCore.SyncAgent and IS covered by maccalCheck.

import AppKit
import EventKit
import QuartzCore
import ServiceManagement
import maccalCore

// MARK: - settings (UserDefaults)

@MainActor
enum Settings {
    private static let d = UserDefaults.standard
    static var sources: [String] {
        get { d.stringArray(forKey: "sources") ?? [] }
        set { d.set(newValue, forKey: "sources") }
    }
    static var target: String {
        get { d.string(forKey: "target") ?? "" }
        set { d.set(newValue, forKey: "target") }
    }
    static var intervalMinutes: Int {
        get { let v = d.integer(forKey: "intervalMinutes"); return v == 0 ? 30 : v }
        set { d.set(newValue, forKey: "intervalMinutes") }
    }
    static var detail: SyncDetail {
        get {
            switch d.string(forKey: "detail") {
            case "notes": return .withNotes
            case "busy": return .busy
            default: return .titleTimeLocation
            }
        }
        set {
            switch newValue {
            case .withNotes: d.set("notes", forKey: "detail")
            case .busy: d.set("busy", forKey: "detail")
            case .titleTimeLocation: d.set("title", forKey: "detail")
            }
        }
    }
    static var runInBackground: Bool {
        get { d.bool(forKey: "runInBackground") }
        set { d.set(newValue, forKey: "runInBackground") }
    }
}

// MARK: - installed CLI resolution

@MainActor
func resolveMaccalPath() -> String {
    let candidates = [
        "/opt/homebrew/bin/maccal",
        "/usr/local/bin/maccal",
        "\(NSHomeDirectory())/.local/bin/maccal",
    ]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["which", "maccal"]
    let pipe = Pipe(); p.standardOutput = pipe
    do {
        try p.run()
        p.waitUntilExit() // only wait after a successful launch; run() throws otherwise
    } catch {
        NSLog("maccalbar: `which maccal` failed: \(error)")
        return "/opt/homebrew/bin/maccal"
    }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out.isEmpty ? "/opt/homebrew/bin/maccal" : out
}

// MARK: - launchd background job (install / remove via launchctl)

@MainActor
enum BackgroundAgent {
    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(SyncAgent.label).plist")
    }

    /// Write + (re)load the job for the current settings. No-op (and removes any
    /// stale job) when sources/target aren't set yet.
    static func install() {
        guard !Settings.sources.isEmpty, !Settings.target.isEmpty else { uninstall(); return }
        let dict = SyncAgent.launchdPlist(
            maccalPath: resolveMaccalPath(), sources: Settings.sources, target: Settings.target,
            detail: Settings.detail, intervalMinutes: Settings.intervalMinutes)
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        else { return }
        try? data.write(to: plistURL)
        let uid = getuid()
        _ = launchctl(["bootout", "gui/\(uid)/\(SyncAgent.label)"]) // ignore "not loaded"
        _ = launchctl(["bootstrap", "gui/\(uid)", plistURL.path])
    }

    static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(SyncAgent.label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Re-emit the job after a settings change (only when the toggle is on).
    static func reloadIfEnabled() { if Settings.runInBackground { install() } }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit() // only wait after a successful launch; run() throws otherwise
        } catch {
            NSLog("maccalbar: launchctl \(args.first ?? "") failed: \(error)")
            return -1
        }
        return p.terminationStatus
    }
}

// MARK: - start at login (SMAppService)

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func toggle() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch { NSLog("maccalbar: login item toggle failed: \(error)") }
    }
}

// MARK: - menu-bar controller

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var statusLine = "Never synced"
    private var syncing = false

    func applicationDidFinishLaunching(_: Notification) {
        updateIcon() // a calendar at rest; a spinning sync glyph while syncing
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        requestAccess() // register maccalbar in the Calendar TCC list up front
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        addDisabled(menu, statusLine)
        menu.addItem(.separator())
        add(menu, syncing ? "Syncing…" : "Sync now", #selector(syncNow), key: "s", enabled: !syncing)
        menu.addItem(.separator())
        menu.addItem(sourcesMenu())
        menu.addItem(targetMenu())
        menu.addItem(intervalMenu())
        menu.addItem(detailMenu())
        menu.addItem(.separator())
        add(menu, "Run in background", #selector(toggleBackground), state: Settings.runInBackground)
        add(menu, "Start at login", #selector(toggleLogin), state: LoginItem.isEnabled)
        menu.addItem(.separator())
        add(menu, "Calendar access…", #selector(openCalendarSettings))
        add(menu, "Quit maccal sync", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
    }

    // MARK: dynamic submenus

    private func calendars() -> [CalendarInfo] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return EKCalendarStore(store: EKEventStore()).calendars()
    }

    private func selector(_ c: CalendarInfo) -> String { c.source.isEmpty ? c.title : "\(c.source)/\(c.title)" }

    private func sourcesMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Sources", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cals = calendars()
        if cals.isEmpty {
            add(sub, "Grant Calendar access…", #selector(requestAccessAction))
        }
        for c in cals {
            let sel = selector(c)
            let mi = NSMenuItem(title: sel, action: #selector(toggleSource(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = sel
            mi.state = Settings.sources.contains(sel) ? .on : .off
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func targetMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Target", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for c in calendars() where c.writable {
            let sel = selector(c)
            let mi = NSMenuItem(title: sel, action: #selector(setTarget(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = sel
            mi.state = Settings.target == sel ? .on : .off
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func intervalMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Every", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (mins, label) in [(15, "15 min"), (30, "30 min"), (60, "1 hour"), (120, "2 hours"), (360, "6 hours")] {
            let mi = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = mins
            mi.state = Settings.intervalMinutes == mins ? .on : .off
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func detailMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Detail", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cur = Settings.detail
        for (tag, label, det) in [(0, "Title + time + location", SyncDetail.titleTimeLocation),
                                  (1, "+ Notes", .withNotes),
                                  (2, "Busy only", .busy)] {
            let mi = NSMenuItem(title: label, action: #selector(setDetail(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = tag
            mi.state = cur == det ? .on : .off
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    // MARK: actions

    @objc private func syncNow() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { requestAccess(); return }
        let sources = Settings.sources, target = Settings.target, detail = Settings.detail
        guard !sources.isEmpty, !target.isEmpty else { statusLine = "Set sources + target first"; return }
        syncing = true
        statusLine = "Syncing…"
        updateIcon()
        // This Task inherits the MainActor, so `self` is only ever touched on the
        // main actor — never sent into a child task. The blocking sync runs in a
        // detached child that captures only Sendable values and returns a Sendable
        // result, so no actor-isolated state crosses the boundary.
        Task { [weak self] in
            let (ok, msg) = await Self.runSyncOffMain(sources: sources, target: target, detail: detail)
            self?.finishSync(ok: ok, msg: msg)
        }
    }

    /// Runs the (blocking) sync off the main actor. `nonisolated` + only-Sendable
    /// parameters guarantee neither `self` nor any actor state crosses into the
    /// detached child; the `(Bool, String)` result is Sendable on the way back.
    nonisolated private static func runSyncOffMain(
        sources: [String], target: String, detail: SyncDetail
    ) async -> (Bool, String) {
        await Task.detached { () -> (Bool, String) in
            do {
                let result = try runSync(
                    store: EKCalendarStore(store: EKEventStore()),
                    from: sources, to: target, since: nil, until: nil, detail: detail,
                    noDelete: false, json: false, dryRun: false, confirm: AutoYes(), now: Date())
                return (true, result.output.split(separator: "\n").first.map(String.init) ?? "synced")
            } catch let e as MaccalError {
                return (false, e.description)
            } catch {
                return (false, "\(error)")
            }
        }.value
    }

    private func finishSync(ok: Bool, msg: String) {
        syncing = false
        updateIcon()
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        statusLine = ok ? "✓ \(t)  \(msg)" : "⚠︎ \(msg)"
    }

    @objc private func toggleSource(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? String else { return }
        var cur = Settings.sources
        if let i = cur.firstIndex(of: sel) { cur.remove(at: i) } else { cur.append(sel) }
        Settings.sources = cur
        BackgroundAgent.reloadIfEnabled()
    }

    @objc private func setTarget(_ sender: NSMenuItem) {
        Settings.target = (sender.representedObject as? String) ?? ""
        BackgroundAgent.reloadIfEnabled()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        Settings.intervalMinutes = sender.tag
        BackgroundAgent.reloadIfEnabled()
    }

    @objc private func setDetail(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: Settings.detail = .withNotes
        case 2: Settings.detail = .busy
        default: Settings.detail = .titleTimeLocation
        }
        BackgroundAgent.reloadIfEnabled()
    }

    @objc private func toggleBackground() {
        let on = !Settings.runInBackground
        if on, Settings.sources.isEmpty || Settings.target.isEmpty {
            statusLine = "Set sources + target first"
            return
        }
        Settings.runInBackground = on
        if on { BackgroundAgent.install() } else { BackgroundAgent.uninstall() }
    }

    @objc private func toggleLogin() { LoginItem.toggle() }

    @objc private func requestAccessAction() { requestAccess() }

    @objc private func openCalendarSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(u)
        }
    }

    private func requestAccess() {
        EKEventStore().requestFullAccessToEvents { _, _ in } // fires the prompt; menu re-reads status on open
    }

    // MARK: status-item icon

    /// The menu-bar glyph doubles as a sync indicator: a calendar at rest, and
    /// the universal circular-arrows "sync" glyph — spinning — while a sync is in
    /// flight, so the icon itself reads as "keeps your calendars in sync."
    private func updateIcon() {
        guard let b = statusItem.button else { return }
        b.image = NSImage(
            systemSymbolName: syncing ? "arrow.triangle.2.circlepath" : "calendar.badge.clock",
            accessibilityDescription: syncing ? "syncing…" : "maccal sync")
        if syncing { startSpin(b) } else { stopSpin(b) }
    }

    private func startSpin(_ b: NSStatusBarButton) {
        b.wantsLayer = true
        guard let layer = b.layer, layer.animation(forKey: "spin") == nil else { return }
        // Default anchor is a corner (the glyph would orbit); move it to the
        // centre, then reassign the frame so it spins in place, not off-screen.
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.frame = frame
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2 // clockwise
        spin.duration = 1.1
        spin.repeatCount = .infinity
        layer.add(spin, forKey: "spin")
    }

    private func stopSpin(_ b: NSStatusBarButton) {
        b.layer?.removeAnimation(forKey: "spin")
    }

    // MARK: menu-builder helpers

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                     state: Bool? = nil, enabled: Bool = true, target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = target ?? self
        if let state { mi.state = state ? .on : .off }
        mi.isEnabled = enabled
        menu.addItem(mi)
        return mi
    }
}

// MARK: - entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
let controller = AppController()
app.delegate = controller
app.run()
