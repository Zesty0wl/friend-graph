import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Metal

/// Turns a picture into something to share: a PNG, or a short video. Everything is rendered on
/// this Mac from a fresh copy of the scene, with the privacy choices from the share sheet applied.
@MainActor
enum Exporter {
    struct Request: Equatable {
        var tab: Tab
        var names: NameStyle = .initials
        var photos = false
        var tall = false
        /// For a video: how many seconds to make. Nil means the whole story.
        var videoLimit: Double?
        /// When the video is shorter than the story: keep the most recent part, or the beginning.
        var keepRecent = true
        var size: CGSize { tall ? CGSize(width: 1080, height: 1920) : CGSize(width: 1080, height: 1080) }
        var options: DrawOptions { DrawOptions(names: names, photos: photos) }
    }

    /// Paints the finished card: the picture, its title, and the app's name.
    static func paintCard(_ p: Painter, scene: any VisualScene, request: Request) {
        let size = request.size, caption = request.tall ? 300.0 : 150.0
        let area = request.tall ? size.width : size.height - caption
        let top = request.tall ? (size.height - area - caption) / 2 : 0
        let design = scene.designSize, scale = min(size.width / design.width, area / design.height)
        p.save()
        p.translate((size.width - design.width * scale) / 2, top + (area - design.height * scale) / 2)
        p.scale(scale)
        p.clip(CGRect(origin: .zero, size: design))
        scene.paint(p, request.options)
        p.restore()

        // The title, on two lines if it will not fit on one.
        let style = TextStyle.serif(request.tall ? 76 : 54), room = size.width - 112
        var lines: [String] = [], current = ""
        for word in SceneBuilder.title(request.tab).split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if p.measure(candidate, style).width > room, !current.isEmpty { lines.append(current); current = word } else { current = candidate }
        }
        if !current.isEmpty { lines.append(current) }
        let lineHeight = style.size * 1.14
        var y = top + area + (lines.count > 1 && !request.tall ? -lineHeight * 0.55 : 0)
        for line in lines { p.text(line, 56, y, style, Pal.paper.c(), anchor: .topLeading); y += lineHeight }
        p.text("FRIEND GRAPH", 56, y + 12, .sans(request.tall ? 24 : 19, tracking: 2.4), Pal.quiet.c(), anchor: .topLeading)
    }

    /// Draws one frame on the GPU into a picture of the given size.
    static func render(_ size: CGSize, _ body: (Painter) -> Void) -> MTLTexture? {
        guard let renderer = Renderer.shared, let target = renderer.canvas(width: Int(size.width), height: Int(size.height)) else { return nil }
        let painter = renderer.scratch
        painter.begin(pixels: size)
        body(painter)
        renderer.draw(painter, into: target, wait: true)
        return target
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
        guard let texture = render(request.size, { paintCard($0, scene: scene, request: request) }) else { return nil }
        return Renderer.shared?.image(from: texture)
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FriendGraph-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name).appendingPathExtension(video ? "mp4" : "png")
    }

    enum Failure: LocalizedError {
        case nothingToDraw, writer(String)
        var errorDescription: String? {
            switch self {
            case .nothingToDraw: return "There was nothing to draw."
            case .writer(let why): return why
            }
        }
    }

    /// How long a picture's whole story takes to play, in seconds.
    static func storySeconds(_ tab: Tab, model: AppModel) -> Double {
        SceneBuilder.make(tab, model: model, live: false)?.storySeconds ?? 10
    }

    /// Anything longer than this is awkward to share, so the owner is offered shorter lengths.
    static let comfortableSeconds: Double = {
        // "--comfort 20" lowers the threshold, for checking the long-story choices with a short sample history.
        let args = CommandLine.arguments
        return args.firstIndex(of: "--comfort").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 60
    }()

    /// A video of one picture: its whole story, or the part the owner asked for. Reports progress from 0 to 1.
    static func video(_ request: Request, model: AppModel, seconds limit: Double? = nil, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let scene = SceneBuilder.make(request.tab, model: model, live: false) else { throw Failure.nothingToDraw }
        let seconds = min(scene.storySeconds, limit ?? request.videoLimit ?? scene.storySeconds)
        scene.beginStory(length: seconds, keepingEnd: request.keepRecent)
        let url = temporaryURL(request, video: true), fps = 30
        try await encode(size: request.size, frames: Int(seconds) * fps, fps: fps, to: url, progress: progress) {
            scene.advance(by: 1.0 / Double(fps))
            return render(request.size) { paintCard($0, scene: scene, request: request) }
        }
        return url
    }
}

