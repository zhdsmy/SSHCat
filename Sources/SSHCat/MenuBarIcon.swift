import AppKit

/// Menu-bar glyph: a cat head wearing a `>_` prompt. Outline while idle, solid while a forward is up.
///
/// Drawn in code rather than loaded by name: `MenuBarExtra(_:image:)` only looks in an asset
/// catalog, which a SwiftPM build has none of, so bundled PDFs left the status item blank.
enum MenuBarIcon {
    static let idle = make(filled: false)
    static let active = make(filled: true)

    private static func make(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(ctx, filled: filled)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SSHCat"
        return image
    }

    /// 18×18 points, y down. The prompt matches the one on the app icon.
    static func draw(_ ctx: CGContext, filled: Bool) {
        let ink = CGColor(gray: 0, alpha: 1)
        let silhouette = CGPath(ellipseIn: CGRect(x: 1.6, y: 5.2, width: 14.8, height: 11.4), transform: nil)
            .union(triangle(CGPoint(x: 2.1, y: 9.6), CGPoint(x: 3.0, y: 1.4), CGPoint(x: 8.2, y: 5.6)))
            .union(triangle(CGPoint(x: 15.9, y: 9.6), CGPoint(x: 15.0, y: 1.4), CGPoint(x: 9.8, y: 5.6)))

        let prompt = CGMutablePath()
        prompt.move(to: CGPoint(x: 5.3, y: 8.4))
        prompt.addLine(to: CGPoint(x: 8.0, y: 10.6))
        prompt.addLine(to: CGPoint(x: 5.3, y: 12.8))
        let cursor = CGRect(x: 9.3, y: 12.0, width: 3.8, height: 1.6)

        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if filled {
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(ink)
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(0.6)
            ctx.addPath(silhouette); ctx.fillPath()
            ctx.addPath(silhouette); ctx.strokePath()
            ctx.setBlendMode(.destinationOut)
            ctx.setLineWidth(1.6)
            ctx.addPath(prompt); ctx.strokePath()
            ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
            ctx.fillPath()
            ctx.endTransparencyLayer()
        } else {
            ctx.setStrokeColor(ink)
            ctx.setFillColor(ink)
            ctx.setLineWidth(1.3)
            ctx.addPath(silhouette); ctx.strokePath()
            ctx.setLineWidth(1.5)
            ctx.addPath(prompt); ctx.strokePath()
            ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
            ctx.fillPath()
        }
    }

    private static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [a, b, c])
        path.closeSubpath()
        return path
    }
}
