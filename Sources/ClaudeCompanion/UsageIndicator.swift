import AppKit

/// Drawing for the usage display: the ring gauge in the menu bar, and the
/// per-limit rows in its menu.
///
/// Both show what is *left*, like a battery - a full ring is a fresh allowance -
/// because "how much can I still do" is the question you glance up to answer.
enum UsageIndicator {
    static let symbolName = "bubble.left.and.bubble.right"
    private static let ringDiameter: CGFloat = 13
    private static let ringWidth: CGFloat = 2
    private static let gap: CGFloat = 5

    /// The app's usual menu-bar symbol with a ring gauge beside it.
    ///
    /// A template image, so the system tints it for light and dark menu bars and
    /// for the pressed state. The track is drawn at partial alpha, which a
    /// template keeps: its alpha channel is the mask.
    static func statusImage(fractionLeft: Double, dimmed: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let height = max(symbol.size.height, ringDiameter)
        let size = NSSize(width: symbol.size.width + gap + ringDiameter, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(
                in: NSRect(
                    x: 0, y: (height - symbol.size.height) / 2,
                    width: symbol.size.width, height: symbol.size.height
                )
            )

            let center = NSPoint(x: size.width - ringDiameter / 2, y: height / 2)
            let radius = (ringDiameter - ringWidth) / 2
            let alpha: CGFloat = dimmed ? 0.45 : 1

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = ringWidth
            NSColor.black.withAlphaComponent(0.3 * alpha).setStroke()
            track.stroke()

            let fraction = min(max(fractionLeft, 0), 1)
            guard fraction > 0 else { return true }
            // Clockwise from twelve o'clock, draining back towards it as the
            // allowance is used - the way a watch complication reads.
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true
            )
            arc.lineWidth = ringWidth
            arc.lineCapStyle = fraction < 1 ? .round : .butt
            NSColor.black.withAlphaComponent(alpha).setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The percentage beside the ring. Normal readings carry no colour, so the
    /// menu bar draws them in its own vibrant label colour.
    static func statusTitle(for limit: UsageLimit, dimmed: Bool) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular
            ),
        ]
        if let tint = tint(for: limit.level) {
            attributes[.foregroundColor] = tint
        } else if dimmed {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        return NSAttributedString(string: UsageText.percent(limit.percentLeft), attributes: attributes)
    }

    /// Colour for text and bars at a given level. `nil` means "the normal colour
    /// for this context", so the menu bar keeps its own vibrant label colour.
    static func tint(for level: UsageLimit.Level) -> NSColor? {
        switch level {
        case .normal: return nil
        case .low: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

/// One limit in the menu: its name and what's left, a bar, and when it resets.
final class UsageRowView: NSView {
    /// Matches where AppKit starts the title of a menu item, so the rows line up
    /// with the ordinary items below them (this menu reserves a checkmark column).
    static let leadingInset: CGFloat = 22
    static let trailingInset: CGFloat = 14
    static let width: CGFloat = 270

    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = UsageBar()

    init(limit: UsageLimit, now: Date) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 50))
        autoresizingMask = [.width]

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.stringValue = limit.title

        valueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .medium
        )
        valueLabel.alignment = .right
        valueLabel.stringValue = UsageText.percent(limit.percentLeft) + " left"
        valueLabel.textColor = UsageIndicator.tint(for: limit.level) ?? .labelColor

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = UsageText.resets(at: limit.resetsAt, now: now)

        bar.fraction = limit.fractionLeft
        bar.fill = UsageIndicator.tint(for: limit.level) ?? .controlAccentColor

        for view in [titleLabel, valueLabel, detailLabel, bar] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            "\(limit.title): \(valueLabel.stringValue). \(detailLabel.stringValue)"
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let left = Self.leadingInset
        let width = bounds.width - left - Self.trailingInset

        // `fittingSize`, not `intrinsicContentSize`: the latter comes up a couple
        // of points short for this font and clips the last letter.
        let valueWidth = ceil(valueLabel.fittingSize.width) + 2
        valueLabel.frame = NSRect(x: left + width - valueWidth, y: 3, width: valueWidth, height: 17)
        titleLabel.frame = NSRect(x: left, y: 3, width: width - valueWidth - 8, height: 17)
        bar.frame = NSRect(x: left, y: 24, width: width, height: 5)
        detailLabel.frame = NSRect(x: left, y: 32, width: width, height: 15)
    }
}

