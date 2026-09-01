// token-bar: menu bar readout of today's AI usage (Claude Code, Codex, OpenCode, pi).
// Aggregation logic lives in TokenBarCore; this file is the AppKit shell.

import AppKit
import CoreServices
import TokenBarCore

// Shown in the right-click menu for debugging which build is running. The .app
// reports its Info.plist version; the raw CLI/Homebrew binary has no Info.plist,
// so fall back to this constant (bump it alongside build.sh on release).
let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.8.44"

// Use the bundle identifier for preferences even when Homebrew launches the
// raw executable (which otherwise writes to token-bar.plist). Preserve settings
// from existing formula installs on first use of each key.
let appDefaults: UserDefaults = {
    let canonical = UserDefaults(suiteName: "com.shrivara.tokenbar") ?? .standard
    let legacy = UserDefaults(suiteName: "token-bar")
    for key in ["period", "periodRangeStyle", "showGraph", "showProviderIcons",
                "showFullModelNames", "menuBarFields", "theme",
                "showExperimentalAttribution"]
        where canonical.object(forKey: key) == nil {
        if let value = legacy?.object(forKey: key) {
            canonical.set(value, forKey: key)
        }
    }
    return canonical
}()

// MARK: - Panel themes

private extension NSColor {
    static func tokenBarRGB(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

struct PanelPalette {
    let background: NSColor
    let surface: NSColor
    let primary: NSColor
    let secondary: NSColor
    let muted: NSColor
    let accent: NSColor
    let border: NSColor
}

enum PanelTheme: String, CaseIterable {
    case system
    case catppuccinMocha = "catppuccin-mocha"
    case dracula
    case gruvboxDark = "gruvbox-dark"
    case nord
    case solarizedDark = "solarized-dark"
    case tokyoNight = "tokyo-night"
    case catppuccinLatte = "catppuccin-latte"
    case githubLight = "github-light"
    case gruvboxLight = "gruvbox-light"
    case solarizedLight = "solarized-light"

    var title: String {
        switch self {
        case .system: return "System"
        case .catppuccinMocha: return "Catppuccin Mocha"
        case .dracula: return "Dracula"
        case .gruvboxDark: return "Gruvbox Dark"
        case .nord: return "Nord"
        case .solarizedDark: return "Solarized Dark"
        case .tokyoNight: return "Tokyo Night"
        case .catppuccinLatte: return "Catppuccin Latte"
        case .githubLight: return "GitHub Light"
        case .gruvboxLight: return "Gruvbox Light"
        case .solarizedLight: return "Solarized Light"
        }
    }

    private static let systemPalette = PanelPalette(
        background: .windowBackgroundColor,
        surface: .controlBackgroundColor,
        primary: .labelColor,
        secondary: .secondaryLabelColor,
        muted: .tertiaryLabelColor,
        accent: .labelColor,
        border: .separatorColor
    )
    private static let catppuccinMochaPalette = PanelPalette(
        background: .tokenBarRGB(0x1e1e2e),
        surface: .tokenBarRGB(0x313244),
        primary: .tokenBarRGB(0xcdd6f4),
        secondary: .tokenBarRGB(0xa6adc8),
        muted: .tokenBarRGB(0x7f849c),
        accent: .tokenBarRGB(0xcba6f7),
        border: .tokenBarRGB(0x45475a)
    )
    private static let draculaPalette = PanelPalette(
        background: .tokenBarRGB(0x282a36),
        surface: .tokenBarRGB(0x44475a),
        primary: .tokenBarRGB(0xf8f8f2),
        secondary: .tokenBarRGB(0xbfbfbf),
        muted: .tokenBarRGB(0x6272a4),
        accent: .tokenBarRGB(0xbd93f9),
        border: .tokenBarRGB(0x44475a)
    )
    private static let gruvboxDarkPalette = PanelPalette(
        background: .tokenBarRGB(0x282828),
        surface: .tokenBarRGB(0x3c3836),
        primary: .tokenBarRGB(0xebdbb2),
        secondary: .tokenBarRGB(0xd5c4a1),
        muted: .tokenBarRGB(0x928374),
        accent: .tokenBarRGB(0xfabd2f),
        border: .tokenBarRGB(0x504945)
    )
    private static let nordPalette = PanelPalette(
        background: .tokenBarRGB(0x2e3440),
        surface: .tokenBarRGB(0x3b4252),
        primary: .tokenBarRGB(0xeceff4),
        secondary: .tokenBarRGB(0xd8dee9),
        muted: .tokenBarRGB(0x81a1c1),
        accent: .tokenBarRGB(0x88c0d0),
        border: .tokenBarRGB(0x4c566a)
    )
    private static let solarizedDarkPalette = PanelPalette(
        background: .tokenBarRGB(0x002b36),
        surface: .tokenBarRGB(0x073642),
        primary: .tokenBarRGB(0x93a1a1),
        secondary: .tokenBarRGB(0x839496),
        muted: .tokenBarRGB(0x657b83),
        accent: .tokenBarRGB(0x2aa198),
        border: .tokenBarRGB(0x586e75)
    )
    private static let tokyoNightPalette = PanelPalette(
        background: .tokenBarRGB(0x1a1b26),
        surface: .tokenBarRGB(0x24283b),
        primary: .tokenBarRGB(0xc0caf5),
        secondary: .tokenBarRGB(0xa9b1d6),
        muted: .tokenBarRGB(0x565f89),
        accent: .tokenBarRGB(0x7aa2f7),
        border: .tokenBarRGB(0x3b4261)
    )
    private static let catppuccinLattePalette = PanelPalette(
        background: .tokenBarRGB(0xeff1f5),
        surface: .tokenBarRGB(0xdce0e8),
        primary: .tokenBarRGB(0x4c4f69),
        secondary: .tokenBarRGB(0x5c5f77),
        muted: .tokenBarRGB(0x7c7f93),
        accent: .tokenBarRGB(0x8839ef),
        border: .tokenBarRGB(0xbcc0cc)
    )
    private static let githubLightPalette = PanelPalette(
        background: .tokenBarRGB(0xffffff),
        surface: .tokenBarRGB(0xf6f8fa),
        primary: .tokenBarRGB(0x1f2328),
        secondary: .tokenBarRGB(0x59636e),
        muted: .tokenBarRGB(0x6e7781),
        accent: .tokenBarRGB(0x0969da),
        border: .tokenBarRGB(0xd0d7de)
    )
    private static let gruvboxLightPalette = PanelPalette(
        background: .tokenBarRGB(0xfbf1c7),
        surface: .tokenBarRGB(0xebdbb2),
        primary: .tokenBarRGB(0x3c3836),
        secondary: .tokenBarRGB(0x504945),
        muted: .tokenBarRGB(0x7c6f64),
        accent: .tokenBarRGB(0xb57614),
        border: .tokenBarRGB(0xd5c4a1)
    )
    private static let solarizedLightPalette = PanelPalette(
        background: .tokenBarRGB(0xfdf6e3),
        surface: .tokenBarRGB(0xeee8d5),
        primary: .tokenBarRGB(0x586e75),
        secondary: .tokenBarRGB(0x657b83),
        muted: .tokenBarRGB(0x839496),
        accent: .tokenBarRGB(0x268bd2),
        border: .tokenBarRGB(0x93a1a1)
    )

    var palette: PanelPalette {
        switch self {
        case .system: return Self.systemPalette
        case .catppuccinMocha: return Self.catppuccinMochaPalette
        case .dracula: return Self.draculaPalette
        case .gruvboxDark: return Self.gruvboxDarkPalette
        case .nord: return Self.nordPalette
        case .solarizedDark: return Self.solarizedDarkPalette
        case .tokyoNight: return Self.tokyoNightPalette
        case .catppuccinLatte: return Self.catppuccinLattePalette
        case .githubLight: return Self.githubLightPalette
        case .gruvboxLight: return Self.gruvboxLightPalette
        case .solarizedLight: return Self.solarizedLightPalette
        }
    }

    // Preserve the existing monochrome controls for System; named themes use
    // their signature accent for the graph and selected period.
    var selectionColor: NSColor {
        self == .system ? palette.secondary : palette.accent
    }

    var isLight: Bool {
        switch self {
        case .catppuccinLatte, .githubLight, .gruvboxLight, .solarizedLight:
            return true
        default:
            return false
        }
    }

    // Match the popover's native chrome to each fixed palette while System
    // continues to inherit the current macOS appearance.
    var chromeAppearance: NSAppearance? {
        guard self != .system else { return nil }
        return NSAppearance(named: isLight ? .aqua : .darkAqua)
    }

    static func load(from defaults: UserDefaults) -> PanelTheme {
        guard let rawValue = defaults.string(forKey: "theme"),
              let theme = PanelTheme(rawValue: rawValue)
        else { return .system }
        return theme
    }

    var swatchImage: NSImage {
        let colors = palette
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let swatchRect = rect.insetBy(dx: 1, dy: 1)
            let outline = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
            colors.background.setFill()
            outline.fill()
            colors.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: swatchRect.maxX - 5.5,
                                        y: swatchRect.minY + 1.5,
                                        width: 4, height: 4)).fill()
            colors.border.setStroke()
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

final class ThemedPanelView: NSStackView {
    var theme: PanelTheme = .system {
        didSet { if theme != oldValue { needsDisplay = true } }
    }
    var usesSnapshotStyle = false {
        didSet { if usesSnapshotStyle != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if theme != .system {
            let colors = theme.palette
            colors.background.setFill()
            if usesSnapshotStyle {
                NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()

                let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
                let border = NSBezierPath(roundedRect: borderRect, xRadius: 11.5, yRadius: 11.5)
                colors.border.withAlphaComponent(0.75).setStroke()
                border.lineWidth = 1
                border.stroke()
            } else {
                NSBezierPath(rect: bounds).fill()
            }
        }
        super.draw(dirtyRect)
    }
}

// With full-size popover content this view reaches into the native chevron.
// Fill it for every theme so the panel and pointed triangle keep a stable
// palette color when this menu-bar app is not the active application. Leaving
// System transparent exposes AppKit's inactive popover material, which dims the
// whole dashboard until the status item is highlighted again.
final class ThemedPopoverContentView: NSView {
    var theme: PanelTheme = .system {
        didSet { if theme != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        theme.palette.background.setFill()
        NSBezierPath(rect: bounds).fill()
        super.draw(dirtyRect)
    }
}

struct MenuBarFields: OptionSet {
    let rawValue: Int

    static let spend = MenuBarFields(rawValue: 1 << 0)
    static let inputTokens = MenuBarFields(rawValue: 1 << 1)
    static let outputTokens = MenuBarFields(rawValue: 1 << 2)
    static let cacheHitRate = MenuBarFields(rawValue: 1 << 3)
    static let all: MenuBarFields = [.spend, .inputTokens, .outputTokens, .cacheHitRate]

    static let defaultsKey = "menuBarFields"

    static func load(from defaults: UserDefaults) -> MenuBarFields {
        guard let number = defaults.object(forKey: defaultsKey) as? NSNumber else { return .all }
        let fields = MenuBarFields(rawValue: number.intValue & all.rawValue)
        guard fields.isEmpty else { return fields }

        // A missing/corrupt selection must not leave an invisible status item.
        defaults.set(MenuBarFields.spend.rawValue, forKey: defaultsKey)
        return .spend
    }
}

// MARK: - Period switching (D / W / M / Y)

typealias Period = UsagePeriod

extension UsagePeriod {
    var letter: String { ["D", "W", "M", "Y"][rawValue] }
    var caption: String { ["spend per hour", "spend per day", "spend per day", "spend per month"][rawValue] }

    func title(rangeStyle: PeriodRangeStyle) -> String {
        if rangeStyle == .relative {
            return ["today", "last 7 days", "last 30 days", "last 12 months"][rawValue]
        }
        return ["today", "this week", "this month", "this year"][rawValue]
    }

    /// Axis labels as (fraction of width, text)
    func axis(cal: Calendar, now: Date, rangeStyle: PeriodRangeStyle) -> [(CGFloat, String)] {
        switch self {
        case .day:
            return [(0, "0"), (0.25, "6"), (0.5, "12"), (0.75, "18"), (1, "24")]
        case .week:
            let start = start(cal: cal, now: now, rangeStyle: rangeStyle)
            let symbols = cal.veryShortStandaloneWeekdaySymbols
            return (0..<7).map { index in
                let date = cal.date(byAdding: .day, value: index, to: start) ?? start
                let weekday = max(0, cal.component(.weekday, from: date) - 1)
                let symbol = weekday < symbols.count ? symbols[weekday] : "\(weekday + 1)"
                return ((CGFloat(index) + 0.5) / 7, symbol)
            }
        case .month where rangeStyle == .relative:
            let start = start(cal: cal, now: now, rangeStyle: rangeStyle)
            let formatter = DateFormatter()
            formatter.calendar = cal
            formatter.locale = cal.locale ?? .current
            formatter.timeZone = cal.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return [0, 14, 29].map { index in
                let date = cal.date(byAdding: .day, value: index, to: start) ?? start
                return ((CGFloat(index) + 0.5) / 30, formatter.string(from: date))
            }
        case .month:
            let n = CGFloat(cal.range(of: .day, in: .month, for: now)?.count ?? 31)
            return [(0.5 / n, "1"), (14.5 / n, "15"), ((n - 0.5) / n, "\(Int(n))")]
        case .year:
            let start = start(cal: cal, now: now, rangeStyle: rangeStyle)
            let symbols = cal.veryShortStandaloneMonthSymbols
            return (0..<12).map { index in
                let date = cal.date(byAdding: .month, value: index, to: start) ?? start
                let month = max(0, cal.component(.month, from: date) - 1)
                let symbol = month < symbols.count ? symbols[month] : "\(month + 1)"
                return ((CGFloat(index) + 0.5) / 12, String(symbol.prefix(1)))
            }
        }
    }
}

// MARK: - Sparkline

// Spend bars over the selected period, sparkline-sized, with axis + caption
private final class LaserOverlayView: NSView {
    var origins: [NSPoint] = []
    var endpoints: [NSPoint] = []
    var colors: [NSColor] = []
    var highlightColor = NSColor.white
    var laserVisible = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard laserVisible, origins.count == endpoints.count else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Match the rounded dashboard so no beam appears beyond its box.
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
        for index in origins.indices {
            let beam = NSBezierPath()
            beam.move(to: origins[index])
            beam.line(to: endpoints[index])
            beam.lineCapStyle = .round
            (index < colors.count ? colors[index] : .systemRed)
                .withAlphaComponent(0.78).setStroke()
            beam.lineWidth = 1.5
            beam.stroke()
            highlightColor.withAlphaComponent(0.92).setStroke()
            beam.lineWidth = 0.4
            beam.stroke()
        }
    }
}

fileprivate struct CatMotionState {
    let position: CGFloat
    let direction: CGFloat
    let nextActivityIn: TimeInterval
}

final class SparkBarView: NSView {
    var values: [Double] = [] {
        didSet {
            guard values != oldValue else { return }
            if values.count != oldValue.count, pendingCatAction != nil {
                pendingCatAction = nil
                pendingCatStop = nil
                nextCatActivityIn = min(max(nextCatActivityIn, 1), 10)
            }
            needsDisplay = true
        }
    }
    var caption = "spend per hour" {
        didSet { if caption != oldValue { needsDisplay = true } }
    }
    var axis: [(CGFloat, String)] = [] {
        didSet { if axis.map(\.1) != oldValue.map(\.1) { needsDisplay = true } }
    }
    var theme: PanelTheme = .system {
        didSet { if theme != oldValue { needsDisplay = true } }
    }
    var catEnabled = false {
        didSet {
            guard catEnabled != oldValue else { return }
            invalidateIntrinsicContentSize()
            updateCatTimer()
            needsDisplay = true
        }
    }
    var catAnimating = false {
        didSet { if catAnimating != oldValue { updateCatTimer() } }
    }

    private enum CatAction: Equatable {
        case walk, lick, blink, zoom, pant, sit, stretch
    }

    private var catTimer: Timer?
    private var laserOverlay: LaserOverlayView?
    private var catPosition: CGFloat = 0
    private var catDirection: CGFloat = 1
    private var catAction: CatAction = .walk
    private var catLastUpdate = ProcessInfo.processInfo.systemUptime
    private var catActionStartedAt = 0.0
    private var catActionEndsAt = 0.0
    private var pendingCatAction: (action: CatAction, duration: TimeInterval)?
    private var pendingCatStop: CGFloat?
    private var nextCatActivityIn = 0.0
    let axisHeight: CGFloat = 11
    let captionHeight: CGFloat = 12

    override var intrinsicContentSize: NSSize {
        NSSize(width: 222, height: (catEnabled ? 27 : 16) + axisHeight + captionHeight)
    }

    deinit {
        catTimer?.invalidate()
        laserOverlay?.removeFromSuperview()
    }

    // Match the display refresh cadence for smooth tiny-glyph motion. The timer
    // exists only while the panel is visible; Reduce Motion keeps a static cat.
    private func updateCatTimer() {
        catTimer?.invalidate()
        catTimer = nil
        guard catEnabled, catAnimating,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hideLaserOverlay()
            needsDisplay = true
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        catLastUpdate = now
        if nextCatActivityIn <= 0 { nextCatActivityIn = Double.random(in: 1...10) }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.advanceCat()
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        catTimer = timer
    }

    fileprivate func motionState() -> CatMotionState {
        let activityInFlight = catAction != .walk || pendingCatAction != nil
        return CatMotionState(position: catPosition,
                              direction: catDirection,
                              nextActivityIn: activityInFlight
                                  ? Double.random(in: 1...10) : nextCatActivityIn)
    }

    fileprivate func restoreMotionState(_ state: CatMotionState) {
        catPosition = min(max(state.position, 0), 1)
        catDirection = state.direction < 0 ? -1 : 1
        nextCatActivityIn = state.nextActivityIn
    }

    private func advanceCat() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(now - catLastUpdate, 0), 0.5)
        catLastUpdate = now

        if catAction != .walk, now >= catActionEndsAt {
            if catAction == .zoom {
                // Decelerate naturally onto the next bar before recovering.
                catAction = .walk
                queueCatAction(.pant, duration: 7, at: now)
            } else {
                catAction = .walk
                nextCatActivityIn = Double.random(in: 1...10)
            }
        }
        if catAction == .walk, pendingCatAction == nil {
            nextCatActivityIn -= elapsed
            if nextCatActivityIn <= 0 { queueRandomCatAction(at: now) }
        }

        let speed: CGFloat
        switch catAction {
        case .walk: speed = 1
        case .zoom: speed = 5
        case .blink, .lick, .pant, .sit, .stretch: speed = 0
        }
        guard speed > 0 else { return }

        // A normal crossing takes ten seconds regardless of bar count.
        // Clamp before reversing so the cat always reaches the end bar.
        let nextPosition = catPosition + catDirection * CGFloat(elapsed / 10) * speed
        if let stop = pendingCatStop, let pending = pendingCatAction {
            let reachedStop = catDirection > 0 ? nextPosition >= stop : nextPosition <= stop
            if reachedStop {
                catPosition = stop
                if stop >= 1 { catDirection = -1 }
                if stop <= 0 { catDirection = 1 }
                pendingCatStop = nil
                pendingCatAction = nil
                startCatAction(pending.action, duration: pending.duration, at: now)
                return
            }
        }

        catPosition = nextPosition
        if catPosition >= 1 {
            catPosition = 1
            catDirection = -1
        } else if catPosition <= 0 {
            catPosition = 0
            catDirection = 1
        }
    }

    private func queueRandomCatAction(at now: TimeInterval) {
        let roll = Int.random(in: 0..<100)
        let activity: (CatAction, TimeInterval)
        switch roll {
        case 0..<25: activity = (.lick, 8)
        case 25..<45: activity = (.blink, 6)
        case 45..<55: activity = (.zoom, 3.5)
        case 55..<80: activity = (.sit, 12)
        default: activity = (.stretch, 8)
        }
        queueCatAction(activity.0, duration: activity.1, at: now)
    }

    private func queueCatAction(_ action: CatAction, duration: TimeInterval, at now: TimeInterval) {
        // Zoomies are intentionally sudden. All stationary activities wait for
        // the next bar top instead of snapping the cat by a few pixels.
        if action == .zoom || values.count < 2 {
            startCatAction(action, duration: duration, at: now)
            return
        }
        let last = CGFloat(values.count - 1)
        let barPosition = catPosition * last
        let targetBar: CGFloat
        if catDirection > 0 {
            targetBar = min(last, floor(barPosition + 0.0001) + 1)
        } else {
            targetBar = max(0, ceil(barPosition - 0.0001) - 1)
        }
        pendingCatAction = (action, duration)
        pendingCatStop = targetBar / last
    }

    private func startCatAction(_ action: CatAction, duration: TimeInterval, at now: TimeInterval) {
        catAction = action
        catActionStartedAt = now
        catActionEndsAt = now + duration
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let maxV = max(values.max() ?? 0, .leastNonzeroMagnitude)
        let n = CGFloat(values.count)
        let gap: CGFloat = values.count > 16 ? 1 : 2
        let bw = (bounds.width - gap * (n - 1)) / n
        let graphHeight = bounds.height - axisHeight - captionHeight
        // Reserve just enough room above the tallest bar for the cat.
        let barArea = graphHeight - (catEnabled ? 11 : 0)
        let colors = theme.palette

        let tiny: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: colors.muted,
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
            colors.primary.withAlphaComponent(alpha).setStroke()
            p.stroke()
        }
        if (values.max() ?? 0) > 0 {
            dashedLine(at: axisHeight + barArea, alpha: 0.3)       // peak, labeled above right
            dashedLine(at: axisHeight + barArea / 2, alpha: 0.15)  // half scale
        }

        for (i, v) in values.enumerated() {
            let h = v > 0 ? max(2, CGFloat(v / maxV) * barArea) : 1.5
            let rect = NSRect(x: CGFloat(i) * (bw + gap), y: axisHeight, width: bw, height: h)
            let alpha: CGFloat
            if theme == .system {
                alpha = v > 0 ? 0.55 : 0.12
            } else {
                alpha = v > 0 ? 0.68 : 0.16
            }
            colors.accent.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(bw / 3, 2), yRadius: min(bw / 3, 2)).fill()
        }

