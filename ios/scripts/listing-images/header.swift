// header.swift
// Makes the App Store product page header and search results images
// from the hero painting: crops it to the target's aspect ratio and
// Lanczos-scales it to exactly WIDTHxHEIGHT, as opaque RGB PNG
// (App Store Connect takes only PNG for these, with no alpha).
//
//   swift ios/scripts/listing-images/header.swift <src> <dst.png> <W> <H> <cropTop>
//
// cropTop is where the crop sits vertically, 0 (top) to 1 (bottom).
// Current files in ios/Nod/AppStore/header/, from
// website/assets/hero/desktop.png (1920×1080):
//   header-3840x1646.png         3840 1646 0.82  product page header, 21:9
//   search-1920x1280.png         1920 1280 0.5   search results, 3:2
//   header-search-5244x2950.png  5244 2950 0.5   one image for both, 16:9
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let src = URL(fileURLWithPath: a[1]), dst = URL(fileURLWithPath: a[2])
let W = Int(a[3])!, H = Int(a[4])!
let topFraction = Double(a[5])!       // where the crop starts, as share of the leftover height
let input = CIImage(contentsOf: src)!
let sw = input.extent.width, sh = input.extent.height
// Largest crop of the source with the target's aspect ratio.
var cw = sw, ch = (sw * Double(H) / Double(W)).rounded()
if ch > sh { ch = sh; cw = (sh * Double(W) / Double(H)).rounded() }
let top = ((sh - ch) * topFraction).rounded()
let x = ((sw - cw) / 2).rounded()
let rect = CGRect(x: x, y: sh - top - ch, width: cw, height: ch)
let cropped = input.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
let f = CIFilter.lanczosScaleTransform()
f.inputImage = cropped; f.scale = Float(Double(W) / cw); f.aspectRatio = Float((Double(H) / ch) / (Double(W) / cw))
let out = f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let cg = CIContext().createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: cs)!
let bmp = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
bmp.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, bmp.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(dst.lastPathComponent) from crop \(Int(cw))x\(Int(ch)) at top \(Int(top))")
