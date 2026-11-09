#!/usr/bin/env zsh
# Render docs/v2/icon-dbman.svg to an iconset and build Resources/AppIcon.icns.
# Uses only macOS tools: swift (AppKit renders the SVG) and iconutil.
set -euo pipefail

root=${0:A:h:h}
src=$root/docs/v2/icon-dbman.svg
out=$root/Resources/AppIcon.icns
work=$(mktemp -d "${TMPDIR:-/tmp}/dbman-icon.XXXXXX")
trap 'rm -rf "$work"' EXIT
set=$work/AppIcon.iconset
mkdir -p "$set" "${out:h}"

cat > "$work/render.swift" <<'SWIFT'
import AppKit
// args: <svg> <outdir>; writes the 10 iconset PNGs at exact pixel sizes.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let args = CommandLine.arguments
let image = NSImage(contentsOf: URL(fileURLWithPath: args[1]))!
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: args[2] + "/" + name + ".png"))
}
SWIFT

swift "$work/render.swift" "$src" "$set"
iconutil -c icns "$set" -o "$out"
echo "wrote $out"
