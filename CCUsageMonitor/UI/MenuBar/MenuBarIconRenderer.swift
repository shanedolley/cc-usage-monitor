import AppKit

/// Draws the menu bar donuts: a ring per metric with its percentage centered inside. Returns a
/// non-template image so the warning and critical colors show; it resolves the label and track
/// colors against whatever appearance draws it, so light and dark menu bars both read well.
enum MenuBarIconRenderer {
    private static let barHeight: CGFloat = 22      // standard menu bar thickness
    private static let diameter: CGFloat = 17
    private static let lineWidth: CGFloat = 2.5
    private static let gap: CGFloat = 3
    private static let padX: CGFloat = 1

    static func image(specs: [DonutSpec], dimmed: Bool) -> NSImage {
        let count = CGFloat(specs.count)
        let width = count * diameter + max(0, count - 1) * gap + 2 * padX
        let size = NSSize(width: max(width, diameter), height: barHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            for (index, spec) in specs.enumerated() {
                let x = padX + CGFloat(index) * (diameter + gap)
                let frame = NSRect(x: x, y: (barHeight - diameter) / 2, width: diameter, height: diameter)
                draw(spec, in: frame, dimmed: dimmed)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ spec: DonutSpec, in frame: NSRect, dimmed: Bool) {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let radius = (frame.width - lineWidth) / 2
        let alpha: CGFloat = dimmed ? 0.45 : 1

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.withAlphaComponent(alpha).setStroke()
        track.stroke()

        let fill = max(0, min(spec.percent, 100))
        if fill > 0 {
            // Clockwise from 12 o'clock, sweeping the filled fraction.
            let start: CGFloat = 90
            let end = start - CGFloat(fill) / 100 * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            spec.level.arcColor.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }

        drawNumber("\(spec.percent)", in: frame, alpha: alpha)
    }

    private static func drawNumber(_ text: String, in frame: NSRect, alpha: CGFloat) {
        let inner = frame.width - 2 * lineWidth - 1
        var fontSize: CGFloat = 8
        var attributes: [NSAttributedString.Key: Any] = [:]
        var bounds = NSSize.zero
        while true {
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
            attributes = [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)]
            bounds = (text as NSString).size(withAttributes: attributes)
            if bounds.width <= inner || fontSize <= 5 { break }
            fontSize -= 0.5
        }
        let origin = NSPoint(x: frame.midX - bounds.width / 2, y: frame.midY - bounds.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

private extension UsageLevel {
    /// The filled-arc color. Normal uses the system accent so the fill is glanceable against the
    /// grey track; warning and critical escalate to amber and red. The number is always present,
    /// so color stays a secondary signal (NFR-006).
    var arcColor: NSColor {
        switch self {
        case .normal: return .controlAccentColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
