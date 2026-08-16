import AppKit
import Foundation

/// The menu bar glyph: Claude's radiating mark, drawn rather than shipped.
///
/// Drawn in code on purpose. A vector the app renders itself is one file
/// instead of an asset catalogue, scales to whatever height the menu bar is,
/// and — being a template image — inverts with the menu bar's appearance
/// without a second copy for dark mode. It is also nobody's logo file: this is
/// a plain radial burst identifying which app the notifications come from, not
/// a reproduction of Anthropic's artwork.
enum ClaudeMark {
    /// Rays around the circle. Odd, and enough to read as a burst rather than
    /// an asterisk, while still leaving daylight between strokes at menu bar
    /// size: at 18pt the outer ends sit ~4.5pt apart with ~1.6pt strokes.
    private static let rayCount = 11

    /// `crossedOut` is the "nothing will ever appear" state — the mark with a
    /// slash through it, the way macOS strikes through a disabled bell.
    static func image(height: CGFloat = 18, crossedOut: Bool) -> NSImage {
        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = rect.width * 0.44
            let inner = rect.width * 0.12
            let stroke = max(1.3, rect.width * 0.09)

            NSColor.black.setStroke()
            let burst = NSBezierPath()
            burst.lineWidth = stroke
            burst.lineCapStyle = .round
            for ray in 0..<rayCount {
                // Start at 12 o'clock so the mark reads the same every launch.
                let angle = (Double(ray) / Double(rayCount)) * 2 * .pi - .pi / 2
                burst.move(
                    to: CGPoint(
                        x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                burst.line(
                    to: CGPoint(
                        x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            }
            burst.stroke()

            guard crossedOut else { return true }

            // Carve a gap first, then draw the slash into it. Without the gap the
            // slash disappears wherever it crosses a ray — a template image has
            // no second colour to fall back on.
            let reach = rect.width * 0.5
            let from = CGPoint(x: center.x - reach * 0.72, y: center.y - reach * 0.72)
            let to = CGPoint(x: center.x + reach * 0.72, y: center.y + reach * 0.72)

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let gap = NSBezierPath()
            // Just enough daylight to read as a break. Wider and the burst
            // loses its centre and the rays either side of the diagonal, and
            // the crossed-out state stops looking like the same mark.
            gap.lineWidth = stroke * 1.8
            gap.lineCapStyle = .round
            gap.move(to: from)
            gap.line(to: to)
            gap.stroke()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let slash = NSBezierPath()
            slash.lineWidth = stroke
            slash.lineCapStyle = .round
            slash.move(to: from)
            slash.line(to: to)
            slash.stroke()
            return true
        }
        // Template, so the mark follows the menu bar's light/dark appearance
        // instead of fighting it — and stays legible over a translucent bar.
        image.isTemplate = true
        return image
    }
}
