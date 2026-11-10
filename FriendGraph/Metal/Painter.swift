import Foundation
import CoreGraphics
import simd

/// A colour with opacity, as the pictures describe it. Not premultiplied.
struct RGBA {
    var r: Float, g: Float, b: Float, a: Float
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
}

extension RGB {
    func c(_ alpha: Double = 1) -> RGBA {
        RGBA(r: Float(r / 255), g: Float(g / 255), b: Float(b / 255), a: Float(max(0, min(1, alpha))))
    }
}

/// Where a piece of text hangs from the point it is drawn at.
enum Anchor { case centre, top, bottom, leading, trailing, bottomLeading, topLeading }

/// Collects everything a picture wants drawn this frame, in order, in the picture's own
/// coordinates. The renderer then draws the lot on the GPU in a few calls.
final class Painter {
    struct Shape {
        var place: SIMD4<Float>, extent: SIMD4<Float>, first: SIMD4<Float>, second: SIMD4<Float>
        var kind: SIMD4<Float>, more: SIMD4<Float>, uv: SIMD4<Float>, spare: SIMD4<Float>
    }
    struct Point { var position: SIMD2<Float>; var spare: SIMD2<Float>; var colour: SIMD4<Float> }
    enum Kind: Equatable { case shapes, mesh, curves, stored(String) }
    struct Batch {
        var kind: Kind
        var additive: Bool
        var clip: CGRect?
        var start: Int
        var count: Int
        /// For stored meshes: where to put them and how strongly to draw them.
        var transform: (Double, Double, Double, Double, Double, Double) = (1, 0, 0, 1, 0, 0)
        var tint: Float = 1
    }
    /// A mesh that has been asked for but is not yet on the GPU. The renderer uploads these.
    private(set) var pending: [String: [Point]] = [:]
    /// Says whether a stored mesh is already on the GPU. Set by the renderer.
    var isStored: (String) -> Bool = { _ in false }
    private struct State {
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0      // x' = a x + c y + tx,  y' = b x + d y + ty
        var opacity = 1.0
        var additive = false
        var clip: CGRect?
    }

    let atlas: Atlas
    private(set) var shapes: [Shape] = []
    private(set) var points: [Point] = []
    private(set) var batches: [Batch] = []
    private var state = State()
    private var stack: [State] = []
    /// Size of the target in pixels.
    private(set) var pixels = CGSize.zero

    init(atlas: Atlas) { self.atlas = atlas }

    func begin(pixels: CGSize) {
        self.pixels = pixels
        shapes.removeAll(keepingCapacity: true); points.removeAll(keepingCapacity: true); batches.removeAll(keepingCapacity: true); pending.removeAll()
        state = State(); stack.removeAll()
    }

    // MARK: State

    var opacity: Double { get { state.opacity } set { state.opacity = max(0, min(1, newValue)) } }
    /// Light that adds up, for glows, strands and anything meant to shine.
    var additive: Bool { get { state.additive } set { state.additive = newValue } }
    func save() { stack.append(state) }
    func restore() { if let last = stack.popLast() { state = last } }
    func translate(_ x: Double, _ y: Double) { state.tx += state.a * x + state.c * y; state.ty += state.b * x + state.d * y }
    func scale(_ s: Double) { state.a *= s; state.b *= s; state.c *= s; state.d *= s }
    func rotate(_ angle: Double) {
        let co = cos(angle), si = sin(angle), a = state.a, b = state.b, c = state.c, d = state.d
        state.a = a * co + c * si; state.b = b * co + d * si
        state.c = -a * si + c * co; state.d = -b * si + d * co
    }
    /// Pixels per unit under the current transform.
    var unit: Double { sqrt(abs(state.a * state.d - state.b * state.c)) }
    /// Limits drawing to a rectangle, given in the current coordinates. Assumes no rotation.
    func clip(_ rect: CGRect?) {
        guard let rect else { state.clip = nil; return }
        let p0 = map(rect.minX, rect.minY), p1 = map(rect.maxX, rect.maxY)
        let made = CGRect(x: min(p0.0, p1.0), y: min(p0.1, p1.1), width: abs(p1.0 - p0.0), height: abs(p1.1 - p0.1))
        state.clip = state.clip.map { $0.intersection(made) } ?? made
    }

    private func map(_ x: Double, _ y: Double) -> (Double, Double) { (state.a * x + state.c * y + state.tx, state.b * x + state.d * y + state.ty) }
    private func premultiplied(_ c: RGBA) -> SIMD4<Float> {
        // Premultiplied colour. For light that adds up the alpha is left at zero, which makes the
        // ordinary "over" blend add the colour to whatever is beneath it.
        let a = c.a * Float(state.opacity)
        return SIMD4(c.r * a, c.g * a, c.b * a, state.additive ? 0 : a)
    }

    private func batch(_ kind: Kind, count: Int, start: Int) {
        if var last = batches.last, last.kind == kind, kind != .curves || true, last.additive == state.additive, last.clip == state.clip, last.start + last.count == start {
            if case .stored = kind {} else {
                last.count += count
                batches[batches.count - 1] = last
                return
            }
        }
        batches.append(Batch(kind: kind, additive: state.additive, clip: state.clip, start: start, count: count))
    }

