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
import IOKit.pwr_mgt
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
            d.object(forKey: "detailRaw") == nil
                ? [.title, .location]                         // default: title + location
                : SyncDetail(rawValue: d.integer(forKey: "detailRaw"))
        }
        set { d.set(newValue.rawValue, forKey: "detailRaw") }
    }
    static var keepAwake: Bool {
        get { d.bool(forKey: "keepAwake") }
        set { d.set(newValue, forKey: "keepAwake") }
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
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        let svc = SMAppService.mainApp
        do {
            if on { try svc.register() } else { try svc.unregister() }
        } catch { NSLog("maccalbar: login item toggle failed: \(error)") }
        return isEnabled // authoritative state (register/unregister may have thrown)
    }
}

// MARK: - keep awake (prevent idle sleep so scheduled syncs keep running)

@MainActor
enum KeepAwake {
    private static var assertionID: IOPMAssertionID = 0
    private static var active = false

    static var isOn: Bool { active }

    /// Prevent (or release) idle system sleep. Clamshell (lid-close) sleep can't
    /// be blocked — this only keeps an otherwise-idle Mac awake so the launchd
    /// sync job keeps firing.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        if on, !active {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "maccal: keeping awake for scheduled sync" as CFString,
                &id) == kIOReturnSuccess {
                assertionID = id
                active = true
            }
        } else if !on, active {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            active = false
        }
        return active // real assertion state (creation may have failed)
    }
}

// MARK: - custom toggle menu item (native look + doesn't close the menu)

