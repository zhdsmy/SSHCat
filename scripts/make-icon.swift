// Draws the app icon as vectors (so every size is rendered crisp) and packs Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift [preview.png [pixels]]
//
// TailCat's sibling: the same head on the same grid, but on a graphite terminal field, and the face
// is a shell prompt — a `>` and an amber cursor — matching the menu-bar glyph in MenuBarIcon.swift.
// SF Symbols may not be used in app icons (license), hence the hand-built shapes.
import AppKit

let fur = CGColor(srgbRed: 0.98, green: 0.95, blue: 0.90, alpha: 1)
let earInner = CGColor(srgbRed: 1.0, green: 0.72, blue: 0.52, alpha: 1)
let amber = CGColor(srgbRed: 1.0, green: 0.64, blue: 0.18, alpha: 1)
let graphite = CGColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 1)
let gradientTop = CGColor(srgbRed: 0.27, green: 0.29, blue: 0.34, alpha: 1)
let gradientBottom = CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)

func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: [a, b, c])
    path.closeSubpath()
    return path
}

/// Fills with rounded corners by also stroking the outline (ear tips would otherwise be needle-sharp).
func fillRounded(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, radius: CGFloat) {
    ctx.setFillColor(color)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(radius * 2)
    ctx.setLineJoin(.round)
    ctx.addPath(path); ctx.fillPath()
    ctx.addPath(path); ctx.strokePath()
}

/// Drawing space is 1024×1024 with y pointing down; `scale` maps it to device pixels for shadows,
/// whose offset and blur ignore the CTM.
func drawIcon(_ ctx: CGContext, scale: CGFloat) {
    // Apple's 1024 icon grid: an 824pt body with ~22.5% corner radius and room for the shadow.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(body)
    ctx.setFillColor(gradientBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let colors = [gradientTop, gradientBottom] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Warm light behind the head, as if from the cursor, so the silhouette doesn't sit on a flat field.
    let glowColors = [amber.copy(alpha: 0.22)!, amber.copy(alpha: 0)!] as CFArray
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glowColors, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 600), endRadius: 440, options: [])

    // Cat, composited as one layer so it casts a single shadow.
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 30 * scale, color: CGColor(gray: 0, alpha: 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    // Outer base corners sit inside the head outline so the rounded joins don't bulge past the cheeks.
    let ears = [
        [CGPoint(x: 270, y: 500), CGPoint(x: 282, y: 238), CGPoint(x: 448, y: 384)],
        [CGPoint(x: 754, y: 500), CGPoint(x: 742, y: 238), CGPoint(x: 576, y: 384)],
    ]
    for ear in ears { fillRounded(ctx, triangle(ear[0], ear[1], ear[2]), fur, radius: 24) }
    ctx.setFillColor(fur)
    ctx.fillEllipse(in: CGRect(x: 200, y: 360, width: 624, height: 470))
    ctx.endTransparencyLayer()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    for ear in ears {
        let cx = ear.map(\.x).reduce(0, +) / 3, cy = ear.map(\.y).reduce(0, +) / 3
        let inner = ear.map { CGPoint(x: cx + ($0.x - cx) * 0.52, y: cy + ($0.y - cy) * 0.52 + 12) }
        fillRounded(ctx, triangle(inner[0], inner[1], inner[2]), earInner, radius: 10)
    }

    // The face is a prompt: a `>` and a glowing cursor. Thick strokes keep it readable at 16px.
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: 360, y: 530))
    chevron.addLine(to: CGPoint(x: 466, y: 610))
    chevron.addLine(to: CGPoint(x: 360, y: 690))
    ctx.addPath(chevron)
    ctx.setStrokeColor(graphite)
    ctx.setLineWidth(60)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22 * scale, color: amber.copy(alpha: 0.9))
    ctx.setFillColor(amber)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 516, y: 646, width: 160, height: 60),
                       cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawIcon(ctx, scale: scale)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let args = Array(CommandLine.arguments.dropFirst())
if let preview = args.first {
    let pixels = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
    try render(pixels: pixels).write(to: URL(fileURLWithPath: preview))
    exit(0)
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", "Resources/AppIcon.icns", iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Wrote Resources/AppIcon.icns")
