import SwiftUI

/// Hosts one picture: draws it every frame, scaled to fit, and passes the pointer through.
struct SceneCanvas: View {
    let scene: any VisualScene
    var options = DrawOptions(names: .first, photos: true)
    /// Called after any pointer event, so the side panel can follow the selection.
    var onInteraction: () -> Void = {}

    @State private var pressed = false
@Environment(\.controlActiveState) private var activity

    var body: some View {
        GeometryReader { geo in
            let design = scene.designSize
            let scale = min(geo.size.width / design.width, geo.size.height / design.height)
            let origin = CGPoint(x: (geo.size.width - design.width * scale) / 2, y: (geo.size.height - design.height * scale) / 2)
            let toDesign: (CGPoint) -> CGPoint = { p in CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
            // Redraw no faster than the picture needs, and not at all while another app is in front.
            TimelineView(.animation(minimumInterval: 1.0 / scene.framesPerSecond, paused: activity == .inactive)) { timeline in
                Canvas(opaque: true) { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Pal.ground.color()))
                    let stepper = FrameStepper.shared
                    scene.advance(by: stepper.step(for: ObjectIdentifier(scene), at: timeline.date))
                    context.translateBy(x: origin.x, y: origin.y)
                    context.scaleBy(x: scale, y: scale)
                    context.clip(to: Path(CGRect(origin: .zero, size: design)))
                    scene.draw(&context, options)
                }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !pressed { pressed = true; scene.pointerDown(toDesign(value.startLocation)) }
                    scene.pointerMoved(toDesign(value.location))
                    onInteraction()
                }
                .onEnded { value in
                    pressed = false
                    scene.pointerUp(toDesign(value.location))
                    onInteraction()
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): scene.hover(toDesign(p))
                case .ended: scene.hover(nil)
                }
                onInteraction()
            }
        }
    }
}

/// Remembers when each scene was last drawn, so motion runs on real time whatever the frame rate.
@MainActor
final class FrameStepper {
    static let shared = FrameStepper()
    private var last: [ObjectIdentifier: Date] = [:]
    func step(for id: ObjectIdentifier, at date: Date) -> Double {
        defer { last[id] = date }
        guard let previous = last[id] else { return 1.0 / 60 }
        return min(0.05, max(0, date.timeIntervalSince(previous)))
    }
    func forget(_ id: ObjectIdentifier) { last[id] = nil }
}
