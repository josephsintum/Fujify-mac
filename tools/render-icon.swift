#!/usr/bin/env swift
//
// render-icon.swift — generates the Fujify app icon at every size the
// platforms ask for.
//
// Usage:
//   swift tools/render-icon.swift [output-dir]        # macOS icon set
//   swift tools/render-icon.swift --windows [out-dir] # Windows PNG set
//
// Defaults: Assets.xcassets/AppIcon.appiconset for macOS,
//           build/windows-icon for Windows.
//
// Every size is drawn natively rather than downsampled from one large
// render, because the wordmark is the whole mark and it has to stay crisp.
//
// Two containers, one mark. macOS adds its own shadow and shows icons inset
// among other inset icons, so the squircle sits inside a 10% margin. Windows
// adds no shadow and applies no mask, and Fluent icons fill their box, so the
// same inset would read as a small icon on the taskbar — there the rounded
// square fills 92% and the mark scales up to match.
//
// Below 48px the wordmark is unreadable at any weight, so those sizes drop to
// an "f" monogram. The stripe stays at every size: a lone white "f" on a green
// rounded square is a well-known social icon with the hue changed, and the
// three colours are the only thing that tells them apart at 16px. What made
// the stripe unusable down there was never the size but the arithmetic --
// three segments across a width that is not a multiple of three land on
// fractional pixels and blend into one muddy line. Snapping the segment width
// to whole pixels first, then centring the band, keeps each colour crisp.
//

import AppKit
import CoreGraphics

// MARK: - Design constants

let backgroundColor = NSColor(red: 0x00 / 255, green: 0xA6 / 255, blue: 0x51 / 255, alpha: 1)
let textColor = NSColor.white

/// Three accent stripe colors evoking Fuji film simulations.
let stripeColors: [NSColor] = [
    NSColor(red: 0xD9 / 255, green: 0x49 / 255, blue: 0x4C / 255, alpha: 1),  // Velvia red
    NSColor(red: 0x4A / 255, green: 0xAF / 255, blue: 0xB8 / 255, alpha: 1),  // Provia teal
    NSColor(red: 0xE3 / 255, green: 0xB2 / 255, blue: 0x3C / 255, alpha: 1),  // Classic Neg yellow
]

/// How the mark sits inside the canvas, which is the only thing that differs
/// between the two platforms.
struct Platform {
    let name: String
    /// Inset of the rounded square from the canvas edge, as a fraction.
    let marginFraction: CGFloat
    /// Corner radius as a fraction of the square's side.
    let cornerRadiusFraction: CGFloat
    /// Wordmark cap height as a fraction of the canvas.
    let wordmarkFraction: CGFloat
    /// Stripe width as a fraction of the canvas.
    let stripeWidthFraction: CGFloat

    static let macOS = Platform(
        name: "macOS",
        marginFraction: 0.10,
        cornerRadiusFraction: 0.225,
        wordmarkFraction: 0.22,
        stripeWidthFraction: 0.55
    )

    static let windows = Platform(
        name: "Windows",
        marginFraction: 0.04,
        cornerRadiusFraction: 0.18,
        wordmarkFraction: 0.25,
        stripeWidthFraction: 0.62
    )
}

let textVerticalCenterFraction: CGFloat = 0.46  // slightly above center
/// Monogram cap height as a fraction of the canvas.
let monogramFraction: CGFloat = 0.50
let stripeHeightFraction: CGFloat = 0.045
let stripeYFraction: CGFloat = 0.70  // from top, of canvas

/// Below this the wordmark cannot be read, so the monogram is used instead.
let monogramBelow: CGFloat = 48

/// Monogram stripe geometry, all relative to the rounded square rather than
/// the canvas so the band never rides out over the corner radius.
let monogramSegmentFraction: CGFloat = 0.235
let monogramStripeInset: CGFloat = 0.19
/// A one-pixel band disappears at 16px, so it never goes below two.
let monogramStripeMinHeight: CGFloat = 2
/// Band thickness as a fraction of the canvas, before the minimum applies.
let monogramStripeHeightFraction: CGFloat = 0.07

// MARK: - Renderer

func renderIcon(size: CGFloat, platform: Platform) -> NSBitmapImageRep {
    let pixels = Int(size)
    // Explicit pixel dimensions bypass the screen backing-scale that
    // NSImage.lockFocus() applies, which would otherwise produce 2x PNGs.
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )
    else {
        fatalError("could not create NSBitmapImageRep at \(pixels)x\(pixels)")
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        fatalError("could not obtain CGContext")
    }

    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // Rounded-square background.
    let margin = size * platform.marginFraction
    let squareRect = CGRect(
        x: margin, y: margin,
        width: size - margin * 2, height: size - margin * 2
    )
    let cornerRadius = squareRect.width * platform.cornerRadiusFraction
    ctx.addPath(
        CGPath(
            roundedRect: squareRect,
            cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil
        ))
    ctx.setFillColor(backgroundColor.cgColor)
    ctx.fillPath()

    let useMonogram = size < monogramBelow

    // Drawn before the mark so the monogram can be centred in what is left
    // above it rather than in the square, which would have it sit on the band.
    let stripeTop = drawStripe(
        in: size,
        platform: platform,
        isMonogram: useMonogram,
        squareRect: squareRect,
        ctx: ctx
    )

    drawText(
        useMonogram ? "f" : "fujify",
        in: size,
        platform: platform,
        isMonogram: useMonogram,
        squareRect: squareRect,
        stripeTop: stripeTop
    )

    return bitmap
}

