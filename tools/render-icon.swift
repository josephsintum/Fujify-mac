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
// an "f" monogram. The accent stripe survives down to 24 and is dropped at 20
// and below, where it would be a smear.
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
let stripeHeightFraction: CGFloat = 0.045
let stripeYFraction: CGFloat = 0.70  // from top, of canvas

/// Below this the wordmark cannot be read, so the monogram is used instead.
let monogramBelow: CGFloat = 48
/// Below this even the stripe is noise.
let dropStripeBelow: CGFloat = 24

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
    drawText(
        useMonogram ? "f" : "fujify",
        in: size,
        platform: platform,
        isMonogram: useMonogram
    )

    // The monogram is centred when it stands alone, so the stripe would
    // collide with it; at 24–32 the glyph sits higher to leave room.
    if !useMonogram || size >= dropStripeBelow {
        drawStripe(in: size, platform: platform, isMonogram: useMonogram, ctx: ctx)
    }

    return bitmap
}

private func drawText(
    _ text: String,
    in size: CGFloat,
    platform: Platform,
    isMonogram: Bool
) {
    // A single letter can be much larger than the wordmark in the same box.
    let fontSize =
        isMonogram
        ? size * (size >= dropStripeBelow ? 0.50 : 0.56)
        : size * platform.wordmarkFraction

    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .kern: isMonogram ? 0 : -fontSize * 0.02,
    ]

    let string = text as NSString
    let textSize = string.size(withAttributes: attributes)

    // A lone monogram centres in the square; with a stripe below it, it
    // lifts to match where the wordmark sits.
    let centerFromTop: CGFloat =
        isMonogram
        ? (size >= dropStripeBelow ? 0.44 : 0.50)
        : textVerticalCenterFraction

    let originX = (size - textSize.width) / 2
    let centerFromBottom = size * (1 - centerFromTop)
    let originY = centerFromBottom - textSize.height / 2

    string.draw(at: NSPoint(x: originX, y: originY), withAttributes: attributes)
}

private func drawStripe(
    in size: CGFloat,
    platform: Platform,
    isMonogram: Bool,
    ctx: CGContext
) {
    let totalWidth = size * (isMonogram ? 0.52 : platform.stripeWidthFraction)
    // A 1px stripe disappears, so it never goes below a full pixel.
    let height = max(size * stripeHeightFraction, 1).rounded()
    let originX = ((size - totalWidth) / 2).rounded()
    let yFromTop = size * (isMonogram ? 0.76 : stripeYFraction)
    let originY = (size - yFromTop - height).rounded()
    let segmentWidth = totalWidth / CGFloat(stripeColors.count)

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
