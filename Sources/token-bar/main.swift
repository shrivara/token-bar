// token-bar: menu bar readout of today's AI usage (Claude Code, Codex, OpenCode, pi).
// Aggregation logic lives in TokenBarCore; this file is the AppKit shell.

import AppKit
import CoreServices
import TokenBarCore

// Shown in the right-click menu for debugging which build is running. The .app
// reports its Info.plist version; the raw CLI/Homebrew binary has no Info.plist,
// so fall back to this constant (bump it alongside build.sh on release).
let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.7.5"

// MARK: - Period switching (D / W / M / Y)

enum Period: Int, CaseIterable {
    case day, week, month, year

    var letter: String { ["D", "W", "M", "Y"][rawValue] }
    var title: String { ["today", "this week", "this month", "this year"][rawValue] }
    var caption: String { ["spend per hour", "spend per day", "spend per day", "spend per month"][rawValue] }

    func start(cal: Calendar, now: Date) -> Date {
        let component: Calendar.Component
        switch self {
        case .day: return cal.startOfDay(for: now)
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return cal.dateInterval(of: component, for: now)?.start ?? cal.startOfDay(for: now)
    }

    func bucketSpec(start: Date, cal: Calendar, now: Date) -> BucketSpec {
        switch self {
        case .day:
            return .hours(from: start)
        case .week:
            return BucketSpec(count: 7) { d in
                let i = cal.dateComponents([.day], from: start, to: d).day ?? -1
                return (0..<7).contains(i) ? i : nil
            }
        case .month:
            let n = cal.range(of: .day, in: .month, for: now)?.count ?? 31
            return BucketSpec(count: n) { d in
                let i = cal.dateComponents([.day], from: start, to: d).day ?? -1
                return (0..<n).contains(i) ? i : nil
            }
        case .year:
            return BucketSpec(count: 12) { d in
                let i = cal.dateComponents([.month], from: start, to: d).month ?? -1
                return (0..<12).contains(i) ? i : nil
            }
        }
    }

    /// Axis labels as (fraction of width, text)
    func axis(cal: Calendar, now: Date) -> [(CGFloat, String)] {
        switch self {
        case .day:
            return [(0, "0"), (0.25, "6"), (0.5, "12"), (0.75, "18"), (1, "24")]
        case .week:
            let syms = cal.veryShortStandaloneWeekdaySymbols  // Sunday-first
            let first = cal.firstWeekday - 1
            return (0..<7).map { ((CGFloat($0) + 0.5) / 7, syms[(first + $0) % 7]) }
        case .month:
            let n = CGFloat(cal.range(of: .day, in: .month, for: now)?.count ?? 31)
            return [(0.5 / n, "1"), (14.5 / n, "15"), ((n - 0.5) / n, "\(Int(n))")]
        case .year:
            let syms = cal.veryShortStandaloneMonthSymbols
            return (0..<12).map { ((CGFloat($0) + 0.5) / 12, String(syms[$0].prefix(1))) }
        }
    }
}

// MARK: - Sparkline

// Spend bars over the selected period, sparkline-sized, with axis + caption
final class SparkBarView: NSView {
    var values: [Double] = [] {
        didSet { if values != oldValue { needsDisplay = true } }
    }
    var caption = "spend per hour" {
        didSet { if caption != oldValue { needsDisplay = true } }
    }
    var axis: [(CGFloat, String)] = [] {
        didSet { if axis.map(\.1) != oldValue.map(\.1) { needsDisplay = true } }
    }

    let axisHeight: CGFloat = 11
    let captionHeight: CGFloat = 12

    override var intrinsicContentSize: NSSize { NSSize(width: 222, height: 16 + axisHeight + captionHeight) }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let maxV = max(values.max() ?? 0, .leastNonzeroMagnitude)
        let n = CGFloat(values.count)
        let gap: CGFloat = values.count > 16 ? 1 : 2
        let bw = (bounds.width - gap * (n - 1)) / n
        let barArea = bounds.height - axisHeight - captionHeight

        let tiny: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        // Caption: what the bars mean (left) and the scale (right)
        let captionY = bounds.height - captionHeight + 2
        (caption as NSString).draw(at: NSPoint(x: 0, y: captionY), withAttributes: tiny)
        if let peak = values.max(), peak > 0 {
            let peakText = "peak \(fmtMoney(peak))" as NSString
            let w = peakText.size(withAttributes: tiny).width
            peakText.draw(at: NSPoint(x: bounds.width - w, y: captionY), withAttributes: tiny)
        }

