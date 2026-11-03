import SwiftUI
import AppKit

// The look shared by every window: soft rounded cards on the system background,
// one dark "pill" for the main action of a window and a pale pill for the rest.

/// The one main action of a window: dark pill with light text (grey when it can't be used).
struct PrimaryPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundColor(isEnabled ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isEnabled ? Color.primary : Color.primary.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Everything else: a pale pill with normal text.
struct SoftPillStyle: ButtonStyle {
    /// Half size, for secondary buttons inside settings cards.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption : .body)
            .fontWeight(.medium)
            .foregroundColor(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, compact ? 10 : 18)
            .padding(.vertical, compact ? 5 : 8)
            .background(RoundedRectangle(cornerRadius: compact ? 7 : 8).fill(Color.primary.opacity(isEnabled ? 0.09 : 0.05)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A row of choices in one pale pill; the picked one is raised (same look as the format choice on the main window).
struct PillSegments: View {
    let options: [(id: String, label: String)]
    let selected: String
    let onPick: (String) -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { option in
                let isOn = option.id == selected
                Text(option.label)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color.primary.opacity(0.14) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { if isEnabled { onPick(option.id) } }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A button of a question window: same width for all of them, dark when it is the main answer.
struct DialogButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Group {
            if primary {
                Button(action: action) { label }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(action: action) { label }
                    .buttonStyle(SoftPillStyle())
            }
        }
    }

    private var label: some View {
        Text(title).lineLimit(1).frame(minWidth: 96)
    }
}

/// The one layout of every question window: icon, title, text and the buttons, all centred.
struct DialogLayout<Extra: View, Buttons: View>: View {
    let title: String
    var message: String = ""
    var width: CGFloat = 440
    @ViewBuilder var extra: Extra
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            extra
            HStack(spacing: 10) { buttons }
                .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 22, trailing: 28))
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension DialogLayout where Extra == EmptyView {
    init(title: String, message: String = "", width: CGFloat = 440, @ViewBuilder buttons: () -> Buttons) {
        self.init(title: title, message: message, width: width, extra: { EmptyView() }, buttons: buttons)
    }
}

/// Puts a question window on screen at the size its content needs.
func makeDialogWindow<Content: View>(_ content: Content, closable: Bool = true) -> NSWindow {
    let hosting = NSHostingController(rootView: content)
    let win = NSWindow(contentViewController: hosting)
    win.styleMask = closable ? [.titled, .closable] : [.titled]
    win.title = "Scorpena – video downloader"
    win.isReleasedWhenClosed = false
    win.isRestorable = false
    hosting.view.layoutSubtreeIfNeeded()
    win.setContentSize(hosting.view.fittingSize)
    win.centerExactlyOnScreen()
    return win
}

extension View {
    /// A rounded content card.
    func card(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// The look of a text field: a rounded, bordered field instead of the system bezel.
    func fieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// App icon + a window's title, the way the main window shows the brand.
struct WindowTitleRow: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.bold())
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Put in the background of a ScrollView's content: gives its scroll view the
/// classic always-visible scroll bar (shown only when there is more to scroll),
/// instead of the overlay one that fades away and hides that the window scrolls.
struct AlwaysVisibleScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PinView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class PinView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.pin() }
        }

        private func pin() {
            var current: NSView? = superview
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    scrollView.scrollerStyle = .legacy
                    scrollView.hasVerticalScroller = true
                    scrollView.autohidesScrollers = true
                    return
                }
                current = view.superview
            }
        }
    }
}

/// Lays its children out left to right like words, wrapping onto the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// A paragraph in which a "⚙" is the real gear button of the toolbar: it looks the
/// same and opens the same «Дополнительно» window.
struct TextWithGear: View {
    let text: String
    let action: () -> Void

    var body: some View {
        FlowLayout {
            ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, word in
                if word.contains("⚙") {
                    let parts = word.components(separatedBy: "⚙")
                    HStack(spacing: 0) {
                        Text(parts.first ?? "")
                        Button(action: action) {
                            Image(systemName: "gearshape")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Дополнительно"))
                        Text(parts.count > 1 ? parts[1] : "")
                    }
                } else {
                    Text(String(word))
                }
            }
        }
    }
}


/// Decides, frame by frame, how far a progress bar is drawn. Three things make it feel smooth:
/// while nothing is reported yet it creeps forward slowly (so the app never looks frozen); when
/// progress arrives it eases to the new place instead of jumping; and between two reports it keeps
/// going at the pace it was going, so it never stands still waiting for the next line.
final class BarDriver {
    private(set) var shown = 0.0
    private var lastValue = 0.0
    private var lastValueTime = Date()
    private var lastFrame = Date()
    private var creepStart = Date()
    private var rate = 0.0               // share of the whole per second, smoothed

