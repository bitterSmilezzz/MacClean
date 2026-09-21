#!/usr/bin/env swift
// 从一张主图生成 macOS 应用图标所需的 iconset。
//
// 为什么要脚本而不是直接把出图丢给 iconutil：出图的圆角半径、四周留白、以及
// "圆角外是不是真透明"每次都不同。这里统一做三件事——按 alpha 包围盒裁到图形本体、
// 等比铺满 1024、再用 Apple 的圆角比例（半径 = 边长 × 0.2237）重切一遍遮罩，
// 保证和系统自己的遮罩不打架。
//
// 用法: swift scripts/make-icns.swift <主图.png> <输出 iconset 目录>
import AppKit
import ImageIO

let args = CommandLine.arguments
// 用 CGImageSource 直接读 PNG：走 NSImage → tiffRepresentation 会把 alpha 通道丢掉，
// 那样就找不到圆角外沿的包围盒（实测报"没有透明通道"）。
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("读不到主图：\(args.count > 1 ? args[1] : "(未给出路径)")\n".data(using: .utf8)!)
    exit(2)
}

let W = cg.width, H = cg.height
guard let data = cg.dataProvider?.data,
      let px = CFDataGetBytePtr(data) else {
    FileHandle.standardError.write("取不到像素数据\n".data(using: .utf8)!)
    exit(2)
}
let bpp = cg.bitsPerPixel / 8, spp = cg.bytesPerRow
// 内存里 alpha 的位置：premultipliedFirst / .first 在最前，Last 系在最后
let hasAlpha: Bool
let alphaOffset: Int
switch cg.alphaInfo {
case .premultipliedFirst, .first:
    hasAlpha = true; alphaOffset = 0
case .premultipliedLast, .last:
    hasAlpha = true; alphaOffset = bpp - 1
default:
    hasAlpha = false; alphaOffset = 0
}

// alpha 包围盒（有不透明像素的范围）
var minX = W, minY = H, maxX = -1, maxY = -1
if hasAlpha {
    for y in 0..<H {
        for x in 0..<W where px[y * spp + x * bpp + alphaOffset] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}

// 有真透明通道时，按 alpha 包围盒取图形本体；没有就当作"铺满整幅的方形出图"，
// 圆角完全由下面的遮罩负责。（出图模型经常把"透明背景"画成假棋盘格，
// 那种图必须走后一条路，否则遮罩会切到假格子上。）
let cropRect: CGRect
if hasAlpha, maxX >= minX {
    let boxW = maxX - minX + 1, boxH = maxY - minY + 1
    let side = max(boxW, boxH)
    let cx = minX + boxW / 2, cy = minY + boxH / 2
    cropRect = CGRect(x: CGFloat(max(0, min(W - side, cx - side / 2))),
                      y: CGFloat(max(0, min(H - side, cy - side / 2))),
                      width: CGFloat(side), height: CGFloat(side))
    print("主图 \(W)x\(H)，图形包围盒 \(boxW)x\(boxH) @(\(minX),\(minY))")
} else {
    let side = min(W, H)
    cropRect = CGRect(x: CGFloat((W - side) / 2), y: CGFloat((H - side) / 2),
                      width: CGFloat(side), height: CGFloat(side))
    print("主图 \(W)x\(H) 无透明通道（alphaInfo=\(cg.alphaInfo.rawValue)）：按整幅方形处理，圆角由遮罩切")
}
guard let cropped = cg.cropping(to: cropRect) else {
    FileHandle.standardError.write("裁剪失败\n".data(using: .utf8)!)
    exit(2)
}

let outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iconutil 要求的命名
let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

func render(_ size: Int) -> Data? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // Apple 连续圆角用圆角矩形近似；半径比例取自系统图标度量
    let r = CGFloat(size) * 0.2237
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.draw(cropped, in: rect)
    guard let out = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: out)
    return rep.representation(using: .png, properties: [:])
}

var written = 0
for (size, name) in specs {
    guard let png = render(size) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    written += 1
}
print("已写出 \(written)/\(specs.count) 个尺寸到 \(outDir)")
guard written == specs.count else { exit(2) }