/// A thin rounded bar filled to `fraction`.
final class UsageBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var fill: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(self.fraction, 0), 1)
        guard fraction > 0 else { return }
        // Never narrower than the bar is tall, so a nearly empty allowance is
        // still a visible dot rather than a sliver that reads as a rendering glitch.
        var filled = bounds
        filled.size.width = max(bounds.width * fraction, bounds.height)
        fill.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - Preview

extension UsageIndicator {
    /// A sheet of the usage display for checking it by eye: the menu bar item at
    /// every level, then the menu rows, each in light and dark.
    static func preview(of usage: PlanUsage, stale: Bool) -> NSImage? {
        guard let headline = usage.headline else { return nil }
        let variants: [(UsageLimit, Bool)] = [
            (headline, stale),
            (headline.with(percentUsed: 80), false),
            (headline.with(percentUsed: 95), false),
            (headline.with(percentUsed: 100), false),
            (headline, true),
        ]

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)
            for (limit, dimmed) in variants {
                column.addArrangedSubview(menuBarReplica(limit, dimmed: dimmed, appearance: appearance))
            }
            column.addArrangedSubview(menuReplica(usage, appearance: appearance))
        }
        column.layoutSubtreeIfNeeded()
        column.frame.size = column.fittingSize

        guard let rep = column.bitmapImageRepForCachingDisplay(in: column.bounds) else { return nil }
        column.cacheDisplay(in: column.bounds, to: rep)
        let image = NSImage(size: column.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func menuBarReplica(
        _ limit: UsageLimit, dimmed: Bool, appearance: NSAppearance?
    ) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: UsageRowView.width, height: 24))
        bar.appearance = appearance
        bar.wantsLayer = true
        bar.layer?.backgroundColor = appearance?.name == .darkAqua
            ? NSColor(white: 0.16, alpha: 1).cgColor
            : NSColor(white: 0.93, alpha: 1).cgColor

        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.image = statusImage(fractionLeft: limit.fractionLeft, dimmed: dimmed)
        button.attributedTitle = statusTitle(for: limit, dimmed: dimmed)
        button.imagePosition = .imageLeading
        button.contentTintColor = .labelColor
        button.sizeToFit()
        button.frame.origin = NSPoint(x: 12, y: (24 - button.frame.height) / 2)
        bar.addSubview(button)

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: UsageRowView.width).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return bar
    }

    private static func menuReplica(_ usage: PlanUsage, appearance: NSAppearance?) -> NSView {
        let menu = NSStackView()
        menu.appearance = appearance
        menu.orientation = .vertical
        menu.spacing = 0
        menu.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        menu.wantsLayer = true
        menu.layer?.backgroundColor = appearance?.name == .darkAqua
            ? NSColor(white: 0.2, alpha: 1).cgColor
            : NSColor(white: 0.97, alpha: 1).cgColor

        for limit in usage.limits {
            let row = UsageRowView(limit: limit, now: Date())
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: UsageRowView.width).isActive = true
            row.heightAnchor.constraint(equalToConstant: row.frame.height).isActive = true
            menu.addArrangedSubview(row)
        }
        return menu
    }
}

private extension UsageLimit {
    func with(percentUsed: Double) -> UsageLimit {
        UsageLimit(
            title: title, percentUsed: percentUsed, resetsAt: resetsAt,
            isActive: isActive, severity: severity
        )
    }
}
