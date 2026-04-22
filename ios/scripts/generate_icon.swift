#!/usr/bin/env swift
// generate_icon.swift
// Renders the Nod app icon (orange rounded square + two black oval eyes with
// glossy highlights) at 1024x1024 and saves it as PNG.
//
// Usage: swift generate_icon.swift <output-path>
//
// Reusable: if you change proportions or colors, re-run and commit the PNG.
// This file is the source of truth for how the icon is generated; the PNG is
// derived output.

import AppKit
import CoreGraphics
import Foundation

let NOD_ORANGE = CGColor(red: 0.867, green: 0.427, blue: 0.173, alpha: 1.0)   // #DD6D2C — deeper, more saturated warm orange matching reference icon
let EYE_BLACK  = CGColor(red: 0.08,  green: 0.08,  blue: 0.08,  alpha: 1.0)
let HIGHLIGHT  = CGColor(red: 1.0,   green: 1.0,   blue: 1.0,   alpha: 1.0)

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Orange rounded-square background.
    // iOS icon corner radius ratio ≈ 0.2237 of the side length, pre-mask.
    let cornerRadius = s * 0.2237
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(
        roundedRect: bgRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.addPath(bgPath)
    ctx.setFillColor(NOD_ORANGE)
    ctx.fillPath()

    // Eye geometry. CG origin is bottom-left; Y increases upward.
    let eyeWidth  = s * 0.13
    let eyeHeight = s * 0.22          // ovals — taller than wide
    let eyeCenterY = s * 0.50         // vertically centered
    let leftEyeCX  = s * 0.33
    let rightEyeCX = s * 0.67

    // Black ovals
    ctx.setFillColor(EYE_BLACK)
    for cx in [leftEyeCX, rightEyeCX] {
        ctx.addEllipse(in: CGRect(
            x: cx - eyeWidth / 2,
            y: eyeCenterY - eyeHeight / 2,
            width: eyeWidth,
            height: eyeHeight
        ))
        ctx.fillPath()
    }

    // Small white highlight on upper-right of each eye (gives the "gloss").
    ctx.setFillColor(HIGHLIGHT)
    let hlSize = s * 0.035
    let hlOffsetX = eyeWidth * 0.12
    let hlOffsetY = eyeHeight * 0.18
    for cx in [leftEyeCX, rightEyeCX] {
        ctx.addEllipse(in: CGRect(
            x: cx + hlOffsetX - hlSize / 2,
            y: eyeCenterY + hlOffsetY - hlSize / 2,
            width: hlSize,
            height: hlSize
        ))
        ctx.fillPath()
    }

    // Export as PNG
    guard let cgImage = ctx.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    return bitmap.representation(using: .png, properties: [:])
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("Usage: swift generate_icon.swift <output-path>\n".data(using: .utf8)!)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
guard let pngData = renderIcon(size: 1024) else {
    FileHandle.standardError.write("Failed to render icon\n".data(using: .utf8)!)
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: url)
print("Generated 1024x1024 icon → \(outputPath)")
