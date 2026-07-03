// maccalbar — a menu-bar app that runs maccal's calendar sync on a schedule.
//
// The menu bar itself is small: status + "Sync now" + the background/login
// toggles. All source/target/interval/detail selection lives in a proper
// Settings window (a checkbox list for the sources, pop-ups for the rest) so you
// can tick several sources and then pick a target without the menu closing on
// the first click — which is what a plain NSMenu does.
//
// It reuses maccalCore.runSync (no duplicated sync logic). "Run in background"
// installs a launchd job invoking the installed `maccal sync … --yes` CLI every
// N minutes; "Start at login" uses SMAppService.
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

// MARK: - calendar helpers

/// Live calendars, or [] until Calendar access is granted.
@MainActor
func availableCalendars() -> [CalendarInfo] {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
    return EKCalendarStore(store: EKEventStore()).calendars()
}

/// The stable selector maccal's sync uses: "Account/Calendar" (or the bare title
/// when the calendar has no account). Stored verbatim in Settings.
@MainActor
func calendarSelector(_ c: CalendarInfo) -> String { c.source.isEmpty ? c.title : "\(c.source)/\(c.title)" }

/// Calendars grouped by account, both levels sorted — for the grouped-header UI.
@MainActor
func calendarsByAccount(writableOnly: Bool) -> [(account: String, calendars: [CalendarInfo])] {
    let cals = availableCalendars().filter { !writableOnly || $0.writable }
    let groups = Dictionary(grouping: cals, by: { $0.source })
    return groups.keys.sorted().map { key in
        (account: key.isEmpty ? "Other" : key,
         calendars: groups[key]!.sorted {
             $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
         })
    }
}

// MARK: - settings window

