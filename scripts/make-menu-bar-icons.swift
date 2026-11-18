#!/usr/bin/env -S swift -suppress-warnings
// Generates the menu bar (status item) icons from the app icon's geometry (EasyReader.svg, 1024-unit canvas).
// One black path per icon, drawn painter-style (filled layers added, cut-outs subtracted): no masks, so they work as template images.
// Writes EasyReader/Assets.xcassets/MenuBarIcon*.imageset:
//   MenuBarIcon        speaker with waves
//   MenuBarIconIdle    speaker without waves
//   MenuBarIconPaused  speaker with pause bars
// Needs macOS 13+ (CGPath boolean operations) to run; the output works on any macOS.
//
// Usage: scripts/make-menu-bar-icons.swift [-h] [-g gap] [-p dir]
//   -g  gap between the headphones and the book, in canvas units (default 25, the icon's line width; ~1 px at 18 pt @2x)
//   -p  also write preview PNGs to dir: big.png (one icon, large) and preview.png (each icon at 16/18 pt, @1x/@2x, light/dark bar, magnified 4×)

import AppKit

let heightPt: CGFloat = 18

enum Speaker { case waves, idle, paused }

func usage(status: Int32 = 1) -> Never {
    print("Usage: scripts/make-menu-bar-icons.swift [-h] [-g gap] [-p dir]")
    exit(status)
}

var gap: CGFloat = 25
var previewDir: URL?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
        case "-g":
            guard let v = args.popFirst().flatMap(Double.init) else { usage() }
            gap = v
        case "-p":
            guard let v = args.popFirst() else { usage() }
            previewDir = URL(fileURLWithPath: v)
        case "-h": usage(status: 0)
        default: usage()
    }
}

// MARK: Shapes (app icon coordinates, y down)

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil)
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: rx, cornerHeight: ry, transform: nil)
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)
}

func cover(top: CGFloat, bottom: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 340, y: top))
    p.addLine(to: CGPoint(x: 696, y: top))
    p.addArc(tangent1End: CGPoint(x: 768, y: top), tangent2End: CGPoint(x: 768, y: top + 72), radius: 72)
    p.addLine(to: CGPoint(x: 768, y: bottom - 72))
    p.addArc(tangent1End: CGPoint(x: 768, y: bottom), tangent2End: CGPoint(x: 696, y: bottom), radius: 72)
    p.addLine(to: CGPoint(x: 340, y: bottom))
    p.closeSubpath()
    return p
}

// A band between two quadratic curves from x 251 (left) to x 340 (right): spines and the spine label.
func spineBand(_ top: (CGFloat, CGFloat, CGFloat), _ bottom: (CGFloat, CGFloat, CGFloat)) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 251, y: top.0))
    p.addQuadCurve(to: CGPoint(x: 340, y: top.2), control: CGPoint(x: 256, y: top.1))
    p.addLine(to: CGPoint(x: 340, y: bottom.2))
    p.addQuadCurve(to: CGPoint(x: 251, y: bottom.0), control: CGPoint(x: 256, y: bottom.1))
    p.closeSubpath()
    return p
}

func headphones() -> CGPath {
    let outer = ellipse(512, 335, 307, 282).union(rect(205, 335, 614, 65))
    let inner = ellipse(512, 327, 274, 221).union(rect(238, 327, 548, 200))
    var shape = outer.subtracting(inner).intersection(rect(0, 0, 1024, 400))
    for (outerX, innerX) in [(205.0, 256.0), (819.0, 768.0)] {
        let leg = CGMutablePath()
        leg.addLines(between: [
            CGPoint(x: outerX, y: 320), CGPoint(x: innerX, y: 307), CGPoint(x: innerX, y: 563), CGPoint(x: outerX, y: 550),
        ])
        leg.closeSubpath()
        shape = shape.union(leg)
    }
    let muffs = ellipse(205, 435.5, 51, 102.5).intersection(rect(0, 0, 205, 1024))
        .union(ellipse(819, 435.5, 51, 102.5).intersection(rect(819, 0, 205, 1024)))
    return shape.union(muffs)
}