private func drawText(
    _ text: String,
    in size: CGFloat,
    platform: Platform,
    isMonogram: Bool,
    squareRect: CGRect,
    stripeTop: CGFloat
) {
    // A single letter can be much larger than the wordmark in the same box.
    let fontSize =
        isMonogram
        ? size * monogramFraction
        : size * platform.wordmarkFraction

    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .kern: isMonogram ? 0 : -fontSize * 0.02,
    ]

    let string = text as NSString
    let textSize = string.size(withAttributes: attributes)

    let originX = (size - textSize.width) / 2
    // The monogram centres in the room the stripe leaves it; the wordmark
    // keeps its own fixed position, which the stripe was drawn to suit.
    let originY =
        isMonogram
        ? (stripeTop + squareRect.maxY) / 2 - textSize.height / 2
        : size * (1 - textVerticalCenterFraction) - textSize.height / 2

    string.draw(at: NSPoint(x: originX, y: originY), withAttributes: attributes)
}

/// Draws the three-colour accent band and returns its top edge, so the
/// monogram can be placed in the space above it.
private func drawStripe(
    in size: CGFloat,
    platform: Platform,
    isMonogram: Bool,
    squareRect: CGRect,
    ctx: CGContext
) -> CGFloat {
    let segmentWidth: CGFloat
    let originX: CGFloat
    let height: CGFloat
    let originY: CGFloat

    if isMonogram {
        // Whole-pixel segments, then centre: the reverse order would put the
        // colour boundaries back on fractions and undo the point of it.
        segmentWidth = max((squareRect.width * monogramSegmentFraction).rounded(), 1)
        let totalWidth = segmentWidth * CGFloat(stripeColors.count)
        originX = (squareRect.midX - totalWidth / 2).rounded()
        height = max(
            (size * monogramStripeHeightFraction).rounded(),
            monogramStripeMinHeight
        )
        originY = (squareRect.minY + squareRect.height * monogramStripeInset).rounded()
    } else {
        let totalWidth = size * platform.stripeWidthFraction
        segmentWidth = totalWidth / CGFloat(stripeColors.count)
        originX = ((size - totalWidth) / 2).rounded()
        // A 1px stripe disappears, so it never goes below a full pixel.
        height = max(size * stripeHeightFraction, 1).rounded()
        originY = (size - size * stripeYFraction - height).rounded()
    }

    for (index, color) in stripeColors.enumerated() {
        ctx.setFillColor(color.cgColor)
        ctx.fill(
            CGRect(
                x: originX + CGFloat(index) * segmentWidth,
                y: originY,
                width: segmentWidth,
                height: height
            ))
    }

    return originY + height
}

func savePNG(bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "render-icon", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not encode PNG for \(url.lastPathComponent)"
            ]
        )
    }
    try pngData.write(to: url)
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsWindows = arguments.contains("--windows")
let positional = arguments.filter { !$0.hasPrefix("--") }

let platform: Platform = wantsWindows ? .windows : .macOS

let outputDir =
    positional.first
    ?? (wantsWindows ? "build/windows-icon" : "Assets.xcassets/AppIcon.appiconset")

/// macOS asks for @1x/@2x pairs; Windows wants the six sizes that go into
/// a single .ico.
let macSizes: [(pixels: CGFloat, filename: String)] = [
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

let windowsSizes: [(pixels: CGFloat, filename: String)] = [
    (16, "icon-16.png"),
    (20, "icon-20.png"),
    (24, "icon-24.png"),
    (32, "icon-32.png"),
    (48, "icon-48.png"),
    (256, "icon-256.png"),
]

let sizes = wantsWindows ? windowsSizes : macSizes

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for (pixels, filename) in sizes {
    let bitmap = renderIcon(size: pixels, platform: platform)
    try savePNG(bitmap: bitmap, to: URL(fileURLWithPath: "\(outputDir)/\(filename)"))
    let form = pixels < monogramBelow ? "monogram" : "wordmark"
    print("wrote \(filename) (\(Int(pixels))px, \(form))")
}

print("done — \(platform.name) icon set in \(outputDir)")

if wantsWindows {
    print("")
    print("Pack into an .ico with ImageMagick:")
    print("  magick \(outputDir)/icon-{16,20,24,32,48,256}.png fujify.ico")
}
