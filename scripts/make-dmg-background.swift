// Draws the background of the download image's window, the DMG look shared by all of Moe's apps (moe-apps skill,
// "DMG window"): 660 × 400 pt, split in the middle – left Fona's colour (deep sage #3A8676, the switch colour #6DB6A5
// darkened until the Finder's black icon labels reach 4.85:1; 2.85:1 against the icon's sage plate), right #F4F4F6.
// No text. Between the app icon (centre 170, 188) and the Applications link (centre 490, 188) a motion trail:
// a small, 10 % lighter copy of the app icon at the right end (x 354–402) and behind it 5 silhouettes of the icon's
// plate, 19.2 pt apart, opacity rising from left to right like in-between frames of a movement.
//   swift scripts/make-dmg-background.swift <AppIcon-1024.png> <out.png> <scale>
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let args = CommandLine.arguments
guard args.count == 4, let icon = NSImage(contentsOfFile: args[1]), let scale = Double(args[3]) else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <AppIcon-1024.png> <out.png> <scale>\n".utf8)); exit(1)
}
let w = 660.0, h = 400.0, midY = 188.0
// sRGB throughout, so #3A8676 lands as #3A8676 in the Finder
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let cg = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                   space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
cg.scaleBy(x: scale, y: scale)
// top-left coordinates like Finder's icon positions
cg.translateBy(x: 0, y: h)
cg.scaleBy(x: 1, y: -1)

// split background
cg.setFillColor(color(0x3A8676)); cg.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
cg.setFillColor(color(0xF4F4F6)); cg.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))

// the icon's plate: 42.8 pt inside the 48 pt icon box (AppIcon-1024.png puts its 824 px plate on Apple's 1024 grid)
let plate = 42.8, radius = plate * 185 / 824
func platePath(_ x: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: midY - plate / 2, width: plate, height: plate), cornerWidth: radius, cornerHeight: radius, transform: nil)
}
// silhouette: the plate's flat sage (#BAD8D1, Theme.accent) with a thin edge so it stays visible on the light half
func fillPlate(_ x: Double, opacity: Double) {
    cg.saveGState()
    cg.setAlpha(opacity)
    cg.addPath(platePath(x)); cg.setFillColor(color(0xBAD8D1)); cg.fillPath()
    cg.addPath(platePath(x)); cg.setStrokeColor(color(0x9CC2B9)); cg.setLineWidth(0.5); cg.strokePath()
    cg.restoreGState()
}

// 5 silhouettes, strongest on the right
for (i, o) in [0.22, 0.34, 0.48, 0.64, 0.82].enumerated() { fillPlate(258 + 2.6 + Double(i) * 19.2, opacity: o) }

// the real icon (plate + F) at the right end, lightened 10 % towards white
let box = CGRect(x: 354, y: midY - 24, width: 48, height: 48)
let src = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let px = Double(src.width) / 1024, crop = CGRect(x: 100 * px, y: 100 * px, width: 824 * px, height: 824 * px)
let plateImage = src.cropping(to: crop)!
let target = CGRect(x: box.minX + (48 - plate) / 2, y: box.minY + (48 - plate) / 2, width: plate, height: plate)
cg.saveGState()
cg.addPath(platePath(target.minX)); cg.clip()
cg.translateBy(x: 0, y: target.minY * 2 + plate); cg.scaleBy(x: 1, y: -1)   // CGImage draws bottom-up
cg.draw(plateImage, in: target)
cg.restoreGState()
cg.saveGState()
cg.addPath(platePath(target.minX)); cg.clip()
cg.setFillColor(CGColor(gray: 1, alpha: 0.10)); cg.fill(target)
cg.restoreGState()

try! NSBitmapImageRep(cgImage: cg.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