func speaker(_ kind: Speaker) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 418, y: 410))
    p.addLine(to: CGPoint(x: 450, y: 410))
    p.addQuadCurve(to: CGPoint(x: 464, y: 405), control: CGPoint(x: 458, y: 410))
    p.addLine(to: CGPoint(x: 503, y: 368))
    p.addQuadCurve(to: CGPoint(x: 511, y: 372), control: CGPoint(x: 511, y: 361))
    p.addLine(to: CGPoint(x: 511, y: 550))
    p.addQuadCurve(to: CGPoint(x: 503, y: 554), control: CGPoint(x: 511, y: 561))
    p.addLine(to: CGPoint(x: 464, y: 517))
    p.addQuadCurve(to: CGPoint(x: 450, y: 512), control: CGPoint(x: 458, y: 512))
    p.addLine(to: CGPoint(x: 418, y: 512))
    p.addQuadCurve(to: CGPoint(x: 410, y: 504), control: CGPoint(x: 410, y: 512))
    p.addLine(to: CGPoint(x: 410, y: 418))
    p.addQuadCurve(to: CGPoint(x: 418, y: 410), control: CGPoint(x: 410, y: 410))
    p.closeSubpath()
    var shape: CGPath = p
    switch kind {
        case .idle:
            break
        case .paused:
            shape = shape.union(roundedRect(552, 380, 32, 162, 16, 16)).union(roundedRect(610, 380, 32, 162, 16, 16))
        case .waves:
            // (center x, radius, half angle): the icon's waves as arcs 25 thick with round caps.
            for (cx, r, half) in [(344.0, 205.7, 0.18), (356.0, 244.2, 0.34), (407.0, 244.9, 0.52)] {
                let arc = CGMutablePath()
                arc.addArc(center: CGPoint(x: cx, y: 461.5), radius: r, startAngle: -half, endAngle: half, clockwise: false)
                shape = shape.union(arc.copy(strokingWithWidth: 25, lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
    }
    return shape
}

func icon(_ kind: Speaker) -> CGPath {
    let back = cover(top: 358, bottom: 973).union(spineBand((282, 356, 358), (921, 972, 973)))
    let page1 = roundedRect(272, 333, 496, 615, 72, 76)
    let page2 = roundedRect(272, 297, 496, 615, 72, 76)
    let page3 = roundedRect(272, 261, 496, 615, 72, 76)
    let front = cover(top: 230, bottom: 845).union(spineBand((282, 232, 230), (897, 847, 845)))
    let label = spineBand((376, 326, 324), (436, 386, 384))
    let textLines = [666, 717, 768.5].map { roundedRect(384, $0, 333, 25, 12.5, 12.5) }.reduce(CGMutablePath() as CGPath) { $0.union($1) }
    let book = back.subtracting(page1).union(page2).subtracting(page3).union(front)
        .subtracting(label).subtracting(speaker(kind)).subtracting(textLines)
    let silhouette = back.union(page1).union(front)
    let halo = silhouette.copy(strokingWithWidth: 2 * gap, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return headphones().subtracting(silhouette.union(halo)).union(book)
}

// MARK: Output

func number(_ v: CGFloat) -> String {
    let s = String(format: "%.1f", v)
    return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
}

func pathData(_ path: CGPath) -> String {
    var d = ""
    func point(_ p: CGPoint) -> String { "\(number(p.x)) \(number(p.y))" }
    path.applyWithBlock { element in
        let pts = element.pointee.points
        switch element.pointee.type {
            case .moveToPoint: d += "M\(point(pts[0]))"
            case .addLineToPoint: d += "L\(point(pts[0]))"
            case .addQuadCurveToPoint: d += "Q\(point(pts[0])) \(point(pts[1]))"
            case .addCurveToPoint: d += "C\(point(pts[0])) \(point(pts[1])) \(point(pts[2]))"
            case .closeSubpath: d += "Z"
            @unknown default: break
        }
    }
    return d
}

func svg(_ path: CGPath) -> String {
    let box = path.boundingBoxOfPath.insetBy(dx: -8, dy: -8).integral
    let width = number(box.width / box.height * heightPt)
    return """
        <?xml version="1.0" encoding="utf-8" ?>
        <!-- Generated by scripts/make-menu-bar-icons.swift -->
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(number(heightPt))" \
        viewBox="\(Int(box.minX)) \(Int(box.minY)) \(Int(box.width)) \(Int(box.height))">
            <path fill="#000" d="\(pathData(path))" />
        </svg>

        """
}

func contentsJSON(_ filename: String) -> String {
    """
    {
      "images" : [
        {
          "filename" : "\(filename)",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "preserves-vector-representation" : true,
        "template-rendering-intent" : "template"
      }
    }

    """
}

// MARK: Previews

func bitmap(_ width: Int, _ height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ context: CGContext, to url: URL) throws {
    try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
}

func draw(_ path: CGPath, in context: CGContext, center: CGPoint, height: CGFloat, color: CGColor) {
    let box = path.boundingBoxOfPath
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: height / box.height, y: -height / box.height)
    context.translateBy(x: -box.midX, y: -box.midY)
    context.addPath(path)
    context.setFillColor(color)
    context.fillPath()
    context.restoreGState()
}

func writePreviews(_ icons: [CGPath], to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let big = bitmap(512, 512)
    big.setFillColor(.white)
    big.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    draw(icons[0], in: big, center: CGPoint(x: 256, y: 256), height: 480, color: .black)
    try writePNG(big, to: dir.appendingPathComponent("big.png"))

    let magnify: CGFloat = 4
    let cell = 22 * 2 * magnify + 16
    let combos = [false, true].flatMap { dark in [16.0, 18.0].flatMap { h in [1.0, 2.0].map { (dark, CGFloat(h), CGFloat($0)) } } }
    let sheet = bitmap(Int(CGFloat(combos.count) * cell), Int(CGFloat(icons.count) * cell))
    sheet.setFillColor(CGColor(gray: 0.5, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
    sheet.interpolationQuality = .none
    for (row, path) in icons.enumerated() {
        for (column, (dark, height, scale)) in combos.enumerated() {
            let side = Int(22 * scale)
            let small = bitmap(side, side)
            small.setFillColor(dark ? CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1) : CGColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1))
            small.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let middle = CGFloat(side) / 2
            draw(path, in: small, center: CGPoint(x: middle, y: middle), height: height * scale, color: dark ? .white : CGColor(gray: 0, alpha: 0.85))
            let origin = CGPoint(x: CGFloat(column) * cell + 8, y: CGFloat(sheet.height) - CGFloat(row + 1) * cell + 8)
            sheet.draw(small.makeImage()!, in: CGRect(origin: origin, size: CGSize(width: 22 * 2 * magnify, height: 22 * 2 * magnify)))
        }
    }
    try writePNG(sheet, to: dir.appendingPathComponent("preview.png"))
}

// MARK: Main

let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("EasyReader/Assets.xcassets")
let names: [(String, Speaker)] = [("MenuBarIcon", .waves), ("MenuBarIconIdle", .idle), ("MenuBarIconPaused", .paused)]
let icons = names.map { icon($0.1) }
do {
    for ((name, _), path) in zip(names, icons) {
        let set = assets.appendingPathComponent("\(name).imageset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try svg(path).write(to: set.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
        try contentsJSON("\(name).svg").write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        print("Wrote \(set.path)")
    }
    if let previewDir {
        try writePreviews(icons, to: previewDir)
        print("Wrote previews to \(previewDir.path)")
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