extension Exporter {
    /// Encodes frames drawn one at a time into an H.264 file.
    static func encode(size: CGSize, frames: Int, fps: Int, to url: URL, progress: @escaping (Double) -> Void, frame: () -> MTLTexture?) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
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
            guard let picture = frame(), let pool = adaptor.pixelBufferPool, let renderer = Renderer.shared else { throw Failure.nothingToDraw }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw Failure.writer("no frame buffer") }
            // The frame is already laid out as the video wants it, so it is copied straight across.
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { renderer.read(picture, into: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
            progress(Double(index + 1) / Double(frames))
            await Task.yield()
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "did not finish") }
    }

    /// Puts the picture and the music into one file.
    static func join(video: URL, audio: URL, into url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let composition = AVMutableComposition()
        // The picture file can take a moment to be finalised on disk after the writer reports it is done.
        var picture = AVURLAsset(url: video), attempt = 0
        while true {
            do { _ = try await picture.load(.duration); break } catch {
                attempt += 1
                if attempt > 12 { throw error }
                try await Task.sleep(for: .milliseconds(400))
                picture = AVURLAsset(url: video)
            }
        }
        let sound = AVURLAsset(url: audio)
        let duration = try await picture.load(.duration)
        guard let videoTrack = try await picture.loadTracks(withMediaType: .video).first,
              let audioTrack = try await sound.loadTracks(withMediaType: .audio).first,
              let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure.writer("could not read the film back") }
        let range = CMTimeRange(start: .zero, duration: duration)
        try videoOut.insertTimeRange(range, of: videoTrack, at: .zero)
        try audioOut.insertTimeRange(range, of: audioTrack, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw Failure.writer("could not join sound and picture") }
        try await session.export(to: url, as: .mp4)
    }

    /// The most recent film made, kept so the self-check can report its timings.
    static var lastFilm: Film?

    /// Makes the whole "My year" film: captions, picture, music. Progress runs from 0 to 1.
    static func film(model: AppModel, narrator: Narrator, answers: Film.Answers, options: DrawOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        let script = Film.script(model: model, answers: answers)
        // Captions first: a sentence each for the three chapters that need one.
        var captions = [String](repeating: "", count: 6)
        // One fact each, so every caption is short enough to take in at a glance.
        captions[2] = await narrator.caption(Array(script.circleFacts.prefix(1)))
        progress(0.03)
        captions[3] = await narrator.caption(Array(script.yearFacts.prefix(1)))
        progress(0.06)
        // Anyone in memory keeps our own plain words; no model writes about them.
        let memory = script.person.map { model.decisions.standing(of: $0) == .inMemory } ?? false
        captions[4] = memory ? "" : await narrator.caption(Array(script.personFacts.prefix(1)))
        progress(0.09)

        let film = Film(model: model, script: script, captions: captions, options: options)
        lastFilm = film
        // A folder of its own for every film, so two windows or two copies of the app can never write over each other.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FriendGraph-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let silent = base.appendingPathComponent("picture.mp4"), music = base.appendingPathComponent("music.m4a")
        let final = base.appendingPathComponent("My year.mp4")
        let frames = Int((film.length * Double(Film.fps)).rounded(.up))
        try await encode(size: Film.size, frames: frames, fps: Film.fps, to: silent, progress: { progress(0.09 + 0.86 * $0) }) {
            film.advance(by: 1.0 / Double(Film.fps))
            return render(Film.size) { film.paint($0) }
        }
        do { try Soundtrack.write(starts: film.starts, length: film.length, cues: film.cues(), to: music) }
        catch { throw Failure.writer("The music could not be made: \(error.localizedDescription)") }
        do { try await join(video: silent, audio: music, into: final) }
        catch { throw Failure.writer("The music could not be added to the picture: \(error.localizedDescription)") }
        try? FileManager.default.removeItem(at: silent)
        try? FileManager.default.removeItem(at: music)
        progress(1)
        return final
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
        if CommandLine.arguments.contains("--videos") {
            for tab in Tab.allCases {
                do {
                    let url = try await Exporter.video(.init(tab: tab, names: open ? .first : .none, photos: open), model: model) { _ in }
                    let target = directory.appendingPathComponent("\(tab.rawValue).mp4")
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: url, to: target)
                    report.append("wrote \(tab.rawValue).mp4")
                } catch { report.append("video FAILED for \(tab.rawValue): \(error)") }
            }
        }
        // How long each picture's story is, and a check that a shortened timeline keeps the right end.
        report.append("story seconds: " + Tab.allCases.map { "\($0.rawValue) \(Int(Exporter.storySeconds($0, model: model)))" }.joined(separator: ", "))
        if CommandLine.arguments.contains("--trim") {
            for recent in [true, false] {
                var request = Exporter.Request(tab: .journey, names: open ? .first : .none, photos: open)
                request.videoLimit = 20; request.keepRecent = recent
                if let url = try? await Exporter.video(request, model: model, progress: { _ in }) {
                    let target = directory.appendingPathComponent(recent ? "journey-recent.mp4" : "journey-beginning.mp4")
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.copyItem(at: url, to: target)
                    report.append("wrote \(target.lastPathComponent)")
                }
            }
        }
        // --film: the "My year" film, with stand-in answers. Made-up people only.
        if CommandLine.arguments.contains("--film"), open {
            do {
                let started = Date()
                let answers = Film.Answers(word: "Steady", thanks: model.circlePeople.dropFirst(4).first?.id, moment: "A week by the sea in June with everyone together")
                let url = try await Exporter.film(model: model, narrator: narrator, answers: answers, options: DrawOptions(names: .full, photos: true, everyoneNamed: true)) { _ in }
                let target = directory.appendingPathComponent("my-year.mp4")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
                report.append("wrote my-year.mp4 in \(Int(Date().timeIntervalSince(started)))s")
                if let made = Exporter.lastFilm {
                    report.append("film length: \(String(format: "%.1f", made.length))s, chapters start at " + made.starts.map { String(format: "%.1f", $0) }.joined(separator: ", "))
                    for i in [2, 3, 4] {
                        let end = i + 1 < made.starts.count ? made.starts[i + 1] : made.length
                        let shown = [0, 0, Film.captionDelay(made.arrivals), Film.busiestCaption, Film.personCaption][i]
                        report.append("caption \(i): \(made.captions[i].split(separator: " ").count) words, on screen \(String(format: "%.1f", end - made.starts[i] - shown))s: \(made.captions[i])")
                    }
                }
            } catch { report.append("film FAILED: \(error)") }
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