    /// One quad: centre and half size in the current coordinates, turned by `angle`.
    private func quad(x: Double, y: Double, halfWidth: Double, halfHeight: Double, angle: Double = 0,
                      first: RGBA, second: RGBA = .clear, type: Float, _ k2: Double = 0, _ k3: Double = 0,
                      more: SIMD4<Float> = .zero, uv: SIMD4<Float> = .zero, padded: Bool = true) {
        guard first.a > 0 || second.a > 0, state.opacity > 0.002 else { return }
        let pad = padded ? 1.0 / max(unit, 0.0001) : 0             // a pixel of room so soft edges are not cut off
        let hw = halfWidth + pad, hh = halfHeight + pad
        let co = cos(angle), si = sin(angle)
        let centre = map(x, y)
        let ax = (state.a * co * hw + state.c * si * hw, state.b * co * hw + state.d * si * hw)
        let ay = (-state.a * si * hh + state.c * co * hh, -state.b * si * hh + state.d * co * hh)
        shapes.append(Shape(place: SIMD4(Float(centre.0), Float(centre.1), Float(ax.0), Float(ax.1)),
                            extent: SIMD4(Float(ay.0), Float(ay.1), Float(hw), Float(hh)),
                            first: premultiplied(first), second: premultiplied(second),
                            kind: SIMD4(type, Float(unit), Float(k2), Float(k3)), more: more, uv: uv, spare: .zero))
        batch(.shapes, count: 1, start: shapes.count - 1)
    }