    func frame(now: Date, value: Double, creeping: Bool) -> Double {
        let dt = min(0.1, max(0.001, now.timeIntervalSince(lastFrame)))
        lastFrame = now

        if value < lastValue - 0.2 || (value == 0 && lastValue > 0) {
            // A new download (or a pause): start over.
            shown = 0; rate = 0; creepStart = now
        }
        if value != lastValue {
            let span = now.timeIntervalSince(lastValueTime)
            if value > lastValue, span > 0.05 {
                let instant = (value - lastValue) / span
                rate = rate == 0 ? instant : rate * 0.6 + instant * 0.4
            }
            lastValue = value
            lastValueTime = now
        }

        var target: Double
        if value <= 0 {
            // Nothing reported yet: a slow creep inside the part of the bar kept for the preparation
            // (under 8%), long enough that it is still visibly moving after ten seconds.
            target = creeping ? 0.075 * (1 - exp(-now.timeIntervalSince(creepStart) / 8)) : 0
        } else {
            // Carry on at the pace of the last reports; the lead over them grows softly and
            // levels off (about 4%), so the bar slows down rather than stopping if a report is late.
            let cap = 0.04
            let ahead = cap * (1 - exp(-rate * now.timeIntervalSince(lastValueTime) / cap))
            target = min(1, value + max(0, ahead))
        }
        // The bar only goes forward (a report that lands behind it just waits to be caught up) — and
        // while a download runs it never stands completely still: a very slow drift, within 5% of the reports.
        target = max(target, shown)
        if value > 0, value < 1, shown < value + 0.05 { target = max(target, shown + 0.006 * dt) }

        // Ease towards the target: quick enough to keep up, soft enough to look like one motion.
        let settle = value >= 1 ? 0.12 : (value > 0 ? 0.35 : 0.8)
        shown += (target - shown) * (1 - exp(-dt / settle))
        if abs(shown - target) < 0.0005 { shown = target }
        return min(1, max(0, shown))
    }

    func isMoving(value: Double, creeping: Bool) -> Bool {
        creeping || (value > 0 && value < 1) || abs(shown - value) > 0.002
    }
}

/// A progress bar that glides (see `BarDriver`).
struct SmoothBar: View {
    let value: Double
    /// True while a download is on but has reported nothing yet.
    var creeping = false
    var height: CGFloat = 6
    var tint: Color = .accentColor
    var track: Color = Color.primary.opacity(0.12)
    var square = false

    @State private var driver = BarDriver()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !driver.isMoving(value: value, creeping: creeping))) { timeline in
            let drawn = driver.frame(now: timeline.date, value: value, creeping: creeping)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    shape.fill(track)
                    shape.fill(tint)
                        .frame(width: proxy.size.width * drawn)
                        .opacity(drawn > 0.001 ? 1 : 0)
                }
            }
            .frame(height: height)
        }
    }

    private var shape: AnyShape { square ? AnyShape(Rectangle()) : AnyShape(Capsule()) }
}