        // Dashed gridlines at the peak (which the tallest bar touches) and halfway
        func dashedLine(at y: CGFloat, alpha: CGFloat) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: y))
            p.line(to: NSPoint(x: bounds.width, y: y))
            p.lineWidth = 0.5
            var pattern: [CGFloat] = [2, 3]
            p.setLineDash(&pattern, count: 2, phase: 0)
            NSColor.labelColor.withAlphaComponent(alpha).setStroke()
            p.stroke()
        }
        if (values.max() ?? 0) > 0 {
            dashedLine(at: axisHeight + barArea, alpha: 0.3)       // peak, labeled above right
            dashedLine(at: axisHeight + barArea / 2, alpha: 0.15)  // half scale
        }

        for (i, v) in values.enumerated() {
            let h = v > 0 ? max(2, CGFloat(v / maxV) * barArea) : 1.5
            let rect = NSRect(x: CGFloat(i) * (bw + gap), y: axisHeight, width: bw, height: h)
            let alpha: CGFloat = v > 0 ? 0.55 : 0.12
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(bw / 3, 2), yRadius: min(bw / 3, 2)).fill()
        }

        for (frac, text) in axis {
            let t = text as NSString
            let w = t.size(withAttributes: tiny).width
            let x = min(max(frac * bounds.width - w / 2, 0), bounds.width - w)
            t.draw(at: NSPoint(x: x, y: 0), withAttributes: tiny)
        }
    }
}

final class ProviderBadgeView: NSView {
    let monogram: String
    let image: NSImage?

