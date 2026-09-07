// Cadre uygulama simgesini uretir. Kullanim: swift Scripts/make-icon.swift
import AppKit

/// Cadre = cerceve. Simge iki dikdortgenden kurulur: disarida ince bir cerceve,
/// iceride kaydirilmis dolu bir panel. Ust uste binme derinlik verir ve 16 pikselde
/// bile ayirt edilir kalir.
func drawIcon(size: CGFloat, into context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let unit = size / 1024

    let plateInset = 60 * unit
    let plate = rect.insetBy(dx: plateInset, dy: plateInset)
    let radius = 200 * unit
    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Zemin: koyu murekkep.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let ground = [
        NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).cgColor,
        NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: ground, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
    }
    context.restoreGState()

    let amber = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.32, alpha: 1)
    let cream = NSColor(srgbRed: 0.97, green: 0.95, blue: 0.91, alpha: 1)

    let shift = 74 * unit
    let side = 470 * unit
    let center = CGPoint(x: plate.midX, y: plate.midY)

    // Icerideki dolu panel, sag asagi kaydirilmis.
    let panel = CGRect(
        x: center.x - side / 2 + shift,
        y: center.y - side / 2 - shift,
        width: side,
        height: side
    )
    context.setFillColor(amber.cgColor)
    context.addPath(CGPath(
        roundedRect: panel, cornerWidth: 40 * unit, cornerHeight: 40 * unit, transform: nil
    ))
    context.fillPath()

    // Disaridaki cerceve, sol yukari kaydirilmis. Panelin uzerinden geciyor.
    let frame = CGRect(
        x: center.x - side / 2 - shift,
        y: center.y - side / 2 + shift,
        width: side,
        height: side
    )
    let stroke = 62 * unit
    context.setStrokeColor(cream.cgColor)
    context.setLineWidth(stroke)
    context.setLineJoin(.round)
    context.addPath(CGPath(
        roundedRect: frame.insetBy(dx: stroke / 2, dy: stroke / 2),
        cornerWidth: 40 * unit, cornerHeight: 40 * unit, transform: nil
    ))
    context.strokePath()
}

func writePNG(size: Int, to url: URL) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return }
    drawIcon(size: CGFloat(size), into: context)
    guard let image = context.makeImage() else { return }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output, "public.png" as CFString, 1, nil
    ) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return }
    try? (output as Data).write(to: url)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("Resources/Cadre.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// macOS iconutil bu adlari bekler.
let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (size, name) in variants {
    writePNG(size: size, to: iconset.appendingPathComponent("\(name).png"))
}
print("iconset hazir: \(iconset.path)")
