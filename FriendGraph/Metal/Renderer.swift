import Metal
import CoreGraphics
import QuartzCore

/// Draws a painter's frame on the GPU, either into a window or into a picture for saving.
/// One of these is shared by the whole app.
@MainActor
final class Renderer {
    static let shared = Renderer()

    let device: MTLDevice
    let atlas: Atlas
    private let queue: MTLCommandQueue
    private let shapePipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let curvePipeline: MTLRenderPipelineState
    /// Meshes kept on the GPU between frames, by name.
    private var stored: [String: (MTLBuffer, Int)] = [:]
    private let sampler: MTLSamplerState
    static let format = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let atlas = Atlas(device: device) else { return nil }
        self.device = device; self.queue = queue; self.atlas = atlas
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                let c = d.colorAttachments[0]!
                c.pixelFormat = Self.format
                // Colours arrive premultiplied, so "over" is one plus one-minus-alpha. Additive light is the same
                // blend with alpha zero.
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            shapePipeline = try pipeline("shape_vertex", "shape_fragment")
            meshPipeline = try pipeline("mesh_vertex", "mesh_fragment")
            curvePipeline = try pipeline("curve_vertex", "curve_fragment")
        } catch {
            NSLog("Friend Graph could not prepare its shaders: \(error)")
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear; s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else { return nil }
        self.sampler = sampler
    }

    func painter() -> Painter {
        let made = Painter(atlas: atlas)
        made.isStored = { [weak self] in self?.stored[$0] != nil }
        return made
    }
    /// A painter for one-off pictures and film frames.
    private(set) lazy var scratch = painter()

    /// Draws everything the painter collected into `target`, clearing it to the ground colour first.
    @discardableResult
    func draw(_ painter: Painter, into target: MTLTexture, present drawable: (any MTLDrawable)? = nil, wait: Bool = false) -> Bool {
        guard let buffer = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Pal.ground.r / 255, green: Pal.ground.g / 255, blue: Pal.ground.b / 255, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }

        // Anything asked for by name that is not on the GPU yet goes up now, once.
        for (name, points) in painter.pending where !points.isEmpty {
            if stored.count > 96 { stored.removeAll() }
            if let made = points.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) {
                stored[name] = (made, points.count)
            }
        }
        struct Frame { var size: SIMD4<Float>; var across: SIMD4<Float>; var down: SIMD4<Float>; var tint: SIMD4<Float> }
        let plain = Frame(size: SIMD4(Float(target.width), Float(target.height), 0, 0), across: SIMD4(1, 0, 0, 0), down: SIMD4(0, 1, 0, 0), tint: SIMD4(repeating: 1))
        let shapes = painter.shapes.isEmpty ? nil : painter.shapes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        let points = painter.points.isEmpty ? nil : painter.points.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let full = MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height)
        let stride = MemoryLayout<Painter.Shape>.stride, frameSize = MemoryLayout<Frame>.stride
        for batch in painter.batches {
            var scissor = full
            if let clip = batch.clip {
                let x0 = max(0, Int(clip.minX.rounded())), y0 = max(0, Int(clip.minY.rounded()))
                let x1 = min(target.width, Int(clip.maxX.rounded())), y1 = min(target.height, Int(clip.maxY.rounded()))
                guard x1 > x0, y1 > y0 else { continue }
                scissor = MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
            encoder.setScissorRect(scissor)
            var frame = plain
            switch batch.kind {
            case .mesh:
                guard let points else { continue }
                encoder.setRenderPipelineState(meshPipeline)
                encoder.setVertexBuffer(points, offset: 0, index: 0)
                encoder.setVertexBytes(&frame, length: frameSize, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: batch.start, vertexCount: batch.count)
            case .stored(let name):
                guard let (mesh, count) = stored[name] else { continue }
                let t = batch.transform
                frame.across = SIMD4(Float(t.0), Float(t.2), Float(t.4), 0)
                frame.down = SIMD4(Float(t.1), Float(t.3), Float(t.5), 0)
                frame.tint = SIMD4(batch.tint, batch.tint, batch.tint, batch.tint)
                encoder.setRenderPipelineState(meshPipeline)
                encoder.setVertexBuffer(mesh, offset: 0, index: 0)
                encoder.setVertexBytes(&frame, length: frameSize, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
            case .shapes:
                guard let shapes else { continue }
                encoder.setRenderPipelineState(shapePipeline)
                encoder.setVertexBuffer(shapes, offset: batch.start * stride, index: 0)
                encoder.setVertexBytes(&frame, length: frameSize, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: batch.count)
            case .curves:
                guard let shapes else { continue }
                encoder.setRenderPipelineState(curvePipeline)
                encoder.setVertexBuffer(shapes, offset: batch.start * stride, index: 0)
                encoder.setVertexBytes(&frame, length: frameSize, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 50, instanceCount: batch.count)
            }
        }
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        buffer.commit()
        if wait { buffer.waitUntilCompleted() }
        return true
    }

    // MARK: Pictures for saving

    private var canvases: [String: MTLTexture] = [:]

    /// A texture to draw a saved picture or a film frame into. Reused between frames of the same size.
    func canvas(width: Int, height: Int) -> MTLTexture? {
        let key = "\(width)x\(height)"
        if let made = canvases[key] { return made }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.format, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let made = device.makeTexture(descriptor: d)
        canvases[key] = made
        return made
    }

    /// Copies a finished canvas into memory laid out as BGRA, as video and image files expect.
    func read(_ texture: MTLTexture, into bytes: UnsafeMutableRawPointer, bytesPerRow: Int) {
        texture.getBytes(bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }

    func image(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height, row = w * 4
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        read(texture, into: data, bytesPerRow: row)
        return context.makeImage()
    }
}