    // MARK: Shapes

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ colour: RGBA) {
        // A hard-edged rectangle: drawn as a mesh so there is no soft border.
        mesh([(x, y, colour), (x + w, y, colour), (x, y + h, colour), (x + w, y, colour), (x + w, y + h, colour), (x, y + h, colour)])
    }

    func disc(_ x: Double, _ y: Double, _ r: Double, _ colour: RGBA) {
        guard r > 0 else { return }
        quad(x: x, y: y, halfWidth: r, halfHeight: r, first: colour, type: 1, r, -1, more: SIMD4(0, 7, 0, 0))
    }

    /// A circle outline, or part of one: `from` is the starting angle and `sweep` how far round it goes.
    func ring(_ x: Double, _ y: Double, _ r: Double, width: Double, _ colour: RGBA, from: Double = 0, sweep: Double = 7, round: Bool = false) {
        guard r > 0, sweep > 0.0005 else { return }
        let outer = r + width / 2
        quad(x: x, y: y, halfWidth: outer + (round ? width : 0), halfHeight: outer + (round ? width : 0), first: colour, type: 1, outer, r - width / 2,
             more: SIMD4(Float(from), Float(sweep), round ? 1 : 0, 0))
    }

    /// A circular fade from one colour at `from` to another at `to`. With `filled`, the first colour also fills the middle.
    func radial(_ x: Double, _ y: Double, from: Double, to: Double, _ inner: RGBA, _ outer: RGBA, filled: Bool = true) {
        guard to > 0 else { return }
        quad(x: x, y: y, halfWidth: to, halfHeight: to, first: inner, second: outer, type: 2, from, to, more: SIMD4(filled ? 1 : 0, 0, 0, 0))
    }

    /// A circular fade through several colours, each at a fraction of the way from `from` to `to`.
    func radial(_ x: Double, _ y: Double, from: Double, to: Double, stops: [(Double, RGBA)]) {
        for i in 0..<max(0, stops.count - 1) {
            let r0 = from + (to - from) * stops[i].0, r1 = from + (to - from) * stops[i + 1].0
            radial(x, y, from: r0, to: r1, stops[i].1, stops[i + 1].1, filled: i == 0)
        }
    }

    func glow(_ x: Double, _ y: Double, _ r: Double, _ colour: RGB, _ alpha: Double) {
        radial(x, y, from: 0, to: r, colour.c(alpha), colour.c(0))
    }

    func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, width: Double, _ start: RGBA, _ end: RGBA? = nil, round: Bool = true) {
        let dx = x1 - x0, dy = y1 - y0, length = hypot(dx, dy)
        guard length > 0.0001 || round else { return }
        quad(x: (x0 + x1) / 2, y: (y0 + y1) / 2, halfWidth: length / 2 + (round ? width / 2 : 0), halfHeight: width / 2, angle: atan2(dy, dx),
             first: start, second: end ?? start, type: 3, length / 2, width / 2, more: SIMD4(round ? 1 : 0, 0, 0, 0))
    }

    /// A curved stroke through one control point, running through three colours: `start`, then `middle`
    /// at the fraction `at`, then `end`. The curve itself is shaped on the GPU.
    func curve(_ p0: CGPoint, _ control: CGPoint, _ p1: CGPoint, width: Double, _ start: RGBA, _ middle: RGBA, _ end: RGBA, at: Double = 0.5) {
        guard state.opacity > 0.002, width > 0 else { return }
        let a = map(p0.x, p0.y), c = map(control.x, control.y), b = map(p1.x, p1.y)
        shapes.append(Shape(place: SIMD4(Float(a.0), Float(a.1), Float(c.0), Float(c.1)),
                            extent: SIMD4(Float(b.0), Float(b.1), Float(max(0.5, width / 2 * unit)), 0),
                            first: premultiplied(start), second: premultiplied(middle),
                            kind: SIMD4(5, Float(unit), 0, 0), more: SIMD4(Float(at), 0, 0, 0), uv: .zero, spare: premultiplied(end)))
        batch(.curves, count: 1, start: shapes.count - 1)
    }

    /// A mesh that never changes shape, kept on the GPU under a name. `build` runs only the first time.
    /// It is drawn with the current transform, opacity and blend, so it can still move and fade.
    func stored(_ key: String, build: () -> [(Double, Double, RGBA)]) {
        guard state.opacity > 0.002 else { return }
        let name = key + (state.additive ? "+" : "")
        if !isStored(name), pending[name] == nil {
            pending[name] = build().map { corner in
                let c = corner.2
                return Point(position: SIMD2(Float(corner.0), Float(corner.1)), spare: .zero,
                             colour: SIMD4(c.r * c.a, c.g * c.a, c.b * c.a, state.additive ? 0 : c.a))
            }
        }
        var made = Batch(kind: .stored(name), additive: state.additive, clip: state.clip, start: 0, count: 0)
        made.transform = (state.a, state.b, state.c, state.d, state.tx, state.ty)
        made.tint = Float(state.opacity)
        batches.append(made)
    }

    /// Plain triangles, three corners at a time.
    func mesh(_ corners: [(Double, Double, RGBA)]) {
        guard !corners.isEmpty, state.opacity > 0.002 else { return }
        let start = points.count
        for corner in corners {
            let p = map(corner.0, corner.1)
            points.append(Point(position: SIMD2(Float(p.0), Float(p.1)), spare: .zero, colour: premultiplied(corner.2)))
        }
        batch(.mesh, count: corners.count, start: start)
    }

    // MARK: Photos and text

    private func textured(_ entry: Atlas.Entry, x: Double, y: Double, halfWidth: Double, halfHeight: Double, angle: Double = 0, tint: RGBA, photo: Bool, circular: Bool) {
        quad(x: x, y: y, halfWidth: halfWidth, halfHeight: halfHeight, angle: angle, first: tint, type: 4, photo ? 1 : 0, circular ? 1 : 0,
             more: SIMD4(Float(min(halfWidth, halfHeight)), 0, 0, 0), uv: SIMD4(entry.u0, entry.v0, entry.u1, entry.v1), padded: false)
    }

    /// A photo cut to a circle.
    func photo(_ key: String, _ image: CGImage, x: Double, y: Double, r: Double) {
        guard let entry = atlas.image(key, image) else { return }
        textured(entry, x: x, y: y, halfWidth: r, halfHeight: r, tint: .white, photo: true, circular: true)
    }

    /// The figure shown for someone with no photo.
    func figure(_ x: Double, _ y: Double, _ r: Double, _ colour: RGBA) {
        guard let entry = atlas.figure() else { return }
        textured(entry, x: x, y: y, halfWidth: r, halfHeight: r, tint: colour, photo: false, circular: true)
    }

    func measure(_ string: String, _ style: TextStyle) -> CGSize { atlas.measure(string, style) }

    /// One line of text. `halo` draws a soft edge of another colour behind it so it reads over anything.
    func text(_ string: String, _ x: Double, _ y: Double, _ style: TextStyle, _ colour: RGBA, anchor: Anchor = .centre, halo: RGBA? = nil, angle: Double = 0) {
        guard !string.isEmpty, colour.a > 0, state.opacity > 0.002, let entry = atlas.text(string, style, scale: unit) else { return }
        let hw = entry.width / 2, hh = entry.height / 2
        // Where the middle of the text sits relative to the anchor point, before turning.
        var ox = 0.0, oy = 0.0
        switch anchor {
        case .centre: break
        case .top: oy = hh
        case .bottom: oy = -hh
        case .leading: ox = hw
        case .trailing: ox = -hw
        case .bottomLeading: ox = hw; oy = -hh
        case .topLeading: ox = hw; oy = hh
        }
        let co = cos(angle), si = sin(angle)
        let cx = x + ox * co - oy * si, cy = y + ox * si + oy * co
        if let halo {
            for k in 0..<8 {
                let a = Double(k) / 8 * 2 * Double.pi
                textured(entry, x: cx + cos(a) * 2.2, y: cy + sin(a) * 2.2, halfWidth: hw, halfHeight: hh, angle: angle, tint: halo, photo: false, circular: false)
            }
        }
        textured(entry, x: cx, y: cy, halfWidth: hw, halfHeight: hh, angle: angle, tint: colour, photo: false, circular: false)
    }
}
