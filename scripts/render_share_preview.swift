import AppKit

// Run from the project root: swift scripts/render_share_preview.swift
// Reproduce the login SVG composition using its original icon and wordmark assets.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 630,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 1200, height: 630).fill()

// The login logo has a 1040 × 340 viewBox, centered here without scaling.
let origin = NSPoint(x: 80, y: 145)
// Use the raster export to retain the SVG relief and shadows in AppKit.
let icon = NSImage(contentsOfFile: "priv/static/images/brand/captain_homework-icon-512.png")!
let iconRect = NSRect(x: origin.x, y: origin.y + 10, width: 320, height: 320)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: iconRect, xRadius: 88, yRadius: 88).addClip()
icon.draw(in: iconRect)
NSGraphicsContext.restoreGraphicsState()

// Match the login's nested SVG viewBox and alpha mask, preserving the original lettering.
let wordmark = NSImage(size: NSSize(width: 695, height: 290), flipped: false) { bounds in
    let source = NSImage(contentsOfFile: "priv/static/images/brand/captain_homework-footer.png")!
    source.size = NSSize(width: 2022, height: 778)
    let scale = min(bounds.width / 1300, bounds.height / 530)
    let destination = NSRect(x: (bounds.width - 1300 * scale) / 2,
                             y: (bounds.height - 530 * scale) / 2,
                             width: 1300 * scale, height: 530 * scale)
    source.draw(in: destination, from: NSRect(x: 650, y: 778 - 120 - 530, width: 1300, height: 530),
                operation: .sourceOver, fraction: 1)
    NSColor(srgbRed: 30 / 255, green: 68 / 255, blue: 141 / 255, alpha: 1).setFill()
    bounds.fill(using: .sourceIn)
    return true
}
wordmark.draw(in: NSRect(x: origin.x + 345, y: origin.y + 25, width: 695, height: 290))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "priv/static/images/brand/share-preview.png"))
