import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Turns a picture into something to share: a PNG, or a short video. Everything is rendered on
/// this Mac from a fresh copy of the scene, with the privacy choices from the share sheet applied.
@MainActor
enum Exporter {
    struct Request: Equatable {
        var tab: Tab
        var names: NameStyle = .initials
        var photos = false
        var tall = false
        var size: CGSize { tall ? CGSize(width: 1080, height: 1920) : CGSize(width: 1080, height: 1080) }
        var options: DrawOptions { DrawOptions(names: names, photos: photos) }
    }

    /// The finished card: the picture, its title, and the app's name.
    struct Card: View {
        let scene: any VisualScene
        let request: Request

        var body: some View {
            let size = request.size, caption = request.tall ? 300.0 : 150.0
            VStack(spacing: 0) {
                if request.tall { Spacer(minLength: 0) }
                Canvas { context, area in
                    let design = scene.designSize, scale = min(area.width / design.width, area.height / design.height)
                    context.translateBy(x: (area.width - design.width * scale) / 2, y: (area.height - design.height * scale) / 2)
                    context.scaleBy(x: scale, y: scale)
                    context.clip(to: Path(CGRect(origin: .zero, size: design)))
                    scene.draw(&context, request.options)
                }
                .frame(width: size.width, height: request.tall ? size.width : size.height - caption)
                VStack(alignment: .leading, spacing: 10) {
                    Text(SceneBuilder.title(request.tab))
                        .font(serif(request.tall ? 76 : 54)).foregroundStyle(Pal.paper.color())
                        .lineLimit(2).minimumScaleFactor(0.6)
                    Text("FRIEND GRAPH")
                        .font(sans(request.tall ? 24 : 19)).tracking(2.4).foregroundStyle(Pal.quiet.color())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 56)
                .frame(height: caption, alignment: .top)
                if request.tall { Spacer(minLength: 0) }
            }
            .frame(width: size.width, height: size.height)
            .background(Pal.ground.color())
        }
    }

    /// A fresh scene, moved on to the moment worth showing.
    static func scene(for request: Request, model: AppModel, settle: Double) -> (any VisualScene)? {
        guard let scene = SceneBuilder.make(request.tab, model: model, live: false) else { return nil }
        if let journey = scene as? JourneyScene { journey.jump(secondsBeforeEnd: settle + 0.05) }
        var t = 0.0
        while t < settle { scene.advance(by: 1.0 / 60); t += 1.0 / 60 }
        return scene
    }

    static func frame(_ scene: any VisualScene, _ request: Request) -> CGImage? {
        let renderer = ImageRenderer(content: Card(scene: scene, request: request))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage
    }

    static func picture(_ request: Request, model: AppModel) -> CGImage? {
        scene(for: request, model: model, settle: 9).flatMap { frame($0, request) }
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func temporaryURL(_ request: Request, video: Bool) -> URL {
        let name = SceneBuilder.title(request.tab).replacingOccurrences(of: ",", with: "")
        return FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension(video ? "mp4" : "png")
    }

    enum Failure: Error { case nothingToDraw, writer(String) }

    /// Ten seconds at 30 frames a second. Reports progress from 0 to 1.
    static func video(_ request: Request, model: AppModel, seconds: Double = 10, progress: @escaping (Double) -> Void) async throws -> URL {
        // The circle opens with everyone blooming out from the centre, which is worth keeping in a video.
        guard let scene = scene(for: request, model: model, settle: request.tab == .journey ? seconds : 0.6) else { throw Failure.nothingToDraw }
        if let journey = scene as? JourneyScene { journey.jump(secondsBeforeEnd: seconds + 0.05) }
        let url = temporaryURL(request, video: true)
        try? FileManager.default.removeItem(at: url)
        let size = request.size, fps = 30, frames = Int(seconds) * fps
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 9_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "could not start") }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frames {
            try Task.checkCancellation()
            scene.advance(by: 1.0 / Double(fps))
            guard let image = frame(scene, request), let pool = adaptor.pixelBufferPool else { throw Failure.nothingToDraw }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw Failure.writer("no frame buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
            progress(Double(index + 1) / Double(frames))
            await Task.yield()
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "did not finish") }
        return url
    }
}