        if catEnabled { drawCat(maxValue: maxV, barWidth: bw, gap: gap, barArea: barArea) }

        for (frac, text) in axis {
            let t = text as NSString
            let w = t.size(withAttributes: tiny).width
            let x = min(max(frac * bounds.width - w / 2, 0), bounds.width - w)
            t.draw(at: NSPoint(x: x, y: 0), withAttributes: tiny)
        }
    }

    private func drawCat(maxValue: Double, barWidth: CGFloat, gap: CGFloat, barArea: CGFloat) {
        guard !values.isEmpty else { return }
        let last = max(values.count - 1, 0)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = ProcessInfo.processInfo.systemUptime
        let action = reduceMotion ? CatAction.walk : catAction
        let actionDuration = max(catActionEndsAt - catActionStartedAt, 0.001)
        let actionProgress = min(max((now - catActionStartedAt) / actionDuration, 0), 1)

        func x(_ index: Int) -> CGFloat { CGFloat(index) * (barWidth + gap) + barWidth / 2 }
        func y(_ index: Int) -> CGFloat {
            let value = values[index]
            let height = value > 0 ? max(2, CGFloat(value / maxValue) * barArea) : 1.5
            return axisHeight + height
        }

        let position: CGFloat
        if reduceMotion {
            let index = values.indices.max(by: { values[$0] < values[$1] }) ?? 0
            position = last > 0 ? CGFloat(index) / CGFloat(last) : 0
        } else {
            position = catPosition
        }
        let catX = x(0) + (x(last) - x(0)) * position
        let catY: CGFloat
        if last == 0 || position >= 1 {
            catY = y(last)
        } else {
            let barPosition = position * CGFloat(last)
            let lower = min(Int(floor(barPosition)), last - 1)
            let upper = lower + 1
            let segmentProgress = barPosition - CGFloat(lower)
            let heightChange = abs(y(upper) - y(lower))
            let hopHeight: CGFloat = heightChange > 2 ? 3 + heightChange * 0.2 : 0.5
            catY = y(lower) + (y(upper) - y(lower)) * segmentProgress
                + sin(.pi * segmentProgress) * hopHeight
        }

        let moving = action == .walk || action == .zoom
        let gait = Int(now * (action == .zoom ? 9 : 4)).isMultiple(of: 2)
        let actionWave = CGFloat(sin(.pi * actionProgress))
        let headX: CGFloat = action == .blink ? 0
            : ((action == .sit || action == .pant) ? 0.5 : 1)
        let headYOffset: CGFloat
        switch action {
        case .sit: headYOffset = 1.2
        case .stretch: headYOffset = -0.7
        case .lick: headYOffset = -0.7 + CGFloat(sin(actionProgress * .pi * 8)) * 0.35
        case .pant: headYOffset = 0.7 + CGFloat(sin(actionProgress * .pi * 12)) * 0.18
        case .blink: headYOffset = -0.5 * actionWave
        default: headYOffset = 0
        }
        let headXOffset = headX - 1
        let catAlpha: CGFloat = theme == .system ? 0.78 : 0.82
        let catColor = theme.palette.primary.withAlphaComponent(catAlpha)

        if action == .zoom, !reduceMotion, catAnimating, window?.isVisible == true {
            updateLaserOverlay(catX: catX, catY: catY, at: now)
        } else {
            hideLaserOverlay()
        }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: catX, yBy: catY)
        if catDirection < 0, !reduceMotion { transform.scaleX(by: -1, yBy: 1) }
        transform.concat()
        catColor.setFill()
        catColor.setStroke()

        if action == .zoom {
            let streaks = NSBezierPath()
            streaks.move(to: NSPoint(x: -9, y: 2))
            streaks.line(to: NSPoint(x: -6, y: 2))
            streaks.move(to: NSPoint(x: -8, y: 4))
            streaks.line(to: NSPoint(x: -5.5, y: 4))
            streaks.lineWidth = 0.7
            streaks.stroke()
        }

        let bodyRect: NSRect
        switch action {
        case .sit: bodyRect = NSRect(x: -2.7, y: 0.5, width: 4.9, height: 7.2)
        case .blink: bodyRect = NSRect(x: -4.8, y: 0.7 + actionWave * 0.2,
                                       width: 8.3, height: 5.5 - actionWave * 0.3)
        case .pant:
            let breath = abs(CGFloat(sin(actionProgress * .pi * 12))) * 0.45
            bodyRect = NSRect(x: -2.9 - breath / 2, y: 0.5,
                              width: 5.2 + breath, height: 6.4 + breath / 2)
        case .stretch: bodyRect = NSRect(x: -5.2, y: 0.7, width: 9, height: 3.3)
        case .zoom: bodyRect = NSRect(x: -5.3, y: 1, width: 8.5, height: 4)
        default: bodyRect = NSRect(x: -4.5, y: 1, width: 7, height: 4.5)
        }
        NSBezierPath(ovalIn: bodyRect).fill()
        NSBezierPath(ovalIn: NSRect(x: headX, y: 2.2 + headYOffset,
                                    width: 4.5, height: 4.5)).fill()

        let ears = NSBezierPath()
        ears.move(to: NSPoint(x: 1.5 + headXOffset, y: 5.7 + headYOffset))
        ears.line(to: NSPoint(x: 2.1 + headXOffset, y: 8 + headYOffset))
        ears.line(to: NSPoint(x: 3.1 + headXOffset, y: 6.3 + headYOffset))
        ears.move(to: NSPoint(x: 3.5 + headXOffset, y: 6.3 + headYOffset))
        ears.line(to: NSPoint(x: 4.8 + headXOffset, y: 7.9 + headYOffset))
        ears.line(to: NSPoint(x: 5 + headXOffset, y: 5.5 + headYOffset))
        ears.fill()

        let tail = NSBezierPath()
        if action == .blink {
            // A curled tail and loaf-shaped body make the slow blink readable
            // even when the eye itself is only a fraction of a point tall.
            tail.move(to: NSPoint(x: -4, y: 2.8))
            tail.curve(to: NSPoint(x: 1.2, y: 1.2),
                       controlPoint1: NSPoint(x: -6.5, y: 0.4),
                       controlPoint2: NSPoint(x: -1.5, y: 0.2))
        } else {
            let tailFlick = action == .zoom ? 3.5
                : (action == .pant ? 4.8 : 6.8 + CGFloat(sin(now * 5)) * 0.8)
            tail.move(to: NSPoint(x: -4, y: 3.5))
            tail.curve(to: NSPoint(x: -6.2, y: tailFlick),
                       controlPoint1: NSPoint(x: -7, y: 3),
                       controlPoint2: NSPoint(x: -7, y: 6.3))
        }
        tail.lineWidth = action == .blink ? 1.5 : 1.2
        tail.lineCapStyle = .round
        tail.stroke()

        let legs = NSBezierPath()
        if moving {
            let stride: CGFloat = gait ? 0.6 : -0.6
            for (index, baseX) in [-3.2, -1.8, -0.1, 1.2].enumerated() {
                let offset = index.isMultiple(of: 2) ? stride : -stride
                legs.move(to: NSPoint(x: baseX, y: 2))
                legs.line(to: NSPoint(x: baseX + offset, y: 0))
            }
        } else if action == .stretch {
            // Two planted hind legs and two long front legs.
            legs.move(to: NSPoint(x: -4.1, y: 2))
            legs.line(to: NSPoint(x: -4.5, y: 0))
            legs.move(to: NSPoint(x: -2.7, y: 2))
            legs.line(to: NSPoint(x: -2.4, y: 0))
            legs.move(to: NSPoint(x: 1.5, y: 2))
            legs.line(to: NSPoint(x: 5.5, y: 0))
            legs.move(to: NSPoint(x: 0.3, y: 2))
            legs.line(to: NSPoint(x: 4.2, y: 0))
        } else if action == .lick {
            // Three grounded legs; the raised paw below is the fourth.
            for baseX in [-3.2, -1.7, 0.2] {
                legs.move(to: NSPoint(x: baseX, y: 2))
                legs.line(to: NSPoint(x: baseX, y: 0))
            }
        } else if action == .pant || action == .sit {
            // Front legs plus two rear paws visible beneath the seated body.
            legs.move(to: NSPoint(x: 0.1, y: 3.2))
            legs.line(to: NSPoint(x: 0.6, y: 0))
            legs.move(to: NSPoint(x: 1.2, y: 3))
            legs.line(to: NSPoint(x: 1.7, y: 0))
            legs.move(to: NSPoint(x: -2.5, y: 1.5))
            legs.line(to: NSPoint(x: -3.2, y: 0))
            legs.move(to: NSPoint(x: -1.5, y: 1.5))
            legs.line(to: NSPoint(x: -1.2, y: 0))
        } else if action != .blink {
            for baseX in [-3.2, -1.8, -0.1, 1.2] {
                legs.move(to: NSPoint(x: baseX, y: 2))
                legs.line(to: NSPoint(x: baseX, y: 0))
            }
        }
        legs.lineWidth = moving ? 0.85 : 0.95
        legs.lineCapStyle = .round
        legs.stroke()

        if action == .lick {
            let paw = NSBezierPath()
            paw.move(to: NSPoint(x: -0.3, y: 2.3))
            paw.line(to: NSPoint(x: 3.4, y: 4 + headYOffset))
            paw.lineWidth = 1.6
            paw.lineCapStyle = .round
            paw.stroke()
            if Int(actionProgress * 8).isMultiple(of: 2) {
                catColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4.5, y: 1.4 + headYOffset,
                                            width: 1.5, height: 2.3)).fill()
            }
        }

        // Contrasting details are monochrome cutouts from the silhouette.
        let detailColor = theme == .system ? theme.palette.surface : theme.palette.background
        detailColor.withAlphaComponent(0.9).setFill()
        if action == .pant {
            let mouthHeight = 0.9 + abs(CGFloat(sin(actionProgress * .pi * 12))) * 0.9
            NSBezierPath(ovalIn: NSRect(x: 4 + headXOffset,
                                        y: 2.1 + headYOffset - mouthHeight / 2,
                                        width: 1.2, height: mouthHeight)).fill()
        }

        if action == .zoom {
            drawLaserEyes()
        } else {
            // A contrasting eye becomes a short line during the slow-blink action.
            detailColor.withAlphaComponent(0.9).setStroke()
            let blinkClosed = action == .blink && sin(.pi * actionProgress) > 0.35
            if blinkClosed {
                let eye = NSBezierPath()
                eye.move(to: NSPoint(x: 4 + headXOffset, y: 4.7 + headYOffset))
                eye.line(to: NSPoint(x: 4.8 + headXOffset, y: 4.7 + headYOffset))
                eye.lineWidth = 0.65
                eye.stroke()
            } else {
                NSBezierPath(ovalIn: NSRect(x: 4.1 + headXOffset, y: 4.5 + headYOffset,
                                            width: 0.75, height: 0.75)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLaserEyes() {
        let origins = [NSPoint(x: 2.6, y: 5), NSPoint(x: 4.15, y: 4.9)]
        let colors = laserOverlay?.colors ?? []
        for (index, origin) in origins.enumerated() {
            (index < colors.count ? colors[index] : .systemRed).setFill()
            NSBezierPath(ovalIn: NSRect(x: origin.x - 0.6, y: origin.y - 0.6,
                                        width: 1.2, height: 1.2)).fill()
        }
    }

    private func updateLaserOverlay(catX: CGFloat, catY: CGFloat, at now: TimeInterval) {
        guard catAnimating, window?.isVisible == true,
              let container = laserContainerView() else {
            hideLaserOverlay()
            return
        }
        container.layoutSubtreeIfNeeded()
        let panelBounds = container.safeAreaRect
        guard panelBounds.width > 0, panelBounds.height > 0 else {
            hideLaserOverlay()
            return
        }
        ensureLaserOverlay(in: container, frame: panelBounds)
        guard let overlay = laserOverlay else { return }

        let facing: CGFloat = catDirection < 0 ? -1 : 1
        let localEyes = [NSPoint(x: 2.6, y: 5), NSPoint(x: 4.15, y: 4.9)]
        overlay.origins = localEyes.map { eye in
            let viewPoint = NSPoint(x: catX + facing * eye.x, y: catY + eye.y)
            return convert(viewPoint, to: overlay)
        }
        guard overlay.origins.allSatisfy(overlay.bounds.contains) else {
            hideLaserOverlay()
            return
        }

        // Hold each random direction for a few display frames. Rays stop at the
        // rounded dashboard body, excluding the popover pointer and shadow.
        let flash = Int(floor(now * 12))
        overlay.laserVisible = !flash.isMultiple(of: 4)
        func randomUnit(_ salt: Double) -> CGFloat {
            let value = sin(Double(flash) * 12.9898 + salt * 78.233) * 43_758.5453
            return CGFloat(value - floor(value))
        }
        let laserBounds = overlay.bounds.insetBy(dx: 1, dy: 1)
        overlay.endpoints = overlay.origins.enumerated().map { index, origin in
            let angle = randomUnit(Double(index) + 0.7) * .pi * 2
            return rayEndpoint(from: origin, angle: angle, in: laserBounds)
        }
        overlay.colors = overlay.origins.map { _ in .systemRed }
        overlay.isHidden = false
        overlay.needsDisplay = true
    }

    private func rayEndpoint(from origin: NSPoint, angle: CGFloat, in rect: NSRect) -> NSPoint {
        let dx = cos(angle), dy = sin(angle)
        var distances: [CGFloat] = []
        if dx > 0.0001 { distances.append((rect.maxX - origin.x) / dx) }
        if dx < -0.0001 { distances.append((rect.minX - origin.x) / dx) }
        if dy > 0.0001 { distances.append((rect.maxY - origin.y) / dy) }
        if dy < -0.0001 { distances.append((rect.minY - origin.y) / dy) }
        let distance = distances.filter { $0 >= 0 }.min() ?? 0
        return NSPoint(x: origin.x + dx * distance, y: origin.y + dy * distance)
    }

    private func laserContainerView() -> NSView? {
        var candidate = superview
        while let view = candidate {
            if view is ThemedPopoverContentView { return view }
            candidate = view.superview
        }
        return window?.contentView
    }

    private func ensureLaserOverlay(in container: NSView, frame: NSRect) {
        if let overlay = laserOverlay, overlay.superview === container {
            if overlay.frame != frame { overlay.frame = frame }
            overlay.highlightColor = (theme == .system || theme.isLight)
                ? .white : theme.palette.primary
            return
        }
        laserOverlay?.removeFromSuperview()
        let overlay = LaserOverlayView(frame: frame)
        overlay.highlightColor = (theme == .system || theme.isLight)
            ? .white : theme.palette.primary
        overlay.isHidden = true
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        laserOverlay = overlay
    }

    private func hideLaserOverlay() {
        laserOverlay?.laserVisible = false
        laserOverlay?.isHidden = true
    }
}

final class ProviderBadgeView: NSView {
    let monogram: String
    let image: NSImage?
    var theme: PanelTheme

    init(provider: String, theme: PanelTheme = .system) {
        let glyphProvider = Self.glyphProvider(for: provider)
        let knownMonograms = ["openrouter": "OR"]
        monogram = knownMonograms[glyphProvider]
            ?? String(glyphProvider.uppercased().filter(\.isLetter).prefix(2))
        image = Bundle.module.url(forResource: glyphProvider, withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:))
        self.theme = theme
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
        let colors = theme.palette
        if let image {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        if theme == .system {
            colors.muted.withAlphaComponent(0.2).setFill()
        } else {
            colors.surface.setFill()
        }
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold),
            .foregroundColor: colors.secondary,
        ]
        let size = (monogram as NSString).size(withAttributes: attributes)
        (monogram as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                                y: (bounds.height - size.height) / 2),
                                     withAttributes: attributes)
    }
}