/// Mimics a native checkmark menu item — leading SF Symbol, title, trailing
/// checkmark, and the blue hover highlight — but does NOT dismiss the menu on
/// click, so several toggles can be flipped in a row.
///
/// Trade-off (intentional; raised in Copilot review on PR #8): being a custom,
/// mouse-driven view instead of a real NSMenuItem, it does NOT support keyboard
/// navigation (arrow keys / Return). On macOS, "clicking keeps the menu open"
/// and full keyboard menu control are effectively mutually exclusive for a menu
/// item, and we chose the former. VoiceOver is still served via the
/// accessibility role/label/value set in init().
@MainActor
final class MenuToggleView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let checkView = NSImageView()
    private var isOn: Bool
    private let toggle: () -> Bool   // performs the side effect, returns the real resulting state
    private var hovered = false

    init(title: String, symbol: String, on: Bool, toggle: @escaping () -> Bool) {
        self.isOn = on
        self.toggle = toggle
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        autoresizingMask = .width

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.frame = NSRect(x: 14, y: 3, width: 16, height: 16)
        addSubview(iconView)

        label.stringValue = title
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 36, y: 3, width: 178, height: 16)
        label.autoresizingMask = .width
        addSubview(label)

        checkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        checkView.imageScaling = .scaleProportionallyDown
        checkView.frame = NSRect(x: 218, y: 5, width: 12, height: 12)
        checkView.autoresizingMask = .minXMargin
        checkView.isHidden = !on
        addSubview(checkView)

        updateColors()

        // accessibility: present as a checkbox menu item so VoiceOver announces
        // the label and the on/off (checked) state.
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(on)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateColors(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; updateColors(); needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        isOn = toggle() // authoritative new state — the side effect may have failed
        checkView.isHidden = !isOn
        setAccessibilityValue(isOn)
        // intentionally does NOT close the enclosing menu
    }

    private func updateColors() {
        let fg: NSColor = hovered ? .white : .labelColor
        iconView.contentTintColor = fg
        label.textColor = fg
        checkView.contentTintColor = fg
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }
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
    private var detailChecks: [NSButton] = []

    private static let intervals: [(tag: Int, label: String)] =
        [(15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"), (360, "6 hours")]
    // Title is mandatory (always copied). Location/Notes are independent toggles.
    private static let detailFields: [(label: String, option: SyncDetail)] =
        [("Location", .location), ("Notes", .notes)]

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
        syncDetailChecks()
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
        for i in Self.intervals { intervalPopup.addItem(withTitle: i.label); intervalPopup.lastItem?.tag = i.tag }
        let titleCheck = NSButton(checkboxWithTitle: "Title", target: nil, action: nil)
        titleCheck.tag = -2 // mandatory + read-only (shown checked, disabled)
        titleCheck.isEnabled = false
        titleCheck.toolTip = "Always included (title is mandatory)"
        detailChecks = [titleCheck] + Self.detailFields.enumerated().map { idx, f in
            let cb = NSButton(checkboxWithTitle: f.label, target: self, action: #selector(detailToggled(_:)))
            cb.tag = idx // 0=Location, 1=Notes
            return cb
        }

        let done = NSButton(title: "Done", target: self, action: #selector(closeSettings))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        done.setContentHuggingPriority(.required, for: .horizontal)
        let doneRow = NSStackView(views: [NSView(), done]) // spacer pushes Done to the right
        doneRow.orientation = .horizontal

        let targetRow = formRow("Target", symbol: "calendar.badge.plus", targetPopup)
        let intervalRow = formRow("Every", symbol: "clock", intervalPopup)
        let detailBox = NSStackView(views: detailChecks)
        detailBox.orientation = .horizontal
        detailBox.spacing = 12
        let detailRow = formRow("Detail", symbol: "list.bullet", detailBox)

        let root = NSStackView(views: [
            sectionLabel("Sources", symbol: "calendar"), scroll, targetRow, intervalRow, detailRow, doneRow,
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

    private func sectionLabel(_ s: String, symbol: String? = nil) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        guard let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return l }
        let icon = NSImageView(image: img)
        icon.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, l])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        return row
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

    private func formRow(_ title: String, symbol: String, _ control: NSView) -> NSStackView {
        let label = sectionLabel(title, symbol: symbol) // same bold style + icon as the section headers
        let row = NSStackView(views: [label, control])
        row.orientation = .vertical
        row.alignment = .leading // label + control both start at the left edge
        row.spacing = 10 // match the gap under the "Sources" header (root spacing)
        // control fills the row width, so it lines up left AND right with the box
        control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    // MARK: populate

    private func reloadSources() {
        for v in sourceStack.arrangedSubviews {
            sourceStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            sourceStack.addArrangedSubview(dimLabel("Grant Calendar access to choose sources."))
            return
        }
        let groups = calendarsByAccount(writableOnly: false)
        guard !groups.isEmpty else {
            sourceStack.addArrangedSubview(dimLabel("No calendars found."))
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
        if let it = toSelect { targetPopup.select(it) }
        else if menu.items.count == 1 { targetPopup.select(menu.items.first) } // lone placeholder — keep it visible
        else { targetPopup.select(nil) }
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

    @objc private func detailToggled(_ sender: NSButton) {
        var d = Settings.detail
        let opt = Self.detailFields[sender.tag].option
        if sender.state == .on { d.insert(opt) } else { d.remove(opt) }
        Settings.detail = d
        onChange()
    }

    /// Reflect Settings.detail onto the checkboxes. Title is always on (mandatory,
    /// shown disabled); Location/Notes reflect the current selection.
    private func syncDetailChecks() {
        for cb in detailChecks {
            if cb.tag == -2 { cb.state = .on; continue } // Title: mandatory
            cb.state = Settings.detail.contains(Self.detailFields[cb.tag].option) ? .on : .off
        }
    }

    @objc private func closeSettings() { window?.close() }
}

// MARK: - menu-bar controller

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastResult: String?   // last manual-sync outcome, shown when present
    private var syncing = false
    private var settingsWC: SettingsWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        updateIcon() // a calendar at rest; a spinning sync glyph while syncing
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        requestAccess() // register maccal in the Calendar TCC list up front
        BackgroundAgent.install() // background auto-sync runs whenever sources+target are set
        Settings.keepAwake = KeepAwake.set(Settings.keepAwake) // restore + reconcile with the real assertion state
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        if Settings.sources.isEmpty || Settings.target.isEmpty {
            addDisabled(menu, "Set sources + target in Settings")
        } else if syncing {
            addDisabled(menu, "Syncing…", symbol: "arrow.triangle.2.circlepath")
        } else {
            if let last = SyncStatus.last() { // manual OR background sync (shared file)
                let counts = abbreviate(last.summary).map { "   \($0)" } ?? ""
                addDisabled(menu, "Last synced \(shortTime(last.date))\(counts)", symbol: "checkmark.circle")
            } else if let r = lastResult {
                addDisabled(menu, r) // no successful sync yet — show the latest outcome (e.g. an error)
            }
            addDisabled(menu, "Auto-syncing every \(intervalLabel(Settings.intervalMinutes))",
                        symbol: "clock.arrow.2.circlepath")
            // show the selected sources → target so they're visible without opening
            // Settings; direction icons distinguish outgoing sources from the target
            for s in Settings.sources { addDisabled(menu, shortName(s), symbol: "arrow.down.circle") }
            addDisabled(menu, shortName(Settings.target), symbol: "arrow.up.circle")
        }
        menu.addItem(.separator())
        add(menu, syncing ? "Syncing…" : "Sync now", #selector(syncNow),
            symbol: "arrow.triangle.2.circlepath", key: "s", enabled: !syncing)
        add(menu, "Settings…", #selector(openSettings), symbol: "gearshape", key: ",")
        menu.addItem(.separator())
        menu.addItem(toggleItem("Start at login", symbol: "power", on: LoginItem.isEnabled) {
            LoginItem.set(!LoginItem.isEnabled) // returns the real state after a (maybe failed) register/unregister
        })
        menu.addItem(toggleItem("Keep awake for sync", symbol: "cup.and.saucer", on: KeepAwake.isOn) {
            let now = KeepAwake.set(!KeepAwake.isOn) // real assertion state
            Settings.keepAwake = now                 // persist what actually happened
            return now
        })
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
        guard !sources.isEmpty, !target.isEmpty else { return } // the menu already prompts for this
        syncing = true
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
        if ok {
            SyncStatus.record(at: Date(), summary: msg) // shared with the background CLI job
            lastResult = nil
        } else {
            lastResult = "⚠︎ \(msg)"
        }
    }


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
        // swap to the plain circular-arrows glyph and spin it.
        if syncing {
            b.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "syncing…")
            startSpin(b)
        } else {
            b.image = Self.calendarSyncIcon()
            stopSpin(b)
        }
    }

    /// A large sync ring (circular arrows) with a small calendar centred inside
    /// it. Both symbols are centre-symmetric, so the menu bar centres the icon
    /// cleanly (no drift), and the calendar sits in the ring's empty middle with
    /// no overlap. `isTemplate` lets the menu bar tint it.
    private static func calendarSyncIcon() -> NSImage? {
        let syncCfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .light)
        let calCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular) // simple, symmetric, no dots
        guard let sync = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "maccal sync")?
                .withSymbolConfiguration(syncCfg),
              let cal = NSImage(systemSymbolName: "square", accessibilityDescription: nil)?
                .withSymbolConfiguration(calCfg)
        else { return nil }

        let size = sync.size
        let img = NSImage(size: size)
        img.lockFocus()
        sync.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        // small square centred inside the ring — `square` is symmetric, so plain
        // centring lands true (no nudge, unlike the asymmetric calendar glyph).
        let calOrigin = NSPoint(x: (size.width - cal.size.width) / 2,
                                y: (size.height - cal.size.height) / 2)
        cal.draw(at: calOrigin, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.black.setFill()
        // thicken the square's top edge (calendar-header hint): left edge flush
        // with the square, right edge pulled in a touch so it doesn't overrun.
        let barH: CGFloat = 1.3
        NSBezierPath(rect: NSRect(x: calOrigin.x + 1,
                                  y: calOrigin.y + cal.size.height - barH - 0.5,
                                  width: cal.size.width - 3, height: barH)).fill()
        // four tiny dots (2×2) inside the square — a hint of calendar day marks;
        // nudged slightly left to sit centred in the square glyph
        let dot: CGFloat = 1.2
        let cx = calOrigin.x + cal.size.width / 2 - 0.5
        let cy = calOrigin.y + cal.size.height / 2 - 0.5
        let gap: CGFloat = 2.4
        for dx in [-gap / 2, gap / 2] {
            for dy in [-gap / 2, gap / 2] {
                NSBezierPath(ovalIn: NSRect(x: cx + dx - dot / 2, y: cy + dy - dot / 2, width: dot, height: dot)).fill()
            }
        }
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

    /// A native-looking toggle item (via MenuToggleView) that does NOT dismiss
    /// the menu on click.
    private func toggleItem(_ title: String, symbol: String, on: Bool, toggle: @escaping () -> Bool) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title // keep a title so the item stays identifiable to accessibility
        item.view = MenuToggleView(title: title, symbol: symbol, on: on, toggle: toggle)
        return item
    }

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

    private func shortName(_ selector: String) -> String {
        selector.split(separator: "/").last.map(String.init) ?? selector
    }

    private func shortTime(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    /// Condense runSync's human line to just the counts, so the menu doesn't grow
    /// wide: "synced: <label>   +5 new  ~2 changed  -1 removed  ✂3 cancelled"
    /// becomes "+5 ~2 -1 ✂3".
    private func abbreviate(_ line: String) -> String? {
        guard let r = line.range(of: "   +") else { return nil } // counts start after the label
        let counts = line[r.lowerBound...]
            .replacingOccurrences(of: " new", with: "")
            .replacingOccurrences(of: " changed", with: "")
            .replacingOccurrences(of: " removed", with: "")
            .replacingOccurrences(of: " cancelled", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return counts.isEmpty ? nil : counts
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
