#!/usr/bin/env swift
//
// render-icon.swift — generates the Fujify app icon at every macOS-required
// size and writes them straight into Assets.xcassets/AppIcon.appiconset.
//
// Usage:
//   swift tools/render-icon.swift [output-dir]
//
// Default output dir: Assets.xcassets/AppIcon.appiconset
//
// Each size is drawn natively (not downsampled from a single large render)
// so the wordmark stays crisp at 16px and 32px.
//

import AppKit
import CoreGraphics

// MARK: - Design constants

let backgroundColor = NSColor(red: 0x00 / 255, green: 0xA6 / 255, blue: 0x51 / 255, alpha: 1)
let textColor = NSColor.white

// Three accent stripe colors evoking Fuji film simulations.
let stripeColors: [NSColor] = [
    NSColor(red: 0xD9 / 255, green: 0x49 / 255, blue: 0x4C / 255, alpha: 1),  // Velvia red
    NSColor(red: 0x4A / 255, green: 0xAF / 255, blue: 0xB8 / 255, alpha: 1),  // Provia teal
    NSColor(red: 0xE3 / 255, green: 0xB2 / 255, blue: 0x3C / 255, alpha: 1),  // Classic Neg yellow
]

// Proportional sizes — all in fractions of the canvas side.
let marginFraction: CGFloat = 0.10            // squircle inset from canvas edge
let cornerRadiusFraction: CGFloat = 0.225     // of squircle side
let textHeightFraction: CGFloat = 0.22        // of canvas
let textVerticalCenterFraction: CGFloat = 0.46  // slightly above center
let stripeWidthFraction: CGFloat = 0.55       // of canvas
let stripeHeightFraction: CGFloat = 0.045
let stripeYFraction: CGFloat = 0.70           // from top, of canvas

// MARK: - Renderer

func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    // NSBitmapImageRep with explicit pixel dimensions — bypasses the screen
    // backing-scale that NSImage.lockFocus() applies, which would otherwise
    // produce 2x-sized PNGs on Retina.
    guard let bitmap = NSBitmapImageRep(
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
    ) else {
        fatalError("could not create NSBitmapImageRep at \(pixels)x\(pixels)")
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        fatalError("could not obtain CGContext")
    }

    // Clear the canvas (transparent outside the squircle).
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // Squircle background.
    let margin = size * marginFraction
    let squircleRect = CGRect(
        x: margin,
        y: margin,
        width: size - margin * 2,
        height: size - margin * 2
    )
    let cornerRadius = squircleRect.width * cornerRadiusFraction
    let squirclePath = CGPath(
        roundedRect: squircleRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(backgroundColor.cgColor)
    ctx.fillPath()

    // Text "fujify".
    let fontSize = size * textHeightFraction
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let textAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .kern: -fontSize * 0.02,
    ]
    let text = "fujify" as NSString
    let textSize = text.size(withAttributes: textAttributes)
    // Core Graphics has Y up; we want the visual center of the text at
    // textVerticalCenterFraction from the TOP, so flip when computing y.
    let textOriginX = (size - textSize.width) / 2
    let textCenterFromBottom = size * (1 - textVerticalCenterFraction)
    let textOriginY = textCenterFromBottom - textSize.height / 2
    text.draw(
        at: NSPoint(x: textOriginX, y: textOriginY),
        withAttributes: textAttributes
    )

    // Three accent stripes at the bottom, contiguous (no gaps).
    let stripeTotalWidth = size * stripeWidthFraction
    let stripeHeight = size * stripeHeightFraction
    let stripeOriginX = (size - stripeTotalWidth) / 2
    let stripeYFromTop = size * stripeYFraction
    let stripeOriginY = size - stripeYFromTop - stripeHeight
    let segmentWidth = stripeTotalWidth / CGFloat(stripeColors.count)
    for (index, color) in stripeColors.enumerated() {
        ctx.setFillColor(color.cgColor)
        ctx.fill(
            CGRect(
                x: stripeOriginX + CGFloat(index) * segmentWidth,
                y: stripeOriginY,
                width: segmentWidth,
                height: stripeHeight
            )
        )
    }

    return bitmap
}

func savePNG(bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "render-icon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG for \(url.lastPathComponent)"]
        )
    }
    try pngData.write(to: url)
}

// MARK: - Main

let outputDir =
    CommandLine.arguments.count >= 2
    ? CommandLine.arguments[1] : "Assets.xcassets/AppIcon.appiconset"

let sizes: [(pixels: CGFloat, filename: String)] = [
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

try FileManager.default.createDirectory(
    atPath: outputDir,
    withIntermediateDirectories: true
)

for (pixels, filename) in sizes {
    let bitmap = renderIcon(size: pixels)
    let url = URL(fileURLWithPath: "\(outputDir)/\(filename)")
    try savePNG(bitmap: bitmap, to: url)
    print("wrote \(filename) (\(Int(pixels))px, actual \(bitmap.pixelsWide)x\(bitmap.pixelsHigh))")
}
print("done")
