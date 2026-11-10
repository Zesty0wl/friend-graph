import AppKit
import Metal
import CoreText

/// How text is set. The app uses two faces: Apple's serif for headlines and the system face for everything else.
struct TextStyle: Hashable {
    enum Face: Hashable { case serif, sans }
    var face: Face
    var size: Double
    var weight: NSFont.Weight = .regular
    var tracking: Double = 0

    static func serif(_ size: Double) -> TextStyle { TextStyle(face: .serif, size: size) }
    static func sans(_ size: Double, _ weight: NSFont.Weight = .regular, tracking: Double = 0) -> TextStyle {
        TextStyle(face: .sans, size: size, weight: weight, tracking: tracking)
    }

    func font(scale: Double) -> NSFont {
        let base = NSFont.systemFont(ofSize: size * scale, weight: weight)
        guard face == .serif, let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size * scale) ?? base
    }
}

/// One large texture that holds every piece of text and every photo the pictures use, so a frame
/// can be drawn without switching textures. Text is drawn into it once and reused.
final class Atlas {
    struct Entry {
        var u0: Float, v0: Float, u1: Float, v1: Float
        /// Size in the units the caller draws in (points for text).
        var width: Double, height: Double
    }

    let texture: MTLTexture
    private let side = 4096
    private var entries: [String: Entry] = [:]
    private var measures: [String: CGSize] = [:]
    private var shelfX = 0, shelfY = 0, shelfHeight = 0
    /// Goes up every time the atlas is emptied, so callers know stored corners are stale.
    private(set) var generation = 0

    init?(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4096, height: 4096, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
        texture = made
    }

    private func place(width: Int, height: Int) -> (Int, Int)? {
        guard width <= side, height <= side else { return nil }
        if shelfX + width > side { shelfX = 0; shelfY += shelfHeight; shelfHeight = 0 }
        if shelfY + height > side {
            // Full: start again. Everything is redrawn on demand, which costs one slow frame.
            entries.removeAll(); shelfX = 0; shelfY = 0; shelfHeight = 0; generation += 1
        }
        let at = (shelfX, shelfY)
        shelfX += width; shelfHeight = max(shelfHeight, height)
        return at
    }

    /// Draws into a bitmap of the given pixel size and stores it. `points` is the size the caller will draw it at.
    private func store(_ key: String, pixels: (Int, Int), points: CGSize, draw: (CGContext) -> Void) -> Entry? {
        let w = pixels.0 + 2, h = pixels.1 + 2            // a clear pixel all round, so neighbours never bleed in
        guard w > 2, h > 2, let at = place(width: w, height: h),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.translateBy(x: 1, y: 1)
        draw(context)
        texture.replace(region: MTLRegionMake2D(at.0, at.1, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        let s = Float(side)
        let entry = Entry(u0: Float(at.0 + 1) / s, v0: Float(at.1 + 1) / s, u1: Float(at.0 + w - 1) / s, v1: Float(at.1 + h - 1) / s,
                          width: points.width, height: points.height)
        entries[key] = entry
        return entry
    }

    private func line(_ string: String, _ style: TextStyle, scale: Double) -> (CTLine, CGSize) {
        var attributes: [NSAttributedString.Key: Any] = [.font: style.font(scale: scale), .foregroundColor: NSColor.white]
        if style.tracking != 0 { attributes[.kern] = style.tracking * scale }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (line, CGSize(width: width, height: ascent + descent))
    }

    /// The size a line of text takes, in points.
    func measure(_ string: String, _ style: TextStyle) -> CGSize {
        let key = "\(string)|\(style.hashValue)"
        if let known = measures[key] { return known }
        let size = line(string, style, scale: 1).1
        if measures.count > 4000 { measures.removeAll() }
        measures[key] = size
        return size
    }

    /// A line of text, drawn white so the shader can tint it. `scale` is pixels per point.
    func text(_ string: String, _ style: TextStyle, scale: Double) -> Entry? {
        // Sizes are rounded to a few steps so resizing a window does not redraw every label for every pixel.
        let step = max(0.25, (scale * 4).rounded(.up) / 4)
        let key = "t|\(string)|\(style.hashValue)|\(step)"
        if let found = entries[key] { return found }
        let (made, size) = line(string, style, scale: step)
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(made, nil, &descent, nil)
        return store(key, pixels: (Int(size.width.rounded(.up)) + 2, Int(size.height.rounded(.up)) + 2),
                     points: CGSize(width: (size.width + 2) / step, height: (size.height + 2) / step)) { context in
            context.textPosition = CGPoint(x: 1, y: descent + 1)
            CTLineDraw(made, context)
        }
    }

    /// A photo, stored once under the given name.
    func image(_ key: String, _ image: CGImage) -> Entry? {
        if let found = entries["i|" + key] { return found }
        let side = min(384, max(image.width, image.height))
        return store("i|" + key, pixels: (side, side), points: CGSize(width: side, height: side)) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// The head-and-shoulders figure shown for someone with no photo, drawn white for tinting.
    func figure() -> Entry? {
        if let found = entries["figure"] { return found }
        let side = 256.0
        return store("figure", pixels: (Int(side), Int(side)), points: CGSize(width: side, height: side)) { context in
            context.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            context.clip()
            context.setFillColor(NSColor.white.cgColor)
            let r = side / 2
            context.fillEllipse(in: CGRect(x: r - r * 0.3, y: r + r * 0.2 - r * 0.3, width: r * 0.6, height: r * 0.6))
            context.fillEllipse(in: CGRect(x: r - r * 0.56, y: r - r * 0.22 - r * 1.3, width: r * 1.12, height: r * 1.3))
        }
    }
}