    init(provider: String) {
        let glyphProvider = Self.glyphProvider(for: provider)
        let knownMonograms = ["openrouter": "OR"]
        monogram = knownMonograms[glyphProvider]
            ?? String(glyphProvider.uppercased().filter(\.isLetter).prefix(2))
        image = Bundle.module.url(forResource: glyphProvider, withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:))
        super.init(frame: .zero)
    }

    // Providers may be qualified by an integration (for example,
    // `openai-codex` or `anthropic-custom/plan`). Prefer a matching glyph,
    // then remove qualifiers until reaching the bundled provider glyph.
    private static func glyphProvider(for provider: String) -> String {
        var candidate = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while !candidate.isEmpty {
            if Bundle.module.url(forResource: candidate, withExtension: "svg") != nil {
                return candidate
            }
            guard let separator = candidate.lastIndex(where: { "-_/".contains($0) }) else { break }
            candidate = String(candidate[..<separator])
        }
        return provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (monogram as NSString).size(withAttributes: attributes)
        (monogram as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                                y: (bounds.height - size.height) / 2),
                                     withAttributes: attributes)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var eventStream: FSEventStreamRef?
    var pendingRefreshTimer: Timer?
    var displayed = BarValues()
    var animTimer: Timer?
    var statFields: [String: NSTextField] = [:]
    var menuSignature = ""
    var sparkView: SparkBarView?
    var panelView: NSStackView?
    var period: Period = Period(rawValue: UserDefaults.standard.integer(forKey: "period")) ?? .day

    // Left-click shows this info panel; right-click shows the View menu below.
    let panelMenu = NSMenu()

    // View preferences (right-click menu). object(forKey:) distinguishes an
    // unset default (nil) from an explicit false, so first launch keeps the
    // graph and icons on.
    var showGraph = UserDefaults.standard.object(forKey: "showGraph") as? Bool ?? true
    var showProviderIcons = UserDefaults.standard.object(forKey: "showProviderIcons") as? Bool ?? true
    var showFullModelNames = UserDefaults.standard.bool(forKey: "showFullModelNames")

    let scanQueue = DispatchQueue(label: "com.shrivara.tokenbar.scan", qos: .userInitiated)
    var scanning = false
    var scanPending = false
    // Coverage is per-source: Claude Code prunes logs after ~30 days while
    // OpenCode keeps everything, so a shared note would misstate one of them.
    // Each harness header gets "· since Jun 13" only when ITS data falls short
    // of the selected period.
    func headerTitle(for s: SourceStats) -> String {
        guard period != .day, let since = s.dataSince,
              since > period.start(cal: Calendar.current, now: Date()).addingTimeInterval(86_400)
        else { return s.name.uppercased() }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(s.name.uppercased()) · since \(f.string(from: since))"
    }

    // Run a block on the main thread in common run-loop modes. Unlike
    // DispatchQueue.main.async, this also executes while a menu is open
    // (menu tracking parks the run loop in the event-tracking mode, which
    // never drains the main GCD queue).
    func performOnMain(_ block: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.common], block: block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // Timer that keeps firing while a menu is open
    func commonModesTimer(interval: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: repeats) { _ in fire() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        observeMenuTracking(panelMenu)
        // Handle clicks ourselves so left and right can open different menus;
        // a status item with a static .menu can't tell them apart.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refresh()
        startWatching()
        prewarmCaches()
        // Fallback: catches midnight rollover, missed events, and dirs created after launch
        timer = commonModesTimer(interval: 60, repeats: true) { [weak self] in
            self?.refresh()
        }
    }

    // The current period loads first; then, in the background, scan the widest
    // window (year) to populate the parse caches so the first switch to any
    // period is instant instead of paying the full disk read + parse.
    func prewarmCaches() {
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let cal = Calendar.current, now = Date()
            let start = Period.year.start(cal: cal, now: now)
            let spec = Period.year.bucketSpec(start: start, cal: cal, now: now)
            _ = self.scanAll(since: start, buckets: spec)
        }
    }

    func startWatching() {
        let paths = [claudeProjectsRoot.path,
                     codexSessionsRoot.path,
                     openCodeDBPath.deletingLastPathComponent().path,
                     piSessionsRoot.path]
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            me.performOnMain { me.scheduleRefresh() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,  // coalesce events within 500ms
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, scanQueue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    // Debounce bursts of file events into a single rescan (runs on main)
    func scheduleRefresh() {
        pendingRefreshTimer?.invalidate()
        pendingRefreshTimer = commonModesTimer(interval: 0.5, repeats: false) { [weak self] in
            self?.refresh()
        }
    }

    var menuIsOpen = false
    var pendingBar: BarValues?

    // Bar updates are deferred while the menu is open: resizing the status
    // item moves the menu's anchor, so the whole panel would jump sideways
    // on every period switch. The panel shows the live numbers meanwhile.
    // Open state comes from NSMenu's tracking notifications, which fire for
    // every way a menu can open/close (click-away, Esc, app switch) - the
    // delegate's menuDidClose can be missed, leaving the bar frozen.
    func observeMenuTracking(_ menu: NSMenu) {
        // queue: nil delivers synchronously on the posting (main) thread;
        // .main would enqueue onto the stalled-during-tracking main queue
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: menu, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.menuIsOpen = true
            self.refresh()
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: menu, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.menuIsOpen = false
            if let target = self.pendingBar {
                self.pendingBar = nil
                self.animateBar(to: target)
            }
        }
    }

    // Left-click (or the panel) opens the readout; right-click / control-click
    // opens the View menu. The performClick idiom pops the menu with the usual
    // button highlight, then we clear .menu so the next click routes here again.
    @objc func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsViewMenu = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        statusItem.menu = wantsViewMenu ? makeViewMenu() : panelMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func makeViewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func toggle(_ title: String, _ on: Bool, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }

        toggle("Show Spend Graph", showGraph, #selector(toggleGraph))
        toggle("Show Provider Icons", showProviderIcons, #selector(toggleProviderIcons))
        toggle("Show Full Model Names", showFullModelNames, #selector(toggleFullModelNames))
        menu.addItem(.separator())
        // Disabled footer showing the running version, for debugging.
        let version = NSMenuItem(title: "v\(appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        return menu
    }

    // View toggles change the panel's row structure, so force a full rebuild
    // (the signature check would otherwise only refresh text in place).
    func applyViewChange(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        menuSignature = ""
        refresh()
    }

    @objc func toggleGraph() { showGraph.toggle(); applyViewChange("showGraph", showGraph) }
    @objc func toggleProviderIcons() { showProviderIcons.toggle(); applyViewChange("showProviderIcons", showProviderIcons) }
    @objc func toggleFullModelNames() { showFullModelNames.toggle(); applyViewChange("showFullModelNames", showFullModelNames) }

    @objc func quitClicked() { NSApp.terminate(nil) }

    @objc func periodClicked(_ sender: NSButton) {
        guard let p = Period(rawValue: sender.tag), p != period else { return }
        period = p
        UserDefaults.standard.set(p.rawValue, forKey: "period")
        refresh()
    }

    func scanAll(since: Date, buckets: BucketSpec?) -> [SourceStats] {
        [scanClaudeCode(since: since, buckets: buckets),
         scanCodex(since: since, buckets: buckets),
         scanOpenCode(since: since, buckets: buckets),
         scanPi(since: since, buckets: buckets)]
    }

    // Scans run on a background queue (a year-view scan reads every log file;
    // doing that on the main thread on every file event made the UI lag).
    // In-flight scans coalesce: at most one queued behind the current one.
    func refresh() {
        if scanning { scanPending = true; return }
        scanning = true

        let cal = Calendar.current
        let now = Date()
        let period = self.period
        let periodStart = period.start(cal: cal, now: now)
        let spec = period.bucketSpec(start: periodStart, cal: cal, now: now)

        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let sources = self.scanAll(since: periodStart, buckets: spec)
            var total = Agg()
            for s in sources { total.add(s.agg) }
            self.performOnMain {
                // Bar and panel both show the selected period
                self.animateBar(to: BarValues(cost: total.cost, input: total.input,
                                              output: total.output, hit: total.hitRate))
                self.rebuildMenu(total: total, sources: sources)
                self.scanning = false
                if self.scanPending {
                    self.scanPending = false
                    self.refresh()
                }
            }
        }
    }

    func setBarTitle(_ v: BarValues) {
        let text = "\(fmtMoney(v.cost))  \(fmtTokens(v.input))↑ \(fmtTokens(v.output))↓  \(String(format: "%.0f%%", v.hit * 100))"
        // Monospaced digits keep the title from wobbling while values roll
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
    }

    // Roll the bar through intermediate values (ease-out, ~0.8s)
    func animateBar(to target: BarValues) {
        if menuIsOpen {
            pendingBar = target
            return
        }
        animTimer?.invalidate()
        let start = displayed
        guard start != target else {
            setBarTitle(target)  // keep title in sync even when nothing changed (first draw)
            return
        }

        let duration = 0.8
        let t0 = Date()
        animTimer = commonModesTimer(interval: 1.0 / 30.0, repeats: true) { [weak self] in
            guard let self = self else { return }
            let p = min(1, Date().timeIntervalSince(t0) / duration)
            let eased = 1 - pow(1 - p, 3)
            self.displayed = BarValues.lerp(start, target, eased)
            self.setBarTitle(self.displayed)
            if p >= 1 { self.animTimer?.invalidate() }
        }
    }

    func shortModel(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    func provider(for source: SourceStats, model: String) -> String {
        let components = model.split(separator: "/")
        if components.count > 1 { return String(components[0]) }
        // Claude Code logs bare model ids (no provider prefix); they're all
        // Anthropic, so map the source to that glyph instead of "Claude Code".
        if source.name == "Claude Code" { return "anthropic" }
        return source.name
    }

    func activeSources(_ sources: [SourceStats]) -> [SourceStats] {
        sources.filter { $0.available && ($0.agg.cost > 0 || $0.agg.contextTotal > 0 || $0.agg.output > 0) }
            .sorted { $0.agg.cost > $1.agg.cost }  // biggest spender first
    }

    func tokensLine(_ a: Agg) -> String {
        "\(fmtTokens(a.input))↑  \(fmtTokens(a.output))↓   \(String(format: "%.0f%%", a.hitRate * 100)) cache"
    }

    func totalBuckets(_ sources: [SourceStats]) -> [Double] {
        var out = [Double](repeating: 0, count: sources.map { $0.buckets.count }.max() ?? 0)
        for s in sources {
            for (i, v) in s.buckets.enumerated() where i < out.count { out[i] += v }
        }
        return out
    }

    // Rebuild the panel only when its row structure changes (period switch,
    // new model/source); otherwise update text fields in place: no flicker.
    func rebuildMenu(total: Agg, sources: [SourceStats]) {
        ensureMenuSkeleton()
        let active = activeSources(sources)
        let signature = "\(period.rawValue)|" + active
            .map { "\($0.name):\($0.perModel.keys.sorted().joined(separator: ","))" }
            .joined(separator: "|")
        if signature == menuSignature && !statFields.isEmpty {
            updateFields(total: total, active: active)
        } else {
            buildPanelContent(total: total, active: active)
            menuSignature = signature
        }
    }

    func setField(_ key: String, _ value: String) {
        guard let f = statFields[key], f.stringValue != value else { return }
        f.stringValue = value
    }

    // Panel width is sticky: it grows to fit the widest content seen but never
    // shrinks back, so switching periods doesn't make the menu edges jump.
    var stickyWidth: CGFloat = 250

    func resizePanel() {
        guard let panel = panelView else { return }
        panel.layoutSubtreeIfNeeded()
        var size = panel.fittingSize
        // fittingSize can under-measure a detached stack view; pad so the
        // trailing column and descenders never clip
        stickyWidth = max(stickyWidth, size.width + 16)
        size.width = stickyWidth
        size.height += 4
        if size != panel.frame.size { panel.setFrameSize(size) }
    }

    func updateFields(total: Agg, active: [SourceStats]) {
        setField("Spend", fmtMoney(total.cost))
        setField("Tokens", tokensLine(total))
        for s in active { setField("\(s.name)/Header", headerTitle(for: s)) }
        sparkView?.values = totalBuckets(active)
        for s in active {
            for (model, a) in s.perModel {
                let marker = s.unknownPricing.contains(model) ? "~" : ""
                setField("\(s.name)/\(model)/Spend", marker + fmtMoney(a.cost))
                setField("\(s.name)/\(model)/Input", fmtTokens(a.input))
                setField("\(s.name)/\(model)/Output", fmtTokens(a.output))
                setField("\(s.name)/\(model)/Hit", String(format: "%.0f%%", a.hitRate * 100))
            }
        }
        resizePanel()  // in case a value grew wider than the panel was sized for
    }

    // Menu skeleton (panel container, separator, Quit) is created once; the
    // panel's content is rebuilt in place so the menu can stay open.
    func ensureMenuSkeleton() {
        guard panelMenu.items.isEmpty else { return }
        panelMenu.autoenablesItems = false

        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 4
        panel.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        panelView = panel

        let panelItem = NSMenuItem()
        panelItem.view = panel
        panelMenu.addItem(panelItem)

        panelMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        panelMenu.addItem(quit)
    }

    func buildPanelContent(total: Agg, active: [SourceStats]) {
        guard let panel = panelView else { return }
        for v in panel.arrangedSubviews {
            panel.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        statFields.removeAll()

        func label(_ key: String?, _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor, mono: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
            f.textColor = color
            f.alignment = align
            if let key = key { statFields[key] = f }
            return f
        }

        func modelLabel(provider: String, name: String) -> NSView {
            let nameLabel = label(nil, name, size: 12)
            guard showProviderIcons else { return nameLabel }
            let row = NSStackView(views: [ProviderBadgeView(provider: provider), nameLabel])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 5
            return row
        }

        // Header: big spend + period word, with the D W M Y switcher on the right
        let spend = label("Spend", fmtMoney(total.cost), size: 24, weight: .semibold, mono: true)
        let periodLabel = label(nil, period.title, size: 12, color: .secondaryLabelColor)

        let switcher = NSStackView()
        switcher.orientation = .horizontal
        switcher.spacing = 9
        for p in Period.allCases {
            let b = NSButton(title: p.letter, target: self, action: #selector(periodClicked(_:)))
            b.isBordered = false
            b.tag = p.rawValue
            b.attributedTitle = NSAttributedString(
                string: p.letter,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: p == period ? .semibold : .regular),
                    .foregroundColor: p == period ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
                ])
            switcher.addArrangedSubview(b)
        }

        let flexSpacer = NSView()
        flexSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let headerRow = NSStackView(views: [spend, periodLabel, flexSpacer, switcher])
        headerRow.orientation = .horizontal
        headerRow.alignment = .lastBaseline
        headerRow.spacing = 6
        panel.addArrangedSubview(headerRow)
        // Stretch the header across the panel so the switcher sits at the right edge
        headerRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14).isActive = true
        headerRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14).isActive = true

        panel.addArrangedSubview(label("Tokens", tokensLine(total), size: 12,
                                       color: .secondaryLabelColor, mono: true))

        if active.isEmpty {
            panel.setCustomSpacing(12, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(label(nil, "No usage yet for this period", size: 13,
                                          weight: .medium))
            panel.setCustomSpacing(2, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(label(nil,
                                           "Token Bar will populate as you use Claude Code, Codex, OpenCode, or Pi.",
                                           size: 12, color: .secondaryLabelColor))
            resizePanel()
            return
        }

        // Spend timeline for the period
        sparkView = nil
        if showGraph {
            let cal = Calendar.current
            let spark = SparkBarView()
            spark.values = totalBuckets(active)
            spark.caption = period.caption
            spark.axis = period.axis(cal: cal, now: Date())
            sparkView = spark
            panel.setCustomSpacing(8, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(spark)
        }

        // Per-source model table. One shared grid keeps the numeric columns
        // aligned across sources; header-row padding does the visual grouping.
        if !active.isEmpty {
            var rows: [[NSView]] = []
            var headerRowIndices: [Int] = []
            for s in active {
                headerRowIndices.append(rows.count)
                // Column captions ride on the harness header row
                func caption(_ t: String) -> NSTextField {
                    label(nil, t, size: 10, color: .tertiaryLabelColor, align: .right)
                }
                rows.append([label("\(s.name)/Header", headerTitle(for: s), size: 10, weight: .medium,
                                   color: .tertiaryLabelColor),
                             caption("spend"), caption("in"), caption("out"), caption("hit")])
                for (model, a) in s.perModel.sorted(by: { $0.value.cost > $1.value.cost }) {
                    let marker = s.unknownPricing.contains(model) ? "~" : ""
                    let displayName = showFullModelNames ? model : shortModel(model)
                    rows.append([
                        modelLabel(provider: provider(for: s, model: model), name: displayName),
                        label("\(s.name)/\(model)/Spend", marker + fmtMoney(a.cost), size: 12,
                              color: .secondaryLabelColor, mono: true, align: .right),
                        label("\(s.name)/\(model)/Input", fmtTokens(a.input), size: 12,
                              color: .secondaryLabelColor, mono: true, align: .right),
                        label("\(s.name)/\(model)/Output", fmtTokens(a.output), size: 12,
                              color: .secondaryLabelColor, mono: true, align: .right),
                        label("\(s.name)/\(model)/Hit", String(format: "%.0f%%", a.hitRate * 100), size: 12,
                              color: .secondaryLabelColor, mono: true, align: .right),
                    ])
                }
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 3
            grid.columnSpacing = 14
            for col in 1..<5 { grid.column(at: col).xPlacement = .trailing }
            // A header binds to the rows below it: generous space above,
            // a small fixed gap below, uniform row spacing within a section.
            for i in headerRowIndices {
                grid.row(at: i).topPadding = i == 0 ? 0 : 10
                grid.row(at: i).bottomPadding = 1
            }
            panel.setCustomSpacing(12, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(grid)
        }

        resizePanel()
    }
}

if CommandLine.arguments.contains("--print") {
    let dayStart = Calendar.current.startOfDay(for: Date())
    let sources = [scanClaudeCode(since: dayStart), scanCodex(since: dayStart),
                   scanOpenCode(since: dayStart), scanPi(since: dayStart)]
    var total = Agg()
    for s in sources { total.add(s.agg) }
    for s in sources where s.available {
        for (model, a) in s.perModel.sorted(by: { $0.value.cost > $1.value.cost }) {
            print("\(s.name) / \(model): in=\(Int(a.input)) out=\(Int(a.output)) cache_read=\(Int(a.cacheRead)) cache_write=\(Int(a.cacheWrite)) cost=\(fmtMoney(a.cost))")
        }
    }
    print("TOTAL: spend=\(fmtMoney(total.cost)) in=\(Int(total.input)) out=\(Int(total.output)) hit=\(String(format: "%.1f%%", total.hitRate * 100))")
    print("BAR: \(fmtMoney(total.cost))  \(fmtTokens(total.input))↑ \(fmtTokens(total.output))↓  \(String(format: "%.0f%%", total.hitRate * 100))")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
