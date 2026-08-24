import CoreGraphics
import CoreText
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Renders a handful of distinct demo images for the in-app tutorial. Each is a
// simple two-tone gradient card with a label — enough to look like real content
// to queue, tag, and query, without shipping anyone's photos.
//
// Run:  swift scripts/make-tutorial-images.swift
// Out:  Resources/TutorialImages/demo-*.png

let outDir = "Resources/TutorialImages"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

struct Card { let name: String; let top: UInt32; let bottom: UInt32 }
let cards: [Card] = [
    Card(name: "Sunset",  top: 0xFF8A5B, bottom: 0xE0407A),
    Card(name: "Ocean",   top: 0x2F9BE0, bottom: 0x0B3B7A),
    Card(name: "Forest",  top: 0x7BC47F, bottom: 0x1E5B34),
    Card(name: "Desert",  top: 0xF5CE4E, bottom: 0xC97B2A),
    Card(name: "City",    top: 0x9AA7B4, bottom: 0x37465C),
    Card(name: "Snow",    top: 0xEAF2FA, bottom: 0x9CB6CE),
    Card(name: "Flower",  top: 0xE879C0, bottom: 0x8A3FB0),
    Card(name: "Night",   top: 0x3A4668, bottom: 0x0C1024),
]

func comps(_ hex: UInt32) -> [CGFloat] {
    [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
     CGFloat(hex & 0xFF) / 255, 1]
}

let W = 900, H = 640
let space = CGColorSpace(name: CGColorSpace.sRGB)!

for card in cards {
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // vertical gradient
    let grad = CGGradient(colorsSpace: space,
                          colors: [CGColor(colorSpace: space, components: comps(card.bottom))!,
                                   CGColor(colorSpace: space, components: comps(card.top))!] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: CGFloat(H)), options: [])

    // soft sun/moon disc for a little variety
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.fillEllipse(in: CGRect(x: CGFloat(W) * 0.62, y: CGFloat(H) * 0.58,
                               width: 180, height: 180))

    // label
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 64, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95),
    ]
    let attr = CFAttributedStringCreate(nil, card.name as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: 60, y: 70)
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
    _ = bounds
    CTLineDraw(line, ctx)

    let img = ctx.makeImage()!
    let path = "\(outDir)/demo-\(card.name.lowercased()).png"
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}
