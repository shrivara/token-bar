// token-bar: menu bar readout of today's AI usage (Claude Code, Codex, OpenCode, pi).
// Aggregation logic lives in TokenBarCore; this file is the AppKit shell.

import AppKit
import CoreServices
import TokenBarCore

// Shown in the right-click menu for debugging which build is running. The .app
// reports its Info.plist version; the raw CLI/Homebrew binary has no Info.plist,
// so fall back to this constant (bump it alongside build.sh on release).
let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.8.24"

// Use the bundle identifier for preferences even when Homebrew launches the
// raw executable (which otherwise writes to token-bar.plist). Preserve settings
// from existing formula installs on first use of each key.
let appDefaults: UserDefaults = {
    let canonical = UserDefaults(suiteName: "com.shrivara.tokenbar") ?? .standard
    let legacy = UserDefaults(suiteName: "token-bar")
    for key in ["period", "periodRangeStyle", "showGraph", "showProviderIcons",
                "showFullModelNames", "menuBarFields"]
        where canonical.object(forKey: key) == nil {
        if let value = legacy?.object(forKey: key) {
            canonical.set(value, forKey: key)
        }
    }
    return canonical
}()

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
    var laserVisible = false

    override func draw(_ dirtyRect: NSRect) {
        guard laserVisible, origins.count == endpoints.count else { return }
        for index in origins.indices {
            let beam = NSBezierPath()
            beam.move(to: origins[index])
            beam.line(to: endpoints[index])
            beam.lineCapStyle = .round
            (index < colors.count ? colors[index] : .systemRed)
                .withAlphaComponent(0.78).setStroke()
            beam.lineWidth = 1.5
            beam.stroke()
            NSColor.white.withAlphaComponent(0.92).setStroke()
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
    private var laserWindow: NSWindow?
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
        laserWindow?.orderOut(nil)
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
        let catColor = NSColor.labelColor.withAlphaComponent(0.78)

        if action == .zoom, !reduceMotion {
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
        NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
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
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setStroke()
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
        guard let hostWindow = window, let screen = hostWindow.screen else {
            hideLaserOverlay()
            return
        }
        ensureLaserOverlay(on: screen)
        guard let overlay = laserOverlay else { return }

        let facing: CGFloat = catDirection < 0 ? -1 : 1
        let localEyes = [NSPoint(x: 2.6, y: 5), NSPoint(x: 4.15, y: 4.9)]
        let screenOrigins = localEyes.map { eye -> NSPoint in
            let viewPoint = NSPoint(x: catX + facing * eye.x, y: catY + eye.y)
            let windowPoint = convert(viewPoint, to: nil)
            return hostWindow.convertPoint(toScreen: windowPoint)
        }
        overlay.origins = screenOrigins.map {
            NSPoint(x: $0.x - screen.frame.minX, y: $0.y - screen.frame.minY)
        }

        // Hold each random direction for a few display frames. Every ray is
        // intersected with the display bounds, so it always reaches an edge.
        let flash = Int(floor(now * 12))
        overlay.laserVisible = !flash.isMultiple(of: 4)
        func randomUnit(_ salt: Double) -> CGFloat {
            let value = sin(Double(flash) * 12.9898 + salt * 78.233) * 43_758.5453
            return CGFloat(value - floor(value))
        }
        overlay.endpoints = overlay.origins.enumerated().map { index, origin in
            let angle = randomUnit(Double(index) + 0.7) * .pi * 2
            return rayEndpoint(from: origin, angle: angle, in: overlay.bounds)
        }
        overlay.colors = overlay.origins.map { _ in .systemRed }
        overlay.needsDisplay = true
        if laserWindow?.isVisible != true { laserWindow?.orderFrontRegardless() }
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

    private func ensureLaserOverlay(on screen: NSScreen) {
        if let laserWindow, laserWindow.frame == screen.frame { return }
        laserWindow?.orderOut(nil)
        let overlay = LaserOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = overlay
        laserOverlay = overlay
        laserWindow = panel
    }

    private func hideLaserOverlay() {
        guard laserWindow?.isVisible == true else { return }
        laserOverlay?.laserVisible = false
        laserWindow?.orderOut(nil)
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
    var latestPanelData: (period: Period, rangeStyle: PeriodRangeStyle,
                          total: Agg, sources: [SourceStats])?
    var sparkView: SparkBarView?
    fileprivate var savedCatMotionState: CatMotionState?
    var panelView: NSStackView?
    var periodField: NSTextField?
    var periodButtons: [NSButton] = []
    var screenshotButton: NSButton?
    var period: Period = Period(rawValue: appDefaults.integer(forKey: "period")) ?? .day
    var periodRangeStyle = PeriodRangeStyle(
        rawValue: appDefaults.integer(forKey: "periodRangeStyle")) ?? .calendar

    // Left-click shows this info panel; right-click shows the View menu below.
    let panelMenu = NSMenu()

    // View preferences (right-click menu). object(forKey:) distinguishes an
    // unset default (nil) from an explicit false, so first launch keeps the
    // graph and icons on.
    var showGraph = appDefaults.object(forKey: "showGraph") as? Bool ?? true
    var showProviderIcons = appDefaults.object(forKey: "showProviderIcons") as? Bool ?? true
    var showFullModelNames = appDefaults.bool(forKey: "showFullModelNames")
    var menuBarFields = MenuBarFields.load(from: appDefaults)
    // Experimental and opt-in: an unset preference must never enable animation.
    var showExperimentalCat = appDefaults.object(forKey: "showExperimentalCat") as? Bool ?? false

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
            self.sparkView?.catAnimating = self.showExperimentalCat
            self.refresh()
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: menu, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.menuIsOpen = false
            self.sparkView?.catAnimating = false
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
        menuSignature = ""
        if let data = latestPanelData, data.period == period,
           data.rangeStyle == periodRangeStyle {
            rebuildMenu(total: data.total, sources: data.sources)
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
        defer {
            if let alpha = screenshotButtonAlpha { screenshotButton?.alphaValue = alpha }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
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
                    self.rebuildMenu(total: total, sources: sources)
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

    // Rebuild the panel only when its row structure changes (a new model or
    // source); otherwise update fields and period controls in place: no flicker.
    func rebuildMenu(total: Agg, sources: [SourceStats]) {
        ensureMenuSkeleton()
        let active = activeSources(sources)
        // Structure, not live ordering or period, determines whether the panel
        // needs rebuilding. Recreating every view on a period switch caused a
        // visible flash and let the menu recalculate its position.
        let signature = active
            .map { "\($0.name):\($0.perModel.keys.sorted().joined(separator: ","))" }
            .sorted()
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
    // shrinks back, so changing values cannot move the menu's anchored edge.
    // The insets are already included in NSStackView.fittingSize; adding them on
    // every refresh made the panel grow a little each time.
    var stickyWidth: CGFloat = 360
    // Width needed by the current table with full names and icons enabled.
    // Reserving this up front keeps view toggles from resizing the menu.
    var minimumContentWidth: CGFloat = 0

    func resizePanel() {
        guard let panel = panelView else { return }
        panel.layoutSubtreeIfNeeded()
        let fitting = panel.fittingSize
        // NSStackView's fitting width only accounts for its leading inset in
        // this menu-hosted configuration. Measure the content explicitly so
        // the table gets the same trailing inset as the header and graph.
        let measuredWidth = panel.arrangedSubviews.map { $0.fittingSize.width }.max() ?? 0
        let contentWidth = max(measuredWidth, minimumContentWidth)
        let insetWidth = panel.edgeInsets.left + panel.edgeInsets.right
        stickyWidth = max(stickyWidth, ceil(contentWidth + insetWidth))
        let size = NSSize(width: stickyWidth, height: ceil(fitting.height))
        if size != panel.frame.size { panel.setFrameSize(size) }
    }

    func updatePeriodControls() {
        periodField?.stringValue = period.title(rangeStyle: periodRangeStyle)
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
                        ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
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
        resizePanel()  // in case a value grew wider than the panel was sized for
    }

    // The panel container is created once; its content is rebuilt in place so
    // the menu can stay open.
    func ensureMenuSkeleton() {
        guard panelMenu.items.isEmpty else { return }
        panelMenu.autoenablesItems = false

        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 0
        panel.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        panelView = panel

        let panelItem = NSMenuItem()
        panelItem.view = panel
        panelMenu.addItem(panelItem)
    }

    func buildPanelContent(total: Agg, active: [SourceStats]) {
        guard let panel = panelView else { return }
        if let sparkView { savedCatMotionState = sparkView.motionState() }
        for v in panel.arrangedSubviews {
            panel.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        statFields.removeAll()
        periodField = nil
        periodButtons.removeAll()
        screenshotButton = nil
        minimumContentWidth = 0

        func label(_ key: String?, _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor, mono: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
            f.textColor = color
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
            let row = NSStackView(views: [ProviderBadgeView(provider: provider), nameLabel])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 5
            return row
        }

        // Header: big spend + period word, with the D W M Y switcher on the right
        let spend = label("Spend", fmtMoney(total.cost), size: 24, weight: .semibold, mono: true)
        let periodLabel = label(nil, period.title(rangeStyle: periodRangeStyle), size: 12,
                                color: .secondaryLabelColor)
        periodField = periodLabel

        let switcher = NSStackView()
        switcher.orientation = .horizontal
        switcher.spacing = 9
        for p in Period.allCases {
            let b = NSButton(title: p.letter, target: self, action: #selector(periodClicked(_:)))
            b.isBordered = false
            b.tag = p.rawValue
            let title = p.title(rangeStyle: periodRangeStyle)
            b.toolTip = "Show \(title)"
            b.setAccessibilityLabel("Show \(title)")
            b.attributedTitle = NSAttributedString(
                string: p.letter,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: p == period ? .semibold : .regular),
                    .foregroundColor: p == period ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
                ])
            switcher.addArrangedSubview(b)
            periodButtons.append(b)
        }

        let capture = NSButton(image: NSImage(systemSymbolName: "camera",
                                               accessibilityDescription: "Copy Panel Screenshot")!,
                               target: self, action: #selector(copyPanelScreenshot))
        capture.isBordered = false
        capture.controlSize = .small
        capture.contentTintColor = .tertiaryLabelColor
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
                                       color: .secondaryLabelColor, mono: true))

        sparkView = nil
        if active.isEmpty {
            panel.setCustomSpacing(16, after: panel.arrangedSubviews.last!)
            panel.addArrangedSubview(label(nil, "No usage yet for this period", size: 13,
                                          weight: .medium))
            panel.setCustomSpacing(3, after: panel.arrangedSubviews.last!)
            let emptyMessage = label(nil,
                                     "Token Bar will populate as you use\nClaude Code, Codex, OpenCode, or Pi.",
                                     size: 12, color: .secondaryLabelColor)
            emptyMessage.maximumNumberOfLines = 2
            emptyMessage.lineBreakMode = .byWordWrapping
            panel.addArrangedSubview(emptyMessage)
            emptyMessage.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14).isActive = true
            emptyMessage.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14).isActive = true
            resizePanel()
            return
        }

        // Spend timeline for the period
        if showGraph {
            let cal = Calendar.current
            let spark = SparkBarView()
            spark.values = totalBuckets(active)
            spark.caption = period.caption
            spark.axis = period.axis(cal: cal, now: Date(), rangeStyle: periodRangeStyle)
            spark.catEnabled = showExperimentalCat
            if let savedCatMotionState { spark.restoreMotionState(savedCatMotionState) }
            spark.catAnimating = showExperimentalCat && menuIsOpen
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
            // passes and the menu visibly jumps before settling.
            let headerWidth = headerRowIndices.map {
                rows[$0][0].fittingSize.width
            }.max() ?? 0
            let models = active.flatMap { $0.perModel.keys }
            func fullModelLabelWidth(_ name: String) -> CGFloat {
                let nameLabel = label(nil, name, size: 12)
                let row = NSStackView(views: [ProviderBadgeView(provider: ""), nameLabel])
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

        resizePanel()
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