/// Every symbol of the toolbar, drawn by hand to ONE set of rules (the rules of the best open
/// line-icon sets, such as Lucide and Feather): a 24-unit grid, one stroke width (thin), round ends and
/// corners, outlines only — nothing filled — and the same visual size for all of them.
struct ToolbarIcon: View {
    let name: String

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 24
            let style = StrokeStyle(lineWidth: 1.55 * s, lineCap: .round, lineJoin: .round)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx - r) * s, y: (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
            }
            func line(_ path: inout Path, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
                path.move(to: p(x1, y1)); path.addLine(to: p(x2, y2))
            }
            var path = Path()
            switch name {
            case "queue":
                // A list: three lines, and a dot before each (a dot is a line of no length: same weight).
                for y: CGFloat in [6, 12, 18] {
                    line(&path, 8, y, 21, y)
                    line(&path, 3, y, 3.01, y)
                }
            case "history":
                // A clock with an arrow that runs back.
                let centre = (x: 12.0, y: 12.0, r: 9.0)
                var points: [CGPoint] = []
                let start = Double.pi, end = -137.0 * .pi / 180
                for k in 0...64 {
                    let t = start + (end - start) * Double(k) / 64
                    points.append(p(CGFloat(centre.x + centre.r * cos(t)), CGFloat(centre.y + centre.r * sin(t))))
                }
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.addLine(to: p(3, 8))
                path.move(to: p(3, 3)); path.addLine(to: p(3, 8)); path.addLine(to: p(8, 8))
                path.move(to: p(12, 7)); path.addLine(to: p(12, 12)); path.addLine(to: p(16, 14))
            case "scissors":
                path.addPath(circle(6, 6, 3))
                path.addPath(circle(6, 18, 3))
                line(&path, 20, 4, 8.12, 15.88)
                line(&path, 14.47, 14.48, 20, 20)
                line(&path, 8.12, 8.12, 12, 12)
            case "settings":
                // A gear: eight teeth round a ring, a hole in the middle.
                let teeth = 8
                for i in 0..<teeth {
                    let centre = Double(i) * 2 * .pi / Double(teeth)
                    let steps: [(Double, CGFloat)] = [(-0.25, 7.7), (-0.15, 10), (0.15, 10), (0.25, 7.7)]
                    for (k, step) in steps.enumerated() {
                        let angle = centre + step.0
                        let point = p(12 + step.1 * CGFloat(cos(angle)), 12 + step.1 * CGFloat(sin(angle)))
                        if i == 0 && k == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                path.closeSubpath()
                path.addPath(circle(12, 12, 3))
            case "sun":
                path.addPath(circle(12, 12, 4))
                line(&path, 12, 2, 12, 4); line(&path, 12, 20, 12, 22)
                line(&path, 4.93, 4.93, 6.34, 6.34); line(&path, 17.66, 17.66, 19.07, 19.07)
                line(&path, 2, 12, 4, 12); line(&path, 20, 12, 22, 12)
                line(&path, 6.34, 17.66, 4.93, 19.07); line(&path, 19.07, 4.93, 17.66, 6.34)
            case "moon":
                // The outer circle without the part a second circle covers.
                let c1 = (x: 12.0, y: 12.0, r: 9.0), c2 = (x: 16.5, y: 8.5, r: 7.2)
                let dx = c2.x - c1.x, dy = c2.y - c1.y
                let d = (dx * dx + dy * dy).squareRoot()
                let a = (c1.r * c1.r - c2.r * c2.r + d * d) / (2 * d)
                let h = max(0, c1.r * c1.r - a * a).squareRoot()
                let mx = c1.x + a * dx / d, my = c1.y + a * dy / d
                let tips = [(mx + h * dy / d, my - h * dx / d), (mx - h * dy / d, my + h * dx / d)]
                func angle(_ t: (Double, Double), _ c: (x: Double, y: Double, r: Double)) -> Double { atan2(t.1 - c.y, t.0 - c.x) }
                func arc(_ c: (x: Double, y: Double, r: Double), from a0: Double, to a1: Double, wanted: (Double, Double) -> Bool) -> [CGPoint] {
                    var span = a1 - a0
                    if span < 0 { span += 2 * .pi }
                    let m = (c.x + c.r * cos(a0 + span / 2), c.y + c.r * sin(a0 + span / 2))
                    if !wanted(m.0, m.1) { span -= 2 * .pi }
                    return (0...48).map { k in
                        let t = a0 + span * Double(k) / 48
                        return p(CGFloat(c.x + c.r * cos(t)), CGFloat(c.y + c.r * sin(t)))
                    }
                }
                let outside2: (Double, Double) -> Bool = { x, y in ((x - c2.x) * (x - c2.x) + (y - c2.y) * (y - c2.y)).squareRoot() > c2.r }
                let inside1: (Double, Double) -> Bool = { x, y in ((x - c1.x) * (x - c1.x) + (y - c1.y) * (y - c1.y)).squareRoot() < c1.r }
                let outer = arc(c1, from: angle(tips[0], c1), to: angle(tips[1], c1), wanted: outside2)
                let inner = arc(c2, from: angle(tips[1], c2), to: angle(tips[0], c2), wanted: inside1)
                if let first = outer.first {
                    path.move(to: first)
                    for point in outer.dropFirst() + inner { path.addLine(to: point) }
                    path.closeSubpath()
                }
            case "auto":
                // «Like the system»: a screen.
                path.addRoundedRect(in: CGRect(x: 2 * s, y: 3 * s, width: 20 * s, height: 14 * s),
                                    cornerSize: CGSize(width: 2 * s, height: 2 * s))
                line(&path, 8, 21, 16, 21)
                line(&path, 12, 17, 12, 21)
            default:
                break
            }
            context.stroke(path, with: .foreground, style: style)
        }
        .frame(width: 20, height: 20)
    }
}

/// A light hairline between the parts of a window.
struct ThinLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 0.5)
    }
}


/// «Показать файл» — one rule for every place that has such a button: the file is shown in Finder
/// when it is there; when it is not (deleted, moved), nothing opens and the caller says «Файл не найден».
/// (Asking Finder to select a file that is gone makes it open some folder instead — that was the bug.)
enum FileReveal {
    /// The words for the button and for «it is gone» — a file or a whole playlist folder.
    static func buttonTitle(folder: Bool) -> String { folder ? tr("Показать папку") : tr("Показать файл") }
    static func missingText(folder: Bool) -> String { folder ? tr("Плейлист не найден") : tr("Файл не найден") }

    @discardableResult
    static func show(_ url: URL?) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return false }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            NSWorkspace.shared.open(url)          // a playlist's folder opens
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return true
    }
}