/// Renders every picture to a folder and quits. Used to check the app's output without clicking
/// through it:  "Friend Graph" --snapshot /some/folder [--real] [--video]
@MainActor
enum Snapshot {
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--snapshot"), at + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[at + 1], isDirectory: true)
    }

    static func run(into directory: URL, model: AppModel) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String] = []
        if CommandLine.arguments.contains("--real") {
            do {
                model.dataset = try GraphReader.load()
                model.decisions = Decisions()
            } catch { report.append("real data failed: \(error)") }
        }
        if model.dataset == nil { model.useSample() }
        guard let data = model.dataset else { return }
        report.append("sample: \(data.isSample), scored: \(data.scored.count), earlier: \(data.earlier.count), others: \(data.othersKnown), days: \(data.days), watch views: \(data.watch?.views.count ?? 0)")
        report.append("with photo: \(data.scored.filter { $0.photo != nil }.count) of \(data.scored.count)")
        report.append("guesses for the ten closest: " + data.scored.prefix(10).map { $0.guess.rawValue }.joined(separator: ", "))
        report.append("messages for the ten closest: " + data.scored.prefix(10).map { String($0.messages) }.joined(separator: ", "))
        report.append("notes: \(data.notes)")
        // Names are only drawn for made-up people; real runs are written with names and photos hidden.
        let open = data.isSample
        for tab in Tab.allCases {
            for tall in [false, true] {
                let request = Exporter.Request(tab: tab, names: open ? .first : .none, photos: open, tall: tall)
                if let image = Exporter.picture(request, model: model), let png = Exporter.png(image) {
                    let name = "\(tab.rawValue)\(tall ? "-tall" : "").png"
                    try? png.write(to: directory.appendingPathComponent(name))
                    report.append("wrote \(name) \(image.width)x\(image.height)")
                } else { report.append("FAILED \(tab.rawValue) tall=\(tall)") }
            }
        }
        if open, let circle = Exporter.scene(for: .init(tab: .circle), model: model, settle: 9) as? CircleScene {
            report.append("ring speeds (radians a second): " + circle.ringSpeeds.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            circle.select(index: 2)
            for _ in 0..<40 { circle.advance(by: 1.0 / 60) }
            report.append("detail: \(circle.detail?.title ?? "none") | \(circle.detail?.subtitle ?? "") | \(circle.detail?.rows.map { $0.label + "=" + $0.value } ?? [])")
            report.append("footer: \(circle.footer)")
            if let image = Exporter.frame(circle, .init(tab: .circle, names: .initials, photos: false)), let png = Exporter.png(image) {
                try? png.write(to: directory.appendingPathComponent("circle-private-selected.png"))
            }
        }
        // The on-device model: is it there, and what does it write from the facts?
        let narrator = Narrator()
        report.append("model available: \(narrator.isAvailable) \(narrator.unavailableReason ?? "")")
        var panels: [Panel] = Tab.allCases.compactMap { Insights.overview($0, model: model) }
        if open, let someone = model.circlePeople.dropFirst(4).first, let made = Insights.person(someone, subtitle: "", model: model) { panels.append(made) }
        for panel in panels {
            let started = Date()
            await narrator.write(panel)
            report.append("--- \(panel.title) (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
            report.append("stats: " + panel.stats.map { "\($0.value) \($0.label)" }.joined(separator: " | "))
            if open { report.append("facts: " + panel.facts.joined(separator: " ")) }
            if open { report.append("fallback: " + panel.fallback) }
            report.append("story: " + (open ? (panel.storyKey.flatMap { narrator.stories[$0] } ?? "(none written)") : (panel.storyKey.flatMap { narrator.stories[$0] } == nil ? "(none written)" : "(written, not shown for real data)")))
        }
        // --videos: a short film of every picture, for the README. Made-up people only.
        if CommandLine.arguments.contains("--videos"), open {
            for tab in Tab.allCases {
                do {
                    let url = try await Exporter.video(.init(tab: tab, names: .first, photos: true), model: model, seconds: 8) { _ in }
                    let target = directory.appendingPathComponent("\(tab.rawValue).mp4")
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: url, to: target)
                    report.append("wrote \(tab.rawValue).mp4")
                } catch { report.append("video FAILED for \(tab.rawValue): \(error)") }
            }
        }
        if CommandLine.arguments.contains("--video") {
            do {
                let url = try await Exporter.video(.init(tab: .circle, names: open ? .first : .none, photos: open), model: model, seconds: 3) { _ in }
                let target = directory.appendingPathComponent("circle.mp4")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
                let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
                report.append("wrote circle.mp4 \(size) bytes")
            } catch { report.append("video FAILED: \(error)") }
        }
        try? report.joined(separator: "\n").write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
