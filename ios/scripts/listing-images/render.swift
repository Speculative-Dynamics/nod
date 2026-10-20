// render.swift
// Renders the App Store listing images from template.html with the
// system WebKit (no browser install needed).
//
//   swift ios/scripts/listing-images/render.swift <output-dir> [WIDTHxHEIGHT]
//
// The default size is 1290×2796 (App Store Connect's large iPhone slot).
// The required slot is now the medium one, iPhone 17 Pro size:
// pass 1206x2622. The template is always laid out 1290 CSS px wide;
// other sizes get a page tall enough for their aspect ratio and are
// scaled to fit, so every size shows the same slide.
//
// Each slide is template.html#N. Fonts load from Google Fonts, so this
// needs a network connection. Source screens live in ./screens (real
// Simulator captures; see README.md for how to refresh them).

import AppKit
import WebKit

let size = CommandLine.arguments.dropFirst(2).first?
    .split(separator: "x").compactMap { Int($0) } ?? []
let width = size.count == 2 ? size[0] : 1290      // output pixels
let height = size.count == 2 ? size[1] : 2796
let layoutWidth = 1290                              // template's CSS width
let layoutHeight = Int((Double(height) * Double(layoutWidth) / Double(width)).rounded())
let slides: [(Int, String)] = [
    (1, "01-listening"), (2, "02-offline"), (3, "03-memory"), (4, "04-voice"),
    (5, "05-your-way"), (6, "06-light-dark"), (7, "07-private"), (8, "08-privacy"),
]

let here = URL(fileURLWithPath: #filePath).absoluteURL.deletingLastPathComponent()
let template = here.appendingPathComponent("template.html")
let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? here.appendingPathComponent("out").path)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let window: NSWindow
    let webView: WKWebView
    var queue = slides
    var current: (Int, String)?

    override init() {
        let frame = NSRect(x: 0, y: 0, width: layoutWidth, height: layoutHeight)
        webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: layoutWidth, height: layoutHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        window.orderBack(nil)
        webView.navigationDelegate = self
    }

    func next() {
        guard !queue.isEmpty else { NSApp.terminate(nil); return }
        current = queue.removeFirst()
        // A distinct query per slide makes each load a real navigation
        // (a hash change alone wouldn't fire didFinish).
        var url = URLComponents(url: template.absoluteURL, resolvingAgainstBaseURL: true)!
        url.fragment = String(current!.0)
        url.query = "n=\(current!.0)"
        webView.loadFileURL(url.url!, allowingReadAccessTo: here)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Wait for web fonts and images, then a beat for layout.
            _ = try? await webView.callAsyncJavaScript(
                "await document.fonts.ready; await Promise.all([...document.images].map(i => i.decode().catch(() => {}))); return true;",
                contentWorld: .page)
            // Stretch the page to this size's aspect ratio.
            _ = try? await webView.evaluateJavaScript(
                "document.documentElement.style.height = document.body.style.height = '\(layoutHeight)px'")
            try? await Task.sleep(for: .milliseconds(400))
            await snapshot()
            next()
        }
    }

    func snapshot() async {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: layoutWidth, height: layoutHeight)
        config.snapshotWidth = NSNumber(value: width)
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let (_, name) = current else {
            print("snapshot failed for slide \(current?.0 ?? -1)")
            return
        }
        // Draw into an exact-size, opaque RGB context: width×height pixels
        // whatever the screen's backing scale, and no alpha channel
        // (App Store Connect rejects screenshots that have one).
        // AppKit can't draw into an alpha-less bitmap, so use CG.
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            print("could not draw slide \(current?.0 ?? -1)")
            return
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let url = outDir.appendingPathComponent("\(name).png")
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = MainActor.assumeIsolated { Renderer() }
MainActor.assumeIsolated { renderer.next() }
app.run()
