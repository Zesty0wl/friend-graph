import SwiftUI
import MetalKit

/// Hosts one picture in the window, drawn on the GPU every frame, and passes the pointer through to it.
struct MetalSceneView: NSViewRepresentable {
    let scene: any VisualScene
    var options = DrawOptions(names: .first, photos: true)
    /// Called after any pointer event, so the side panel can follow the selection.
    var onInteraction: () -> Void = {}

    func makeNSView(context: Context) -> SceneSurface {
        let surface = SceneSurface(frame: .zero, device: Renderer.shared?.device)
        surface.scene = scene; surface.options = options; surface.onInteraction = onInteraction
        return surface
    }

    func updateNSView(_ surface: SceneSurface, context: Context) {
        surface.scene = scene; surface.options = options; surface.onInteraction = onInteraction
    }
}

final class SceneSurface: MTKView, MTKViewDelegate {
    var scene: (any VisualScene)?
    var options = DrawOptions()
    var onInteraction: () -> Void = {}
    private var lastFrame: CFTimeInterval?
    private var painter: Painter?
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        colorPixelFormat = Renderer.format
        clearColor = MTLClearColor(red: Pal.ground.r / 255, green: Pal.ground.g / 255, blue: Pal.ground.b / 255, alpha: 1)
        framebufferOnly = true
        preferredFramesPerSecond = 60
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.isOpaque = true
        delegate = self
        painter = Renderer.shared?.painter()
        // Nothing moves while another app is in front.
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPaused = true }
        })
        observers.append(centre.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastFrame = nil; self?.isPaused = false }
        })
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    /// How the picture sits in the view: pixels per design unit, and the offset of its top-left corner in pixels.
    private var fit: (scale: Double, x: Double, y: Double) {
        guard let design = scene?.designSize else { return (1, 0, 0) }
        let scale = min(drawableSize.width / design.width, drawableSize.height / design.height)
        return (scale, (drawableSize.width - design.width * scale) / 2, (drawableSize.height - design.height * scale) / 2)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let scene, let painter, let renderer = Renderer.shared, let drawable = currentDrawable, drawableSize.width > 1 else { return }
        let now = CACurrentMediaTime()
        let step = lastFrame.map { min(0.05, max(0, now - $0)) } ?? 1.0 / 60
        lastFrame = now
        scene.advance(by: step)
        let placed = fit
        painter.begin(pixels: drawableSize)
        painter.translate(placed.x, placed.y)
        painter.scale(placed.scale)
        painter.clip(CGRect(origin: .zero, size: scene.designSize))
        scene.paint(painter, options)
        renderer.draw(painter, into: drawable.texture, present: drawable)
    }

    // MARK: Pointer

    private func design(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), placed = fit
        let density = bounds.width > 0 ? drawableSize.width / bounds.width : 1
        return CGPoint(x: (point.x * density - placed.x) / placed.scale, y: (point.y * density - placed.y) / placed.scale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) { scene?.pointerDown(design(event)); scene?.pointerMoved(design(event)); onInteraction() }
    override func mouseDragged(with event: NSEvent) { scene?.pointerMoved(design(event)); onInteraction() }
    override func mouseUp(with event: NSEvent) { scene?.pointerUp(design(event)); onInteraction() }
    override func mouseMoved(with event: NSEvent) { scene?.hover(design(event)); onInteraction() }
    override func mouseExited(with event: NSEvent) { scene?.hover(nil); onInteraction() }
}
