// 生成 App 图标和菜单栏图标：swift tools/make-icon.swift
// 输出到 App/Assets.xcassets（AppIcon.appiconset、MenuBarIcon*.imageset）
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func gradientStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// 以 1024 为设计坐标系画 App 图标。
func drawAppIcon(_ ctx: CGContext) {
    // 圆角方块（macOS 图标网格：824 的方块居中，四周留给阴影）
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.55))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x0B0F16))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    // 底色：自上而下的深蓝灰渐变
    ctx.drawLinearGradient(gradient([color(0x1E2736), color(0x0A0E15)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // 左上角一点青色的光
    ctx.drawRadialGradient(gradient([color(0x39D0D6, 0.22), color(0x39D0D6, 0)]), startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])
    // 右下角一点绿色的光
    ctx.drawRadialGradient(gradient([color(0x3FB950, 0.16), color(0x3FB950, 0)]), startCenter: CGPoint(x: 760, y: 220), startRadius: 0,
                           endCenter: CGPoint(x: 760, y: 220), endRadius: 460, options: [])
    ctx.restoreGState()

    // 方块内沿的细高光
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // 信封
    let body = CGRect(x: 258, y: 318, width: 508, height: 372)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 52, cornerHeight: 52, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color(0x39D0D6, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0F1620, 0.92))
    ctx.fillPath()
    ctx.restoreGState()

    let cyanGreen = [color(0x39D0D6), color(0x3FB950)]
    gradientStroke(ctx, bodyPath, width: 30, colors: cyanGreen, from: CGPoint(x: 258, y: 690), to: CGPoint(x: 766, y: 318))

    // 信封口的 V 形
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: 296, y: 666))
    flap.addLine(to: CGPoint(x: 512, y: 500))
    flap.addLine(to: CGPoint(x: 728, y: 666))
    gradientStroke(ctx, flap, width: 28, colors: cyanGreen, from: CGPoint(x: 258, y: 690), to: CGPoint(x: 766, y: 318))

    // 终端提示符 >_
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: 394, y: 468))
    chevron.addLine(to: CGPoint(x: 458, y: 416))
    chevron.addLine(to: CGPoint(x: 394, y: 364))
    gradientStroke(ctx, chevron, width: 30, colors: [color(0x3FB950), color(0x3FB950)], from: .zero, to: CGPoint(x: 1, y: 1))
    let cursor = CGMutablePath()
    cursor.move(to: CGPoint(x: 500, y: 364))
    cursor.addLine(to: CGPoint(x: 588, y: 364))
    gradientStroke(ctx, cursor, width: 30, colors: [color(0x39D0D6), color(0x39D0D6)], from: .zero, to: CGPoint(x: 1, y: 1))

    // 右上角的红色提醒点
    let dot = CGRect(x: 690, y: 626, width: 124, height: 124)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: color(0xF85149, 0.75))
    ctx.setFillColor(color(0xF85149))
    ctx.fillEllipse(in: dot)
    ctx.restoreGState()
    ctx.setStrokeColor(color(0x0B0F16))
    ctx.setLineWidth(16)
    ctx.strokeEllipse(in: dot)
    ctx.setFillColor(color(0xFF7B72, 0.9))
    ctx.fillEllipse(in: dot.insetBy(dx: 30, dy: 30).offsetBy(dx: -8, dy: 10).applying(.identity))
}

/// 菜单栏模板图标：单色，系统按菜单栏颜色着色。以 36x36 为设计坐标系。
func drawMenuBarIcon(_ ctx: CGContext, badge: Bool) {
    ctx.setStrokeColor(color(0x000000))
    ctx.setFillColor(color(0x000000))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(3)
    let body = CGRect(x: 4, y: 7, width: 28, height: 20)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 6, y: 25))
    ctx.addLine(to: CGPoint(x: 18, y: 17))
    ctx.addLine(to: CGPoint(x: 30, y: 25))
    ctx.strokePath()
    // >_
    ctx.setLineWidth(2.6)
    ctx.move(to: CGPoint(x: 12.5, y: 15))
    ctx.addLine(to: CGPoint(x: 16, y: 12.2))
    ctx.addLine(to: CGPoint(x: 12.5, y: 9.4))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 19.5, y: 9.6))
    ctx.addLine(to: CGPoint(x: 24, y: 9.6))
    ctx.strokePath()
    if badge {
        // 挖掉一圈再画实心点，和信封分开
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: 21, y: 20, width: 15, height: 15))
        ctx.setBlendMode(.normal)
        ctx.fillEllipse(in: CGRect(x: 24, y: 23, width: 9, height: 9))
    }
}

func png(pixels: Int, design: CGFloat, draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / design, y: CGFloat(pixels) / design)
    draw(ctx)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func writeJSON(_ object: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let info: [String: Any] = ["author": "xcode", "version": 1]
try writeJSON(["info": info], root.appendingPathComponent("Contents.json"))

// App 图标
let iconSet = root.appendingPathComponent("AppIcon.appiconset")
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)@\(scale)x.png"
    try write(png(pixels: pixels, design: 1024, draw: drawAppIcon), iconSet.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
try writeJSON(["images": images, "info": info], iconSet.appendingPathComponent("Contents.json"))

// 菜单栏图标（模板）：普通 / 带提醒点
for (name, badge) in [("MenuBarIcon", false), ("MenuBarIconBadge", true)] {
    let set = root.appendingPathComponent("\(name).imageset")
    var entries: [[String: String]] = []
    for scale in [1, 2, 3] {
        let file = "\(name)@\(scale)x.png"
        try write(png(pixels: 18 * scale, design: 36) { drawMenuBarIcon($0, badge: badge) }, set.appendingPathComponent(file))
        entries.append(["filename": file, "idiom": "universal", "scale": "\(scale)x"])
    }
    try writeJSON(["images": entries, "info": info, "properties": ["template-rendering-intent": "template"]], set.appendingPathComponent("Contents.json"))
}
print("图标已生成到 \(root.path)")
