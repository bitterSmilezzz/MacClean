#!/usr/bin/env swift
// 生成 MacClean 应用图标（Apple 风格：渐变蓝底 + 白色圆角方块 + 光芒）
// 用法: swift scripts/make-icon.swift <输出目录>
import AppKit
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/macclean-icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iconutil 标准命名：icon_{size}x{size}.png + @2x 变体
let specs: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
let canvas = 1024.0

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // 背景圆角方块
    let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
                              xRadius: size * 0.2237, yRadius: size * 0.2237)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.51, blue: 0.98, alpha: 1),   // #3382fa
        NSColor(calibratedRed: 0.00, green: 0.40, blue: 0.80, alpha: 1),   // #0066cc
    ])!
    gradient.draw(in: bgPath, angle: -60)

    // 中心白色方块（"缓存盒"）
    let boxRect = NSRect(x: size * 0.30, y: size * 0.34,
                         width: size * 0.40, height: size * 0.34)
    let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: size * 0.08, yRadius: size * 0.08)
    NSColor.white.withAlphaComponent(0.95).setFill()
    boxPath.fill()

    // 方块上的"扫出"线条
    NSColor(calibratedRed: 0.0, green: 0.4, blue: 0.8, alpha: 1).setStroke()
    for i in 0..<3 {
        let y = boxRect.minY + boxRect.height * (0.28 + 0.24 * Double(i))
        let line = NSBezierPath()
        line.move(to: NSPoint(x: boxRect.minX + boxRect.width * 0.18, y: y))
        line.line(to: NSPoint(x: boxRect.maxX - boxRect.width * 0.18, y: y))
        line.lineWidth = size * 0.035
        line.lineCapStyle = .round
        line.stroke()
    }

    // 顶部"光芒"（扫描光）
    let cx = size * 0.62, cy = size * 0.76, r = size * 0.075
    NSColor.white.setFill()
    let dot = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    dot.fill()
    for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
        let small = NSBezierPath(ovalIn: NSRect(x: cx + dx * r * 1.9 - r * 0.28, y: cy + dy * r * 1.9 - r * 0.28,
                                               width: r * 0.56, height: r * 0.56))
        small.fill()
    }

    return image
}

for (s, filename) in specs {
    let img = drawIcon(size: CGFloat(s))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let path = "\(outDir)/\(filename)"
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