// MARK: - App

struct SessionLaunchTarget {
    let source: String
    let id: String
    let projectPath: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var eventStream: FSEventStreamRef?
    var pendingRefreshTimer: Timer?
    var outsideClickMonitor: Any?
    var displayed = BarValues()
    var animTimer: Timer?
    var statFields: [String: NSTextField] = [:]
    var sessionLaunchTargets: [String: SessionLaunchTarget] = [:]
    var panelSignature = ""
    var latestPanelData: (period: Period, rangeStyle: PeriodRangeStyle,
                          total: Agg, sources: [SourceStats])?
    var sparkView: SparkBarView?
    fileprivate var savedCatMotionState: CatMotionState?
    let panelPopover = NSPopover()
    var panelContentView: ThemedPopoverContentView?
    var panelView: ThemedPanelView?
    var panelScrollView: NSScrollView?
    var periodField: NSTextField?
    var periodButtons: [NSButton] = []
    var screenshotButton: NSButton?
    var period: Period = Period(rawValue: appDefaults.integer(forKey: "period")) ?? .day
    var periodRangeStyle = PeriodRangeStyle(
        rawValue: appDefaults.integer(forKey: "periodRangeStyle")) ?? .calendar

    // Left-click shows the dashboard popover; right-click shows the View menu.