/// The whole source/target/interval/detail editor. A window (not a menu) so the
/// sources are checkboxes you can tick several of, and the target/interval/detail
/// are pop-ups — nothing dismisses on the first click. Every change writes
/// straight to `Settings` and re-emits the launchd job via `onChange`.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onChange: () -> Void
    private let sourceStack = NSStackView()
    private let targetPopup = NSPopUpButton()
    private let intervalPopup = NSPopUpButton()
    private let detailPopup = NSPopUpButton()

    private static let intervals: [(tag: Int, label: String)] =
        [(15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"), (360, "6 hours")]
    private static let details: [(tag: Int, label: String, detail: SyncDetail)] =
        [(0, "Title + time + location", .titleTimeLocation), (1, "＋ Notes", .withNotes), (2, "Busy only", .busy)]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "maccal · Settings"
        win.isReleasedWhenClosed = false // reused across opens; keep it alive on close
        super.init(window: win)
        win.delegate = self
        let content = buildContent()
        win.contentView = content
        content.layoutSubtreeIfNeeded()
        win.setContentSize(NSSize(width: 400, height: content.fittingSize.height)) // fit height to content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Refresh from the live calendars + current settings, then bring to front.
    func show() {
        reloadSources()
        reloadTarget()
        if let i = Self.intervals.firstIndex(where: { $0.tag == Settings.intervalMinutes }) { intervalPopup.selectItem(at: i) }
        if let i = Self.details.firstIndex(where: { $0.detail == Settings.detail }) { detailPopup.selectItem(at: i) }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: layout

    private func buildContent() -> NSView {
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 4
        sourceStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = sourceStack
        sourceStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sourceStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            sourceStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            sourceStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true

        targetPopup.target = self;   targetPopup.action = #selector(targetChanged)
        intervalPopup.target = self; intervalPopup.action = #selector(intervalChanged)
        detailPopup.target = self;   detailPopup.action = #selector(detailChanged)
        for i in Self.intervals { intervalPopup.addItem(withTitle: i.label); intervalPopup.lastItem?.tag = i.tag }
        for d in Self.details { detailPopup.addItem(withTitle: d.label); detailPopup.lastItem?.tag = d.tag }

        let done = NSButton(title: "Done", target: self, action: #selector(closeSettings))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        done.setContentHuggingPriority(.required, for: .horizontal)
        let doneRow = NSStackView(views: [NSView(), done]) // spacer pushes Done to the right
        doneRow.orientation = .horizontal

        let targetRow = formRow("Target", targetPopup)
        let intervalRow = formRow("Every", intervalPopup)
        let detailRow = formRow("Detail", detailPopup)

        let root = NSStackView(views: [
            sectionLabel("Sources"), scroll, targetRow, intervalRow, detailRow, doneRow,
        ])
        root.orientation = .vertical
        root.alignment = .leading // rows start at the left; wide rows get an explicit width below
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        // Host the stack in a plain content view pinned on all sides. (.leading
        // keeps rows left-aligned; .width alignment only equalises widths and
        // lets narrow rows drift, so instead we pin the full-width rows' widths
        // to the stack minus the 16pt side insets.)
        let container = NSView()
        container.addSubview(root)
        let sideInsets: CGFloat = 32 // left + right edgeInsets
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -sideInsets),
            targetRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -sideInsets),
            intervalRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -sideInsets),
            detailRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -sideInsets),
            doneRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -sideInsets),
        ])
        return container
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return l
    }

    private func groupHeader(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func dimLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func formRow(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal) // pop-up fills the row
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // MARK: populate

    private func reloadSources() {
        for v in sourceStack.arrangedSubviews {
            sourceStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let groups = calendarsByAccount(writableOnly: false)
        guard !groups.isEmpty else {
            sourceStack.addArrangedSubview(dimLabel("Grant Calendar access to choose sources."))
            return
        }
        let selected = Set(Settings.sources)
        for group in groups {
            sourceStack.addArrangedSubview(groupHeader(group.account))
            for c in group.calendars {
                let sel = calendarSelector(c)
                let cb = NSButton(checkboxWithTitle: c.title, target: self, action: #selector(sourceToggled(_:)))
                cb.state = selected.contains(sel) ? .on : .off
                cb.identifier = NSUserInterfaceItemIdentifier(sel) // carry the selector for the action
                let indented = NSStackView(views: [cb]) // indent the calendar under its account header
                indented.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
                sourceStack.addArrangedSubview(indented)
            }
        }
    }

    private func reloadTarget() {
        let menu = NSMenu()
        var toSelect: NSMenuItem?
        for group in calendarsByAccount(writableOnly: true) {
            let header = NSMenuItem(title: group.account, action: nil, keyEquivalent: "")
            header.isEnabled = false // account rows are non-selectable headers
            menu.addItem(header)
            for c in group.calendars {
                let sel = calendarSelector(c)
                let it = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
                it.indentationLevel = 1
                it.representedObject = sel
                menu.addItem(it)
                if sel == Settings.target { toSelect = it }
            }
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "(no writable calendars)", action: nil, keyEquivalent: "")
        }
        targetPopup.menu = menu
        if let it = toSelect { targetPopup.select(it) } else { targetPopup.select(nil) }
    }

    // MARK: actions

    @objc private func sourceToggled(_ sender: NSButton) {
        guard let sel = sender.identifier?.rawValue else { return }
        var cur = Settings.sources
        if sender.state == .on {
            if !cur.contains(sel) { cur.append(sel) }
        } else {
            cur.removeAll { $0 == sel }
        }
        Settings.sources = cur
        onChange()
    }

    @objc private func targetChanged() {
        Settings.target = (targetPopup.selectedItem?.representedObject as? String) ?? ""
        onChange()
    }

    @objc private func intervalChanged() {
        Settings.intervalMinutes = intervalPopup.selectedItem?.tag ?? 30
        onChange()
    }

    @objc private func detailChanged() {
        let tag = detailPopup.selectedItem?.tag ?? 0
        Settings.detail = Self.details.first { $0.tag == tag }?.detail ?? .titleTimeLocation
        onChange()
    }

    @objc private func closeSettings() { window?.close() }
}

// MARK: - menu-bar controller

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var statusLine = "Never synced"
    private var syncing = false
    private var settingsWC: SettingsWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        updateIcon() // a calendar at rest; a spinning sync glyph while syncing
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        requestAccess() // register maccal in the Calendar TCC list up front
        BackgroundAgent.install() // background auto-sync runs whenever sources+target are set
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        addDisabled(menu, statusLine)
        if !Settings.sources.isEmpty, !Settings.target.isEmpty {
            addDisabled(menu, "Auto-syncing every \(intervalLabel(Settings.intervalMinutes))",
                        symbol: "clock.arrow.2.circlepath")
        }
        menu.addItem(.separator())
        add(menu, syncing ? "Syncing…" : "Sync now", #selector(syncNow),
            symbol: "arrow.triangle.2.circlepath", key: "s", enabled: !syncing)
        add(menu, "Settings…", #selector(openSettings), symbol: "gearshape", key: ",")
        menu.addItem(.separator())
        add(menu, "Start at login", #selector(toggleLogin), symbol: "power", state: LoginItem.isEnabled)
        menu.addItem(.separator())
        add(menu, "Calendar access…", #selector(openCalendarSettings), symbol: "lock.shield")
        add(menu, "Quit maccal", #selector(NSApplication.terminate(_:)), symbol: "xmark.circle", key: "q", target: NSApp)
    }

    // MARK: actions

    @objc private func openSettings() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { requestAccess(); return }
        if settingsWC == nil {
            settingsWC = SettingsWindowController(onChange: { BackgroundAgent.install() })
        }
        settingsWC?.show()
    }

    @objc private func syncNow() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { requestAccess(); return }
        let sources = Settings.sources, target = Settings.target, detail = Settings.detail
        guard !sources.isEmpty, !target.isEmpty else { statusLine = "Open Settings to pick sources + target"; return }
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

    @objc private func toggleLogin() { LoginItem.toggle() }

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
        // A calendar with a small sync badge at rest; while a sync is in flight,
        // swap to the plain circular-arrows glyph and spin it (spinning the
        // composite would rotate the calendar too, which looks wrong).
        if syncing {
            b.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "syncing…")
            startSpin(b)
        } else {
            b.image = Self.calendarSyncIcon()
            stopSpin(b)
        }
    }

    /// Composite tray icon: a calendar with a small "sync" (circular arrows)
    /// badge punched into its lower-right corner. SF Symbols has no single
    /// calendar+sync glyph, so we draw one; `isTemplate` lets the menu bar tint it.
    private static func calendarSyncIcon() -> NSImage? {
        let calCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let badgeCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        guard let cal = NSImage(systemSymbolName: "calendar", accessibilityDescription: "maccal sync")?
                .withSymbolConfiguration(calCfg),
              let badge = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
                .withSymbolConfiguration(badgeCfg)
        else { return nil }

        let size = cal.size
        let img = NSImage(size: size)
        img.lockFocus()
        cal.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        // A small sync badge tucked into the lower-right corner (like macrec's
        // mic badge). Clear a little well first so it reads separately from the
        // calendar grid, then draw the glyph at its natural (small) size.
        let bs = badge.size
        let origin = NSPoint(x: size.width - bs.width, y: 0)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(origin: origin, size: bs).insetBy(dx: -1, dy: -1)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        badge.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        img.isTemplate = true
        return img
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

    private func addDisabled(_ menu: NSMenu, _ title: String, symbol: String? = nil) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        mi.isEnabled = false
        menu.addItem(mi)
    }

    private func intervalLabel(_ mins: Int) -> String {
        switch mins {
        case 15: return "15 min"
        case 30: return "30 min"
        case 60: return "1 hour"
        case 120: return "2 hours"
        case 360: return "6 hours"
        default: return "\(mins) min"
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, symbol: String? = nil, key: String = "",
                     state: Bool? = nil, enabled: Bool = true, target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = target ?? self
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
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
