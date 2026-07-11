// token-bar: menu bar readout of today's AI usage (Claude Code, OpenCode, pi).
// Aggregation logic lives in TokenBarCore; this file is the AppKit shell.

import AppKit
import CoreServices
import TokenBarCore

// 24 hourly spend bars, sparkline-sized, with an hour axis (0 6 12 18 24)
final class SparkBarView: NSView {
    var values = [Double](repeating: 0, count: 24) {
        didSet { if values != oldValue { needsDisplay = true } }
    }

    let axisHeight: CGFloat = 11

    override var intrinsicContentSize: NSSize { NSSize(width: 222, height: 16 + axisHeight) }

    override func draw(_ dirtyRect: NSRect) {
        let maxV = max(values.max() ?? 0, .leastNonzeroMagnitude)
        let n = CGFloat(values.count)
        let gap: CGFloat = 2
        let bw = (bounds.width - gap * (n - 1)) / n
        let barArea = bounds.height - axisHeight

        for (i, v) in values.enumerated() {
            let h = v > 0 ? max(2, CGFloat(v / maxV) * barArea) : 1.5
            let rect = NSRect(x: CGFloat(i) * (bw + gap), y: axisHeight, width: bw, height: h)
            let alpha: CGFloat = v > 0 ? 0.55 : 0.12
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: bw / 3, yRadius: bw / 3).fill()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for hour in [0, 6, 12, 18, 24] {
            let text = "\(hour)" as NSString
            let w = text.size(withAttributes: attrs).width
            let tick = CGFloat(hour) * (bw + gap)  // leading edge of that hour's bar
            let x = hour == 0 ? 0 : hour == 24 ? bounds.width - w : tick - w / 2
            text.draw(at: NSPoint(x: x, y: 0), withAttributes: attrs)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var eventStream: FSEventStreamRef?
    var pendingRefresh: DispatchWorkItem?
    var displayed = BarValues()
    var animTimer: Timer?
    var statFields: [String: NSTextField] = [:]
    var menuSignature = ""
    var sparkView: SparkBarView?

    func totalHourly(_ sources: [SourceStats]) -> [Double] {
        var out = [Double](repeating: 0, count: 24)
        for s in sources {
            for (i, v) in s.hourly.enumerated() where i < out.count { out[i] += v }
        }
        return out
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        startWatching()
        // Fallback: catches midnight rollover, missed events, and dirs created after launch
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func startWatching() {
        let paths = [claudeProjectsRoot.path,
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
            Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue().scheduleRefresh()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,  // coalesce events within 500ms
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    // Debounce bursts of file events into a single rescan
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc func quitClicked() { NSApp.terminate(nil) }

    func refresh() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let sources = [
            scanClaudeCode(since: dayStart),
            scanOpenCode(since: dayStart),
            scanPi(since: dayStart),
        ]
        var total = Agg()
        for s in sources { total.add(s.agg) }

        animateBar(to: BarValues(cost: total.cost, input: total.input,
                                 output: total.output, hit: total.hitRate))
        rebuildMenu(total: total, sources: sources)
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
        animTimer?.invalidate()
        let start = displayed
        guard start != target else {
            setBarTitle(target)  // keep title in sync even when nothing changed (first draw)
            return
        }

        let duration = 0.8
        let t0 = Date()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(t0) / duration)
            let eased = 1 - pow(1 - p, 3)
            self.displayed = BarValues.lerp(start, target, eased)
            self.setBarTitle(self.displayed)
            if p >= 1 { timer.invalidate() }
        }
    }

    func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    func activeSources(_ sources: [SourceStats]) -> [SourceStats] {
        sources.filter { $0.available && ($0.agg.cost > 0 || $0.agg.contextTotal > 0 || $0.agg.output > 0) }
            .sorted { $0.agg.cost > $1.agg.cost }  // biggest spender first
    }

    func tokensLine(_ a: Agg) -> String {
        "\(fmtTokens(a.input))↑  \(fmtTokens(a.output))↓   \(String(format: "%.0f%%", a.hitRate * 100)) cache"
    }

    // Rebuild the panel only when its row structure changes (new model/source);
    // otherwise update the text fields in place so an open menu never flickers.
    func rebuildMenu(total: Agg, sources: [SourceStats]) {
        let active = activeSources(sources)
        let signature = active.map { "\($0.name):\($0.perModel.keys.sorted().joined(separator: ","))" }
            .joined(separator: "|")
        if signature == menuSignature && !statFields.isEmpty {
            updateFields(total: total, active: active)
        } else {
            buildMenu(total: total, active: active)
            menuSignature = signature
        }
    }

    func setField(_ key: String, _ value: String) {
        guard let f = statFields[key], f.stringValue != value else { return }
        f.stringValue = value
    }

    func updateFields(total: Agg, active: [SourceStats]) {
        setField("Today/Spend", fmtMoney(total.cost))
        setField("Today/Tokens", tokensLine(total))
        sparkView?.values = totalHourly(active)
        for s in active {
            for (model, a) in s.perModel {
                let marker = s.unknownPricing.contains(model) ? "~" : ""
                setField("\(s.name)/\(model)/Spend", marker + fmtMoney(a.cost))
                setField("\(s.name)/\(model)/Input", fmtTokens(a.input))
                setField("\(s.name)/\(model)/Output", fmtTokens(a.output))
                setField("\(s.name)/\(model)/Hit", String(format: "%.0f%%", a.hitRate * 100))
            }
        }
        // Re-measure in case a value grew wider than the panel was sized for
        if let panel = statusItem.menu?.items.first?.view {
            panel.layoutSubtreeIfNeeded()
            var size = panel.fittingSize
            size.width = max(size.width + 16, 250)
            size.height += 4
            if size != panel.frame.size { panel.setFrameSize(size) }
        }
    }

    func buildMenu(total: Agg, active: [SourceStats]) {
        guard let menu = statusItem.menu else { return }
        menu.autoenablesItems = false
        menu.removeAllItems()
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

        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 4
        panel.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        // Header: big spend, then the token summary line
        let spend = label("Today/Spend", fmtMoney(total.cost), size: 24, weight: .semibold, mono: true)
        let today = label(nil, "today", size: 12, color: .secondaryLabelColor)
        let headerRow = NSStackView(views: [spend, today])
        headerRow.orientation = .horizontal
        headerRow.alignment = .lastBaseline
        headerRow.spacing = 6
        panel.addArrangedSubview(headerRow)
        panel.addArrangedSubview(label("Today/Tokens", tokensLine(total), size: 12,
                                       color: .secondaryLabelColor, mono: true))

        // Tiny hourly spend sparkline
        let spark = SparkBarView()
        spark.values = totalHourly(active)
        sparkView = spark
        panel.setCustomSpacing(8, after: panel.arrangedSubviews.last!)
        panel.addArrangedSubview(spark)

        // Per-source model table. One shared grid keeps the numeric columns
        // aligned across sources; header-row padding does the visual grouping.
        if !active.isEmpty {
            var rows: [[NSView]] = []
            var headerRowIndices: [Int] = []
            for s in active {
                headerRowIndices.append(rows.count)
                rows.append([label(nil, s.name.uppercased(), size: 10, weight: .medium,
                                   color: .tertiaryLabelColor),
                             NSView(), NSView(), NSView(), NSView()])
                for (model, a) in s.perModel.sorted(by: { $0.value.cost > $1.value.cost }) {
                    let marker = s.unknownPricing.contains(model) ? "~" : ""
                    rows.append([
                        label(nil, shortModel(model), size: 12),
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

        panel.layoutSubtreeIfNeeded()
        var size = panel.fittingSize
        // fittingSize can under-measure a detached stack view; pad so the
        // trailing column and descenders never clip
        size.width = max(size.width + 16, 250)
        size.height += 4
        panel.setFrameSize(size)

        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
    }
}

if CommandLine.arguments.contains("--print") {
    let dayStart = Calendar.current.startOfDay(for: Date())
    let sources = [scanClaudeCode(since: dayStart), scanOpenCode(since: dayStart), scanPi(since: dayStart)]
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