    // View preferences (right-click menu). object(forKey:) distinguishes an
    // unset default (nil) from an explicit false, so first launch keeps the
    // graph and icons on.
    var showGraph = appDefaults.object(forKey: "showGraph") as? Bool ?? true
    var showProviderIcons = appDefaults.object(forKey: "showProviderIcons") as? Bool ?? true
    var showFullModelNames = appDefaults.bool(forKey: "showFullModelNames")
    var menuBarFields = MenuBarFields.load(from: appDefaults)
    var panelTheme = PanelTheme.load(from: appDefaults)
    // Experimental features are opt-in; unset preferences must stay disabled.
    var showExperimentalCat = appDefaults.object(forKey: "showExperimentalCat") as? Bool ?? false
    var showExperimentalAttribution = appDefaults.object(forKey: "showExperimentalAttribution") as? Bool ?? false

    let scanQueue = DispatchQueue(label: "com.shrivara.tokenbar.scan", qos: .userInitiated)
    var scanning = false
    var scanPending = false
    // Coverage is per-source: Claude Code prunes logs after ~30 days while
    // OpenCode keeps everything, so a shared note would misstate one of them.
    // Each harness header gets "· since Jun 13" only when ITS data falls short
    // of the selected period.
    func headerTitle(for s: SourceStats) -> String {
        guard period != .day, let since = s.dataSince,
              since > period.start(cal: Calendar.current, now: Date(),
                                   rangeStyle: periodRangeStyle).addingTimeInterval(86_400)
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
        panelPopover.behavior = .transient
        panelPopover.animates = false
        panelPopover.hasFullSizeContent = true
        panelPopover.delegate = self
        panelPopover.appearance = panelTheme.chromeAppearance
        ensurePanelSkeleton()
        buildPanelContent(total: Agg(), active: [])
        // Handle clicks ourselves so left and right can open different surfaces;
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
            let rangeStyle = self.periodRangeStyle
            let start = Period.year.start(cal: cal, now: now, rangeStyle: rangeStyle)
            let spec = Period.year.bucketSpec(start: start, cal: cal, now: now,
                                              rangeStyle: rangeStyle)
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

    var panelIsOpen = false
    var pendingBar: BarValues?

    func startOutsideClickMonitoring() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            self.performOnMain {
                if self.panelPopover.isShown { self.closePanel() }
            }
        }
    }

    func stopOutsideClickMonitoring() {
        guard let monitor = outsideClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        outsideClickMonitor = nil
    }

    // The status title is allowed to keep updating in the popover itself, but
    // its menu-bar representation is deferred while anchored. Changing the
    // button width would otherwise move the popover sideways during a refresh.
    func popoverWillShow(_ notification: Notification) {
        panelIsOpen = true
        statusItem.button?.highlight(true)
        sparkView?.catAnimating = showExperimentalCat
        startOutsideClickMonitoring()
        // Full-size content reports its chevron/rounded-corner safe area once
        // AppKit creates the popover window. Account for it before presentation.
        resizePanel()
        refresh()
    }

    func popoverDidShow(_ notification: Notification) {
        // Recheck after AppKit's final layout in case the preferred edge changed.
        resizePanel()
        scrollPanelToTop()
        // With animations disabled, didShow runs before NSStatusBarButton ends
        // mouse tracking and clears its pressed state. Main-queue work resumes
        // after tracking finishes, so reassert the selection there.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelPopover.isShown else { return }
            self.statusItem.button?.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        panelIsOpen = false
        stopOutsideClickMonitoring()
        statusItem.button?.highlight(false)
        sparkView?.catAnimating = false
        if let target = pendingBar {
            pendingBar = nil
            animateBar(to: target)
        }
    }

    func scrollPanelToTop() {
        guard let panel = panelView, let scrollView = panelScrollView else { return }
        let revealHeader = { [weak panel, weak scrollView] in
            guard let panel, let scrollView,
                  let header = panel.arrangedSubviews.first else { return }
            panel.layoutSubtreeIfNeeded()
            scrollView.layoutSubtreeIfNeeded()
            header.scrollToVisible(header.bounds)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        revealHeader()
        // A content-size change lays out the popover window on the next pass;
        // reveal it again after the clip view has adopted its final height.
        performOnMain(revealHeader)
    }

    func showPanel() {
        guard let button = statusItem.button else { return }
        ensurePanelSkeleton()
        resizePanel()
        panelPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        scrollPanelToTop()
    }

    func closePanel() {
        panelPopover.performClose(nil)
    }

    // Left-click toggles the dashboard popover; right-click / control-click
    // retains a native command menu. The performClick idiom gives that menu its
    // usual status-button highlight, then .menu is cleared for the next click.
    @objc func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsViewMenu = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if wantsViewMenu {
            if panelPopover.isShown { closePanel() }
            statusItem.menu = makeViewMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panelPopover.isShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    func makeViewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func submenu(_ title: String) -> NSMenu {
            let child = NSMenu(title: title)
            child.autoenablesItems = false
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = child
            menu.addItem(item)
            return child
        }

        @discardableResult
        func toggle(in targetMenu: NSMenu, _ title: String, _ on: Bool,
                    _ selector: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            targetMenu.addItem(item)
            return item
        }

        let menuBarMenu = submenu("Show in Menu Bar")
        let canRemoveSelectedField = menuBarFields.rawValue.nonzeroBitCount > 1
        func menuBarToggle(_ title: String, _ field: MenuBarFields, _ selector: Selector) {
            let selected = menuBarFields.contains(field)
            let item = toggle(in: menuBarMenu, title, selected, selector)
            // Keep the sole selected field checked, rather than allowing the
            // status item to become empty and impossible to find.
            item.isEnabled = !selected || canRemoveSelectedField
            if !item.isEnabled {
                item.toolTip = "At least one item must remain visible in the menu bar."
            }
        }
        menuBarToggle("Spend", .spend, #selector(toggleMenuBarSpend))
        menuBarToggle("Input Tokens", .inputTokens, #selector(toggleMenuBarInputTokens))
        menuBarToggle("Output Tokens", .outputTokens, #selector(toggleMenuBarOutputTokens))
        menuBarToggle("Cache Hit Rate", .cacheHitRate, #selector(toggleMenuBarCacheHitRate))

        let showInPanelMenu = submenu("Show in Panel")
        toggle(in: showInPanelMenu, "Spend Graph", showGraph, #selector(toggleGraph))
        toggle(in: showInPanelMenu, "Provider Icons", showProviderIcons,
               #selector(toggleProviderIcons))
        toggle(in: showInPanelMenu, "Full Model Names", showFullModelNames,
               #selector(toggleFullModelNames))
        showInPanelMenu.addItem(.sectionHeader(title: "Experimental"))
        let cat = toggle(in: showInPanelMenu, "Animated Cat",
                         showExperimentalCat, #selector(toggleExperimentalCat))
        cat.toolTip = "Appears on the spend graph."
        let attribution = toggle(in: showInPanelMenu, "Projects & Sessions",
                                 showExperimentalAttribution,
                                 #selector(toggleExperimentalAttribution))
        attribution.toolTip = "Shows cross-agent project totals and top sessions."

        let themeMenu = submenu("Theme")
        for theme in PanelTheme.allCases {
            if theme == .catppuccinMocha {
                themeMenu.addItem(.sectionHeader(title: "Dark"))
            } else if theme == .catppuccinLatte {
                themeMenu.addItem(.separator())
                themeMenu.addItem(.sectionHeader(title: "Light"))
            }
            let item = NSMenuItem(title: theme.title,
                                  action: #selector(selectPanelTheme(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            item.state = theme == panelTheme ? .on : .off
            item.image = theme.swatchImage
            if theme == .system { item.toolTip = "Follow the macOS appearance." }
            themeMenu.addItem(item)
            if theme == .system { themeMenu.addItem(.separator()) }
        }

        let periodRangeMenu = submenu("Period Range")
        let calendarRange = toggle(in: periodRangeMenu, "Calendar",
                                   periodRangeStyle == .calendar, #selector(useCalendarRange))
        calendarRange.toolTip = "This week, this month, and this year."
        let relativeRange = toggle(in: periodRangeMenu, "Relative",
                                   periodRangeStyle == .relative, #selector(useRelativeRange))
        relativeRange.toolTip = "Last 7 days, last 30 days, and last 12 months."

        menu.addItem(.separator())
        // Disabled version label helps identify the running build.
        let version = NSMenuItem(title: "Token Bar v\(appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    // View toggles only change presentation, so rebuild synchronously from the
    // latest scan. Waiting for another disk scan allowed the old panel to open
    // first and then visibly resize when that scan completed.
    func applyViewChange(_ key: String, _ value: Bool) {
        appDefaults.set(value, forKey: key)
        panelSignature = ""
        if let data = latestPanelData, data.period == period,
           data.rangeStyle == periodRangeStyle {
            rebuildPanel(total: data.total, sources: data.sources)
        } else {
            refresh()
        }
    }

    @objc func selectPanelTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selectedTheme = PanelTheme(rawValue: rawValue),
              selectedTheme != panelTheme
        else { return }
        panelTheme = selectedTheme
        appDefaults.set(selectedTheme.rawValue, forKey: "theme")
        panelPopover.appearance = selectedTheme.chromeAppearance
        panelContentView?.appearance = selectedTheme.chromeAppearance
        panelContentView?.theme = selectedTheme
        panelView?.appearance = selectedTheme.chromeAppearance
        panelView?.theme = selectedTheme
        panelSignature = ""
        if let data = latestPanelData, data.period == period,
           data.rangeStyle == periodRangeStyle {
            rebuildPanel(total: data.total, sources: data.sources)
        } else {
            refresh()
        }
    }

    func toggleMenuBarField(_ field: MenuBarFields) {
        if menuBarFields.contains(field) {
            guard menuBarFields.rawValue.nonzeroBitCount > 1 else { return }
            menuBarFields.remove(field)
        } else {
            menuBarFields.insert(field)
        }
        appDefaults.set(menuBarFields.rawValue, forKey: MenuBarFields.defaultsKey)
        setBarTitle(displayed)
    }

    @objc func toggleMenuBarSpend() { toggleMenuBarField(.spend) }
    @objc func toggleMenuBarInputTokens() { toggleMenuBarField(.inputTokens) }
    @objc func toggleMenuBarOutputTokens() { toggleMenuBarField(.outputTokens) }
    @objc func toggleMenuBarCacheHitRate() { toggleMenuBarField(.cacheHitRate) }

    func setPeriodRangeStyle(_ rangeStyle: PeriodRangeStyle) {
        guard periodRangeStyle != rangeStyle else { return }
        periodRangeStyle = rangeStyle
        appDefaults.set(rangeStyle.rawValue, forKey: "periodRangeStyle")
        refresh()
    }

    @objc func useCalendarRange() { setPeriodRangeStyle(.calendar) }
    @objc func useRelativeRange() { setPeriodRangeStyle(.relative) }

    @objc func toggleGraph() { showGraph.toggle(); applyViewChange("showGraph", showGraph) }
    @objc func toggleExperimentalCat() {
        showExperimentalCat.toggle()
        applyViewChange("showExperimentalCat", showExperimentalCat)
    }
    @objc func toggleExperimentalAttribution() {
        showExperimentalAttribution.toggle()
        applyViewChange("showExperimentalAttribution", showExperimentalAttribution)
    }
    @objc func toggleProviderIcons() { showProviderIcons.toggle(); applyViewChange("showProviderIcons", showProviderIcons) }
    @objc func toggleFullModelNames() { showFullModelNames.toggle(); applyViewChange("showFullModelNames", showFullModelNames) }

    // Render only the stats card—not the desktop, menu bar, or Quit item—onto
    // an opaque background and place a Retina PNG on the clipboard.
    func panelSnapshot() -> NSBitmapImageRep? {
        guard let panel = panelView else { return nil }
        resizePanel()
        panel.layoutSubtreeIfNeeded()
        let size = panel.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = max(2, panel.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // Keep the capture action available in the live panel without baking
        // that control into the exported image. Alpha preserves its layout.
        let screenshotButtonAlpha = screenshotButton?.alphaValue
        screenshotButton?.alphaValue = 0
        panel.usesSnapshotStyle = true
        defer {
            panel.usesSnapshotStyle = false
            if let alpha = screenshotButtonAlpha { screenshotButton?.alphaValue = alpha }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            panelTheme.palette.background.setFill()
            NSBezierPath(roundedRect: panel.bounds, xRadius: 12, yRadius: 12).fill()
            panel.displayIgnoringOpacity(panel.bounds, in: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @objc func copyPanelScreenshot() {
        guard let rep = panelSnapshot(),
              let png = rep.representation(using: .png, properties: [:])
        else { NSSound.beep(); return }
        // Put both representations on the clipboard: image data pastes into
        // editors and chats, while the file URL lets Finder paste an actual
        // .png file. The temporary source remains available until macOS cleans
        // its temp directory.
        let snapshotsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Token Bar Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapshotsDirectory,
                                                 withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "Token Bar \(formatter.string(from: Date())).png"
        let fileURL = snapshotsDirectory.appendingPathComponent(filename)
        let wroteFile = (try? png.write(to: fileURL, options: .atomic)) != nil

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if wroteFile { pasteboard.writeObjects([fileURL as NSURL]) }
        pasteboard.setData(png, forType: .png)

        // Brief in-place confirmation; the panel can remain open.
        if let button = screenshotButton {
            button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
            _ = commonModesTimer(interval: 1, repeats: false) { [weak button] in
                button?.image = NSImage(systemSymbolName: "camera",
                                        accessibilityDescription: "Copy Panel Screenshot")
            }
        }
    }

    @objc func quitClicked() { NSApp.terminate(nil) }

    @objc func periodClicked(_ sender: NSButton) {
        guard let p = Period(rawValue: sender.tag), p != period else { return }
        period = p
        appDefaults.set(p.rawValue, forKey: "period")
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
        let rangeStyle = periodRangeStyle
        let periodStart = period.start(cal: cal, now: now, rangeStyle: rangeStyle)
        let spec = period.bucketSpec(start: periodStart, cal: cal, now: now,
                                     rangeStyle: rangeStyle)

        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let sources = self.scanAll(since: periodStart, buckets: spec)
            var total = Agg()
            for s in sources { total.add(s.agg) }
            self.performOnMain {
                // A period or range style can change while its previous scan
                // is in flight. Never render stale rows under the new selection.
                if period == self.period, rangeStyle == self.periodRangeStyle {
                    self.latestPanelData = (period, rangeStyle, total, sources)
                    self.animateBar(to: BarValues(cost: total.cost, input: total.input,
                                                  output: total.output, hit: total.hitRate))
                    self.rebuildPanel(total: total, sources: sources)
                }
                self.scanning = false
                if self.scanPending {
                    self.scanPending = false
                    self.refresh()
                }
            }
        }
    }

    func setBarTitle(_ v: BarValues) {
        var sections: [String] = []
        if menuBarFields.contains(.spend) { sections.append(fmtMoney(v.cost)) }
        var tokens: [String] = []
        if menuBarFields.contains(.inputTokens) { tokens.append("\(fmtTokens(v.input))↑") }
        if menuBarFields.contains(.outputTokens) { tokens.append("\(fmtTokens(v.output))↓") }
        if !tokens.isEmpty { sections.append(tokens.joined(separator: " ")) }
        if menuBarFields.contains(.cacheHitRate) {
            sections.append(String(format: "%.0f%%", v.hit * 100))
        }
        // Loading and menu actions enforce this invariant; retain a defensive
        // fallback so the status item remains discoverable if state is changed elsewhere.
        let text = sections.isEmpty ? fmtMoney(v.cost) : sections.joined(separator: "  ")
        // Monospaced digits keep the title from wobbling while values roll
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
    }

    // Roll the bar through intermediate values (ease-out, ~0.8s)
    func animateBar(to target: BarValues) {
        if panelIsOpen {
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

    struct AttributedSession {
        let source: String
        let stats: SessionStats
        var key: String { "\(source)/\(stats.id)" }
    }

    struct AttributedProject {
        let key: String
        let path: String?
        var agg: Agg
        var sessionCount: Int
        var lastActivity: Date
    }

    struct AttributionData {
        let projects: [AttributedProject]
        let sessions: [AttributedSession]
    }

    func attributionData(_ sources: [SourceStats]) -> AttributionData {
        let sessions = sources.flatMap { source in
            source.sessions.values.compactMap { session -> AttributedSession? in
                let usage = session.agg
                guard usage.cost > 0 || usage.contextTotal > 0 || usage.output > 0 else { return nil }
                return AttributedSession(source: source.name, stats: session)
            }
        }
        var byProject: [String: AttributedProject] = [:]
        for session in sessions {
            let path = session.stats.projectPath
            let key = path ?? "\u{0}unknown-project"
            if var project = byProject[key] {
                project.agg.add(session.stats.agg)
                project.sessionCount += 1
                project.lastActivity = max(project.lastActivity, session.stats.lastActivity)
                byProject[key] = project
            } else {
                byProject[key] = AttributedProject(key: key, path: path,
                                                   agg: session.stats.agg, sessionCount: 1,
                                                   lastActivity: session.stats.lastActivity)
            }
        }
        func usageComesFirst(_ lhs: Agg, _ rhs: Agg) -> Bool {
            if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
            return lhs.contextTotal + lhs.output > rhs.contextTotal + rhs.output
        }
        let projects = byProject.values.sorted {
            if $0.agg != $1.agg { return usageComesFirst($0.agg, $1.agg) }
            return $0.lastActivity > $1.lastActivity
        }
        let rankedSessions = sessions.sorted {
            if $0.stats.agg != $1.stats.agg {
                return usageComesFirst($0.stats.agg, $1.stats.agg)
            }
            return $0.stats.lastActivity > $1.stats.lastActivity
        }
        return AttributionData(projects: projects, sessions: rankedSessions)
    }

    func projectName(_ path: String?) -> String {
        guard let path else { return "Unknown Project" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    func sessionName(_ session: AttributedSession) -> String {
        if let title = session.stats.title {
            return title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let project = projectName(session.stats.projectPath)
        let shortProject = project.count > 18 ? String(project.prefix(17)) + "…" : project
        let id = session.stats.id
        let shortID = id.count > 8 ? String(id.prefix(8)) : id
        return "\(shortProject) · \(shortID)"
    }

    func sessionDetail(_ session: AttributedSession) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(session.stats.lastActivity) {
            formatter.timeStyle = .short
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        }
        return "\(session.source) · \(formatter.string(from: session.stats.lastActivity))"
    }

    @objc func openAttributedProject(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func sessionInvocation(_ target: SessionLaunchTarget) -> (executable: String, arguments: [String])? {
        switch target.source.lowercased() {
        case "claude code":
            return ("claude", ["--resume", target.id])
        case "codex":
            return ("codex", ["resume", "--include-non-interactive", target.id])
        case "opencode":
            return ("opencode", ["--session", target.id])
        case "pi":
            return ("pi", ["--session", target.id])
        default:
            return nil
        }
    }

    @objc func resumeAttributedSession(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let target = sessionLaunchTargets[key],
              let invocation = sessionInvocation(target)
        else { NSSound.beep(); return }

        var isDirectory: ObjCBool = false
        let projectExists = target.projectPath.map {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        } ?? false
        let workingDirectory = projectExists
            ? target.projectPath! : FileManager.default.homeDirectoryForCurrentUser.path
        let command = ([invocation.executable] + invocation.arguments)
            .map(shellQuote).joined(separator: " ")
        let missingMessage = "Token Bar could not find '\(invocation.executable)' in your shell PATH."
        let script = """
        #!/bin/zsh
        for profile in "$HOME/.zprofile" "$HOME/.zshrc"; do
          [[ -r "$profile" ]] && source "$profile" >/dev/null 2>&1 || true
        done
        export PATH="$HOME/.local/bin:$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd -- \(shellQuote(workingDirectory))
        if ! command -v \(shellQuote(invocation.executable)) >/dev/null 2>&1; then
          print -r -- \(shellQuote(missingMessage))
          printf '\nPress Return to close.'
          read -r
          exit 127
        fi
        exec \(command)
        """

        let fm = FileManager.default
        let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let directory = cacheRoot.appendingPathComponent("Token Bar/Session Launchers",
                                                         isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let oldLaunchers = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
                let cutoff = Date().addingTimeInterval(-86_400)
                for url in oldLaunchers {
                    let modified = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]).contentModificationDate
                    if modified.map({ $0 < cutoff }) ?? true { try? fm.removeItem(at: url) }
                }
            }
            let launcher = directory.appendingPathComponent(
                "Resume-\(UUID().uuidString).command", isDirectory: false)
            try Data(script.utf8).write(to: launcher, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
            guard NSWorkspace.shared.open(launcher) else { throw CocoaError(.fileNoSuchFile) }
        } catch {
            NSSound.beep()
        }
    }

    // Rebuild the panel only when its row structure changes (a new model or
    // source); otherwise update fields and period controls in place: no flicker.
    func rebuildPanel(total: Agg, sources: [SourceStats]) {
        ensurePanelSkeleton()
        let active = activeSources(sources)
        // Structure and presentation—not live ordering or period—determine
        // whether the panel needs rebuilding. Recreating every view on a period
        // switch caused a visible flash and let the popover recalculate its position.
        let sourceSignature = active
            .map { "\($0.name):\($0.perModel.keys.sorted().joined(separator: ","))" }
            .sorted()
            .joined(separator: "|")
        let attributionSignature: String
        if showExperimentalAttribution {
            let attribution = attributionData(active)
            let metadata = active.flatMap { source in
                source.sessions.values.map {
                    "\(source.name):\($0.id):\($0.projectPath ?? ""):\($0.title ?? "")"
                }
            }.sorted().joined(separator: "|")
            // Unlike the model table, these rows explicitly promise a ranking;
            // rebuild if the top entries change, then update their values in place.
            let projectOrder = attribution.projects.prefix(4).map(\.key).joined(separator: "|")
            let sessionOrder = attribution.sessions.prefix(4).map(\.key).joined(separator: "|")
            attributionSignature = "\(metadata);projects:\(projectOrder);sessions:\(sessionOrder)"
        } else {
            attributionSignature = ""
        }
        let signature = [panelTheme.rawValue,
                         "graph:\(showGraph)",
                         "icons:\(showProviderIcons)",
                         "names:\(showFullModelNames)",
                         "cat:\(showExperimentalCat)",
                         "attribution:\(showExperimentalAttribution)",
                         sourceSignature,
                         attributionSignature]
            .joined(separator: "|")
        if signature == panelSignature && !statFields.isEmpty {
            updateFields(total: total, active: active)
        } else {
            buildPanelContent(total: total, active: active)
            panelSignature = signature
        }
    }

    func setField(_ key: String, _ value: String) {
        guard let f = statFields[key], f.stringValue != value else { return }
        f.stringValue = value
    }

    // Panel width is sticky: it grows to fit the widest content seen but never
    // shrinks back, so changing values cannot move the popover's anchored edge.
    // The insets are already included in NSStackView.fittingSize; adding them on
    // every refresh made the panel grow a little each time.
    var stickyWidth: CGFloat = 360
    // Width needed by the current table with full names and icons enabled.
    // Reserving this up front keeps view toggles from resizing the popover.
    var minimumContentWidth: CGFloat = 0

    func maximumPanelHeight() -> CGFloat {
        guard let button = statusItem?.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main
        else { return 640 }
        let windowRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let availableBelow = screenRect.minY - screen.visibleFrame.minY - 12
        return max(220, min(720, floor(availableBelow)))
    }

    func resizePanel() {
        guard let panel = panelView else { return }
        panel.layoutSubtreeIfNeeded()
        let fitting = panel.fittingSize
        // Measure the content explicitly so the table gets the same trailing
        // inset as the header and graph.
        let measuredWidth = panel.arrangedSubviews.map { $0.fittingSize.width }.max() ?? 0
        let contentWidth = max(measuredWidth, minimumContentWidth)
        let insetWidth = panel.edgeInsets.left + panel.edgeInsets.right
        stickyWidth = max(stickyWidth, ceil(contentWidth + insetWidth))
        let panelSize = NSSize(width: stickyWidth, height: ceil(fitting.height))
        if panelSize != panel.frame.size { panel.setFrameSize(panelSize) }

        // Full-size content paints the native chevron, while the safe area keeps
        // controls out of the chevron and rounded corners. Include those insets
        // in the outer size so they do not clip or silently shorten the panel.
        let safeInsets = panelContentView?.safeAreaInsets ?? NSEdgeInsets()
        let horizontalChrome = safeInsets.left + safeInsets.right
        let verticalChrome = safeInsets.top + safeInsets.bottom
        let visiblePanelHeight = min(panelSize.height,
                                     max(1, maximumPanelHeight() - verticalChrome))
        panelScrollView?.hasVerticalScroller = panelSize.height > visiblePanelHeight + 0.5
        let popoverSize = NSSize(width: panelSize.width + horizontalChrome,
                                 height: visiblePanelHeight + verticalChrome)
        if panelPopover.contentViewController?.preferredContentSize != popoverSize {
            panelPopover.contentViewController?.preferredContentSize = popoverSize
        }
        if panelPopover.contentSize != popoverSize {
            panelPopover.contentSize = popoverSize
        }
    }

    func updatePeriodControls() {
        periodField?.stringValue = period.title(rangeStyle: periodRangeStyle)
        let colors = panelTheme.palette
        for button in periodButtons {
            guard let buttonPeriod = Period(rawValue: button.tag) else { continue }
            let title = buttonPeriod.title(rangeStyle: periodRangeStyle)
            button.toolTip = "Show \(title)"
            button.setAccessibilityLabel("Show \(title)")
            button.attributedTitle = NSAttributedString(
                string: buttonPeriod.letter,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11,
                                             weight: buttonPeriod == period ? .semibold : .regular),
                    .foregroundColor: buttonPeriod == period
                        ? panelTheme.selectionColor : colors.muted,
                ])
        }
    }

    func updateFields(total: Agg, active: [SourceStats]) {
        setField("Spend", fmtMoney(total.cost))
        setField("Tokens", tokensLine(total))
        updatePeriodControls()
        for s in active { setField("\(s.name)/Header", headerTitle(for: s)) }
        sparkView?.values = totalBuckets(active)
        sparkView?.caption = period.caption
        sparkView?.axis = period.axis(cal: Calendar.current, now: Date(),
                                      rangeStyle: periodRangeStyle)
        for s in active {
            for (model, a) in s.perModel {
                let marker = s.unknownPricing.contains(model) ? "~" : ""
                setField("\(s.name)/\(model)/Spend", marker + fmtMoney(a.cost))
                setField("\(s.name)/\(model)/Input", fmtTokens(a.input))
                setField("\(s.name)/\(model)/Output", fmtTokens(a.output))
                setField("\(s.name)/\(model)/Hit", String(format: "%.0f%%", a.hitRate * 100))
            }
        }
        if showExperimentalAttribution {
            let attribution = attributionData(active)
            for project in attribution.projects {
                let prefix = "Attribution/Project/\(project.key)"
                setField("\(prefix)/Spend", fmtMoney(project.agg.cost))
                setField("\(prefix)/Tokens",
                         fmtTokens(project.agg.contextTotal + project.agg.output))
                setField("\(prefix)/Sessions", "\(project.sessionCount)")
            }
            for session in attribution.sessions {
                let prefix = "Attribution/Session/\(session.key)"
                setField("\(prefix)/Detail", sessionDetail(session))
                setField("\(prefix)/Spend", fmtMoney(session.stats.agg.cost))
                setField("\(prefix)/Tokens",
                         fmtTokens(session.stats.agg.contextTotal + session.stats.agg.output))
            }
        }
        resizePanel()  // in case a value grew wider than the panel was sized for
    }

    // The panel and scroll container are created once; rows are rebuilt in
    // place so the popover can stay open. Tall dashboards scroll rather than
    // extending beyond the current screen's visible frame.
    func ensurePanelSkeleton() {
        panelPopover.appearance = panelTheme.chromeAppearance
        guard panelView == nil else { return }

        let panel = ThemedPanelView()
        panel.theme = panelTheme
        panel.appearance = panelTheme.chromeAppearance
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 0
        panel.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        panelView = panel

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .automatic
        scrollView.documentView = panel
        panelScrollView = scrollView

        let contentView = ThemedPopoverContentView()
        contentView.theme = panelTheme
        contentView.appearance = panelTheme.chromeAppearance
        contentView.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor),
        ])
        panelContentView = contentView

        let controller = NSViewController()
        controller.view = contentView
        panelPopover.contentViewController = controller
    }

    func buildPanelContent(total: Agg, active: [SourceStats]) {
        guard let panel = panelView else { return }
        panel.theme = panelTheme
        let colors = panelTheme.palette
        if let sparkView { savedCatMotionState = sparkView.motionState() }
        for v in panel.arrangedSubviews {
            panel.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        statFields.removeAll()
        sessionLaunchTargets.removeAll()
        periodField = nil
        periodButtons.removeAll()
        screenshotButton = nil
        minimumContentWidth = 0

        func label(_ key: String?, _ text: String, size: CGFloat,
                   weight: NSFont.Weight = .regular, color: NSColor? = nil,
                   mono: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
            f.textColor = color ?? colors.primary
            f.alignment = align
            if align == .right {
                // Keep metric columns compact. Any width reserved for full
                // model names belongs to the first column, not a numeric cell.
                f.setContentHuggingPriority(.required, for: .horizontal)
                f.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            if let key = key { statFields[key] = f }
            return f
        }

        func modelLabel(provider: String, name: String) -> NSView {
            let nameLabel = label(nil, name, size: 12)
            nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            guard showProviderIcons else { return nameLabel }
            let row = NSStackView(views: [ProviderBadgeView(provider: provider, theme: panelTheme),
                                          nameLabel])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 5
            return row
        }

        // Header: big spend + period word, with the D W M Y switcher on the right
        let spend = label("Spend", fmtMoney(total.cost), size: 24, weight: .semibold, mono: true)
        let periodLabel = label(nil, period.title(rangeStyle: periodRangeStyle), size: 12,
                                color: colors.secondary)
        periodField = periodLabel

        let switcher = NSStackView()
        switcher.orientation = .horizontal
        // Use contiguous 24-point targets while preserving the compact letter
        // spacing. The former intrinsic-size buttons left dead gaps around each
        // glyph, making clicks hard to acquire.
        switcher.spacing = 0
        for p in Period.allCases {
            let b = NSButton(title: p.letter, target: self,
                             action: #selector(periodClicked(_:)))
            b.isBordered = false
            b.tag = p.rawValue
            let title = p.title(rangeStyle: periodRangeStyle)
            b.toolTip = "Show \(title)"
            b.setAccessibilityLabel("Show \(title)")
            b.attributedTitle = NSAttributedString(
                string: p.letter,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: p == period ? .semibold : .regular),
                    .foregroundColor: p == period ? panelTheme.selectionColor : colors.muted,
                ])
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            switcher.addArrangedSubview(b)
            periodButtons.append(b)
        }

        let capture = NSButton(
            image: NSImage(systemSymbolName: "camera",
                           accessibilityDescription: "Copy Panel Screenshot")!,
            target: self, action: #selector(copyPanelScreenshot))
        capture.isBordered = false
        capture.controlSize = .small
        capture.contentTintColor = colors.muted
        capture.toolTip = "Copy Panel Screenshot"
        capture.setAccessibilityLabel("Copy Panel Screenshot")
        screenshotButton = capture

        let flexSpacer = NSView()
        flexSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        // Keep the period switcher against the trailing edge; the capture
        // action lives with the title controls on the left.
        let headerRow = NSStackView(views: [spend, periodLabel, capture, flexSpacer, switcher])
        headerRow.orientation = .horizontal
        headerRow.alignment = .lastBaseline
        headerRow.spacing = 6
        panel.addArrangedSubview(headerRow)
        // Stretch the header across the panel so the switcher sits at the right edge
        headerRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14).isActive = true
        headerRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14).isActive = true
        panel.setCustomSpacing(2, after: headerRow)

        panel.addArrangedSubview(label("Tokens", tokensLine(total), size: 12,
                                       color: colors.secondary, mono: true))

        sparkView = nil
        if active.isEmpty {
            let isLoading = latestPanelData == nil
            panel.setCustomSpacing(16, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(label(nil,
                                          isLoading ? "Loading usage…" : "No usage yet for this period",
                                          size: 13, weight: .medium))
            panel.setCustomSpacing(3, after: panel.arrangedSubviews.last!)
            let emptyMessage = label(
                nil,
                isLoading
                    ? "Scanning local Claude Code, Codex,\nOpenCode, and pi history."
                    : "Token Bar will populate as you use\nClaude Code, Codex, OpenCode, or Pi.",
                size: 12, color: colors.secondary)
            emptyMessage.maximumNumberOfLines = 2
            emptyMessage.lineBreakMode = .byWordWrapping
            panel.addArrangedSubview(emptyMessage)
            emptyMessage.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14).isActive = true
            emptyMessage.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14).isActive = true
            resizePanel()
            if panelIsOpen { scrollPanelToTop() }
            return
        }

        // Spend timeline for the period
        if showGraph {
            let cal = Calendar.current
            let spark = SparkBarView()
            spark.values = totalBuckets(active)
            spark.caption = period.caption
            spark.theme = panelTheme
            spark.axis = period.axis(cal: cal, now: Date(), rangeStyle: periodRangeStyle)
            spark.catEnabled = showExperimentalCat
            if let savedCatMotionState { spark.restoreMotionState(savedCatMotionState) }
            spark.catAnimating = showExperimentalCat && panelIsOpen
            sparkView = spark
            panel.setCustomSpacing(10, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(spark)
            spark.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spark.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14).isActive = true
            spark.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14).isActive = true
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
                    label(nil, t, size: 10, color: colors.muted, align: .right)
                }
                rows.append([label("\(s.name)/Header", headerTitle(for: s), size: 10, weight: .medium,
                                   color: colors.muted),
                             caption("spend"), caption("in"), caption("out"), caption("hit")])
                for (model, a) in s.perModel.sorted(by: { $0.value.cost > $1.value.cost }) {
                    let marker = s.unknownPricing.contains(model) ? "~" : ""
                    let displayName = showFullModelNames ? model : shortModel(model)
                    rows.append([
                        modelLabel(provider: provider(for: s, model: model), name: displayName),
                        label("\(s.name)/\(model)/Spend", marker + fmtMoney(a.cost), size: 12,
                              color: colors.secondary, mono: true, align: .right),
                        label("\(s.name)/\(model)/Input", fmtTokens(a.input), size: 12,
                              color: colors.secondary, mono: true, align: .right),
                        label("\(s.name)/\(model)/Output", fmtTokens(a.output), size: 12,
                              color: colors.secondary, mono: true, align: .right),
                        label("\(s.name)/\(model)/Hit", String(format: "%.0f%%", a.hitRate * 100), size: 12,
                              color: colors.secondary, mono: true, align: .right),
                    ])
                }
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 4
            grid.columnSpacing = 12
            for col in 1..<5 { grid.column(at: col).xPlacement = .trailing }
            // A header binds to the rows below it: generous space above,
            // a small fixed gap below, uniform row spacing within a section.
            for i in headerRowIndices {
                grid.row(at: i).topPadding = i == 0 ? 0 : 12
                grid.row(at: i).bottomPadding = 2
            }

            // Size from the unconstrained grid, then reserve the difference
            // between the displayed first column and its widest possible state.
            // Otherwise Auto Layout discovers the full-name width over several
            // passes and the popover visibly jumps before settling.
            let headerWidth = headerRowIndices.map {
                rows[$0][0].fittingSize.width
            }.max() ?? 0
            let models = active.flatMap { $0.perModel.keys }
            func fullModelLabelWidth(_ name: String) -> CGFloat {
                let nameLabel = label(nil, name, size: 12)
                let row = NSStackView(views: [ProviderBadgeView(provider: "", theme: panelTheme),
                                              nameLabel])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 5
                return row.fittingSize.width
            }
            let fullModelWidth = models.map(fullModelLabelWidth).max() ?? 0
            let stableFirstColumn = ceil(max(headerWidth, fullModelWidth))
            for row in rows {
                row[0].widthAnchor.constraint(equalToConstant: stableFirstColumn).isActive = true
            }
            // Giving the first column its final width before measuring leaves
            // no surplus for NSGridView to assign to a metric column.
            minimumContentWidth = ceil(grid.fittingSize.width)

            panel.setCustomSpacing(showGraph ? 16 : 14, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(grid)
            grid.setContentHuggingPriority(.defaultLow, for: .horizontal)
            grid.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14).isActive = true
            grid.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14).isActive = true
        }

        if showExperimentalAttribution {
            let attribution = attributionData(active)
            let projectLimit = 4
            let sessionLimit = 4

            func clipped(_ text: String, limit: Int = 30) -> String {
                text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
            }
            func attributionCaption(_ text: String) -> NSTextField {
                label(nil, text, size: 10, color: colors.muted, align: .right)
            }
            func emptyCell() -> NSTextField { label(nil, "", size: 10) }
            func flexibleCell() -> NSView {
                let view = NSView()
                view.setContentHuggingPriority(.init(1), for: .horizontal)
                view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                return view
            }
            func metricWidth(caption: String, sample: String) -> CGFloat {
                let captionWidth = attributionCaption(caption).fittingSize.width
                let valueWidth = label(nil, sample, size: 12, color: colors.secondary,
                                       mono: true, align: .right).fittingSize.width
                return ceil(max(captionWidth, valueWidth))
            }
            // Fixed left/metric columns plus one flexible middle column make
            // the visual split deterministic: labels stay at the leading edge,
            // metrics stay at the trailing edge, and only the empty gap grows.
            let projectLabelWidth: CGFloat = 180
            let sessionInfoWidth: CGFloat = 225
            let spendWidth = metricWidth(caption: "spend", sample: "$999999.99")
            let tokensWidth = metricWidth(caption: "tokens", sample: "9999.9M")
            let sessionsWidth = metricWidth(caption: "sessions", sample: "9999")

            func folderLink(title: String, path: String?,
                            truncation: NSLineBreakMode) -> NSButton {
                let pathExists = path.map {
                    FileManager.default.fileExists(atPath: $0)
                } ?? false
                let button = NSButton(
                    title: title,
                    target: pathExists ? self : nil,
                    action: pathExists ? #selector(openAttributedProject(_:)) : nil)
                if pathExists, let path {
                    button.identifier = NSUserInterfaceItemIdentifier(path)
                }
                button.isBordered = false
                button.isEnabled = pathExists
                button.alignment = .left
                let symbol: String
                if pathExists {
                    symbol = "folder"
                } else if path != nil {
                    symbol = "folder.badge.minus"
                } else {
                    symbol = "questionmark.folder"
                }
                button.image = NSImage(systemSymbolName: symbol,
                                       accessibilityDescription: pathExists
                                           ? "Open Project" : "Folder Unavailable")
                button.imagePosition = .imageLeading
                button.contentTintColor = colors.muted
                button.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.font: NSFont.systemFont(ofSize: 12),
                                 .foregroundColor: pathExists ? colors.primary : colors.secondary])
                if let path {
                    button.toolTip = pathExists ? "Open \(path)" : "Folder no longer exists: \(path)"
                } else {
                    button.toolTip = "No working directory metadata was recorded."
                }
                button.setAccessibilityLabel(pathExists
                    ? "Open project folder for \(title)" : "\(title), folder unavailable")
                button.lineBreakMode = truncation
                button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return button
            }

            func projectCell(_ project: AttributedProject) -> NSView {
                folderLink(title: clipped(projectName(project.path)), path: project.path,
                           truncation: .byTruncatingTail)
            }

            func sessionFolderLink(_ session: AttributedSession) -> NSButton {
                let button = folderLink(title: "", path: session.stats.projectPath,
                                        truncation: .byClipping)
                button.imagePosition = .imageOnly
                button.setAccessibilityLabel("Project folder for session \(session.stats.id)")
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                button.widthAnchor.constraint(equalToConstant: 16).isActive = true
                return button
            }

            func sessionLink(_ session: AttributedSession) -> NSButton {
                let rawName = sessionName(session)
                let title = clipped(rawName)
                let button = NSButton(title: title, target: self,
                                      action: #selector(resumeAttributedSession(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(session.key)
                sessionLaunchTargets[session.key] = SessionLaunchTarget(
                    source: session.source, id: session.stats.id,
                    projectPath: session.stats.projectPath)
                button.isBordered = false
                button.alignment = .left
                button.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.font: NSFont.systemFont(ofSize: 12),
                                 .foregroundColor: colors.primary])
                button.toolTip = "Resume in \(session.source)\nSession: \(session.stats.id)"
                button.setAccessibilityLabel("Resume \(session.source) session \(rawName)")
                button.lineBreakMode = .byTruncatingMiddle
                button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return button
            }

            var projectRows: [[NSView]] = [[
                label(nil, "PROJECTS · \(attribution.projects.count)", size: 10,
                      weight: .medium, color: colors.muted),
                flexibleCell(),
                attributionCaption("spend"),
                attributionCaption("tokens"),
                attributionCaption("sessions"),
            ]]
            for project in attribution.projects.prefix(projectLimit) {
                let prefix = "Attribution/Project/\(project.key)"
                projectRows.append([
                    projectCell(project),
                    flexibleCell(),
                    label("\(prefix)/Spend", fmtMoney(project.agg.cost), size: 12,
                          color: colors.secondary, mono: true, align: .right),
                    label("\(prefix)/Tokens",
                          fmtTokens(project.agg.contextTotal + project.agg.output), size: 12,
                          color: colors.secondary, mono: true, align: .right),
                    label("\(prefix)/Sessions", "\(project.sessionCount)", size: 12,
                          color: colors.secondary, mono: true, align: .right),
                ])
            }
            if attribution.projects.isEmpty {
                projectRows.append([label(nil, "No project metadata found", size: 12,
                                          color: colors.secondary),
                                    flexibleCell(), emptyCell(), emptyCell(), emptyCell()])
            }
            let projectGrid = NSGridView(views: projectRows)
            projectGrid.rowSpacing = 4
            projectGrid.columnSpacing = 12
            projectGrid.column(at: 0).width = projectLabelWidth
            projectGrid.column(at: 0).xPlacement = .fill
            projectGrid.column(at: 1).xPlacement = .fill
            projectGrid.column(at: 2).width = spendWidth
            projectGrid.column(at: 3).width = tokensWidth
            projectGrid.column(at: 4).width = sessionsWidth
            for column in 2..<5 { projectGrid.column(at: column).xPlacement = .trailing }
            projectGrid.row(at: 0).bottomPadding = 2

            var sessionRows: [[NSView]] = [[
                label(nil, "TOP SESSIONS · \(attribution.sessions.count)", size: 10,
                      weight: .medium, color: colors.muted),
                flexibleCell(), attributionCaption("spend"), attributionCaption("tokens"),
            ]]
            for session in attribution.sessions.prefix(sessionLimit) {
                let folder = sessionFolderLink(session)
                let name = sessionLink(session)
                let prefix = "Attribution/Session/\(session.key)"
                let detail = label("\(prefix)/Detail", sessionDetail(session), size: 11,
                                   color: colors.muted)
                detail.setContentHuggingPriority(.required, for: .horizontal)
                detail.setContentCompressionResistancePriority(.required, for: .horizontal)
                let info = NSStackView(views: [folder, name, detail])
                info.orientation = .horizontal
                info.alignment = .centerY
                info.spacing = 4
                info.setCustomSpacing(8, after: name)
                info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                sessionRows.append([
                    info,
                    flexibleCell(),
                    label("\(prefix)/Spend", fmtMoney(session.stats.agg.cost), size: 12,
                          color: colors.secondary, mono: true, align: .right),
                    label("\(prefix)/Tokens",
                          fmtTokens(session.stats.agg.contextTotal + session.stats.agg.output),
                          size: 12, color: colors.secondary, mono: true, align: .right),
                ])
            }
            if attribution.sessions.isEmpty {
                sessionRows.append([label(nil, "No attributed sessions", size: 12,
                                          color: colors.secondary),
                                    flexibleCell(), emptyCell(), emptyCell()])
            }
            let sessionGrid = NSGridView(views: sessionRows)
            sessionGrid.rowSpacing = 4
            sessionGrid.columnSpacing = 12
            sessionGrid.column(at: 0).width = sessionInfoWidth
            sessionGrid.column(at: 0).xPlacement = .fill
            sessionGrid.column(at: 1).xPlacement = .fill
            sessionGrid.column(at: 2).width = spendWidth
            sessionGrid.column(at: 3).width = tokensWidth
            for column in 2..<4 { sessionGrid.column(at: column).xPlacement = .trailing }
            sessionGrid.row(at: 0).bottomPadding = 2

            // Both grids are deliberately the same stable minimum width. Their
            // flexible blank columns absorb wider model tables without moving
            // either the leading labels or trailing metrics.
            minimumContentWidth = max(minimumContentWidth, 400)
            panel.setCustomSpacing(18, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(projectGrid)
            projectGrid.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14).isActive = true
            projectGrid.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14).isActive = true
            panel.setCustomSpacing(12, after: projectGrid)
            panel.addArrangedSubview(sessionGrid)
            sessionGrid.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14).isActive = true
            sessionGrid.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14).isActive = true
        }

        resizePanel()
        if panelIsOpen { scrollPanelToTop() }
    }
}

#if DEBUG
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
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
