import SwiftUI
import ImageIO

let TAU = Double.pi * 2

struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    func color(_ alpha: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: max(0, min(1, alpha)))
    }
    static func mix(_ a: RGB, _ b: RGB, _ f: Double) -> RGB {
        RGB(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
    }
}

/// The whole palette. Near-black ground, warm paper text, and one run of colour that means closeness:
/// amber next to me, through rose, to violet at the edge.
enum Pal {
    static let ground = RGB(7, 7, 12)
    static let paper = RGB(244, 241, 234)
    static let soft = RGB(169, 167, 180)
    static let quiet = RGB(143, 141, 155)
    static let amber = RGB(255, 180, 84)
    static let rose = RGB(255, 122, 144)
    static let violet = RGB(143, 124, 247)
    static let core = RGB(255, 217, 168)
    static let memory = RGB(255, 236, 200)
    static let series: [RGB] = [
        RGB(255, 180, 84), RGB(255, 150, 110), RGB(255, 122, 144), RGB(214, 120, 220), RGB(143, 124, 247),
        RGB(110, 140, 255), RGB(110, 168, 255), RGB(90, 196, 240), RGB(79, 214, 224), RGB(110, 226, 190),
    ]
    static let categories: [RGB] = [
        RGB(255, 180, 84), RGB(255, 122, 144), RGB(79, 214, 224), RGB(110, 226, 190), RGB(143, 124, 247),
        RGB(255, 150, 110), RGB(110, 168, 255), RGB(214, 120, 220), RGB(160, 160, 176),
    ]

    /// Colour for a distance from the centre of the circle picture (about 100 to 295 points).
    static func warmth(_ distance: Double) -> RGB {
        let u = max(0, min(0.999, (distance - 100) / 195)) * 2
        return u < 1 ? RGB.mix(amber, rose, u) : RGB.mix(rose, violet, u - 1)
    }
}

enum NameStyle: String, CaseIterable, Identifiable {
    case full, first, initials, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Full"
        case .first: return "First names"
        case .initials: return "Initials"
        case .none: return "None"
        }
    }
}

struct DrawOptions: Equatable {
    var names: NameStyle = .first
    var photos = true
}

/// What the side panel shows for whatever is under the pointer.
struct Detail: Equatable {
    struct Row: Equatable, Identifiable {
        var label: String, value: String
        var id: String { label }
    }
    var title: String
    var subtitle: String
    var rows: [Row] = []
}

/// A person as the pictures need them: names in each style and a square photo ready to draw.
struct Face {
    let id: String
    let name: String
    let first: String
    let initials: String
    let image: Image?
    let standing: Standing
    let relationship: Relationship

    init(_ p: Person, _ decisions: Decisions) {
        id = p.id; name = p.name; first = p.first
        initials = p.initials.first.map { $0.isLetter } == true ? p.initials : "#"
        image = p.photo.flatMap(Face.square)
        standing = decisions.standing(of: p)
        relationship = decisions.relationship(of: p)
    }

    func label(_ style: NameStyle) -> String? {
        switch style {
        case .full: return name
        case .first: return first
        case .initials: return initials
        case .none: return nil
        }
    }

    /// Decodes, downsamples and centre-crops a photo to a square.
    static func square(_ data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 320]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let side = min(image.width, image.height)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let cropped = image.cropping(to: rect) else { return nil }
        return Image(decorative: cropped, scale: 1)
    }
}

/// One of the four pictures. A scene owns its own motion, so the same code draws the live view,
/// a saved picture and every frame of a video.
protocol VisualScene: AnyObject {
    var designSize: CGSize { get }
    func advance(by dt: Double)
    func draw(_ g: inout GraphicsContext, _ options: DrawOptions)
    func pointerDown(_ p: CGPoint)
    func pointerMoved(_ p: CGPoint)
    func pointerUp(_ p: CGPoint)
    func hover(_ p: CGPoint?)
    /// Changes whenever the side panel should refresh.
    var detailKey: String { get }
    var detail: Detail? { get }
    /// The person under the pointer, if this picture is of people.
    var selectedPersonID: String? { get }
    var footer: String { get }
}

extension VisualScene {
    func pointerDown(_ p: CGPoint) {}
    func pointerMoved(_ p: CGPoint) {}
    func pointerUp(_ p: CGPoint) {}
    func hover(_ p: CGPoint?) {}
    var detailKey: String { "" }
    var detail: Detail? { nil }
    var selectedPersonID: String? { nil }
}

func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

func arc(_ x: Double, _ y: Double, _ r: Double, _ a0: Double, _ a1: Double) -> Path {
    var p = Path()
    p.addArc(center: pt(x, y), radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
    return p
}

func serif(_ size: Double) -> Font { .system(size: size, weight: .regular, design: .serif) }
func sans(_ size: Double, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

func wrapAngle(_ x: Double) -> Double {
    var v = x
    while v > .pi { v -= TAU }
    while v < -.pi { v += TAU }
    return v
}

func minutesText(_ m: Double?) -> String {
    guard let m else { return "too few replies to say" }
    if m < 1 { return "under a minute" }
    if m < 90 { return "\(Int(m.rounded())) minutes" }
    return "\(Int((m / 60).rounded())) hours"
}

extension GraphicsContext {
    /// Text with an optional halo of background colour, so it stays readable over anything.
    func label(_ string: String, at p: CGPoint, font: Font, color: Color, anchor: UnitPoint = .center,
               halo: Color? = nil, tracking: Double = 0) {
        if let halo {
            let under = resolve(Text(string).font(font).tracking(tracking).foregroundStyle(halo))
            for k in 0..<8 {
                let a = Double(k) / 8 * TAU
                draw(under, at: CGPoint(x: p.x + cos(a) * 2.2, y: p.y + sin(a) * 2.2), anchor: anchor)
            }
        }
        draw(Text(string).font(font).tracking(tracking).foregroundStyle(color), at: p, anchor: anchor)
    }

    func glow(_ x: Double, _ y: Double, _ r: Double, _ c: RGB, _ alpha: Double) {
        fill(circle(x, y, r), with: .radialGradient(Gradient(colors: [c.color(alpha), c.color(0)]), center: pt(x, y), startRadius: 0, endRadius: r))
    }
}
