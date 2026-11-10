import AVFoundation

/// The film's music, made from scratch so there is nothing to license: a slow warm pad that changes
/// chord with each chapter, and a plucked note at the instant each thing appears on screen.
/// Everything is simple sine waves.
enum Soundtrack {
    static let sampleRate = 44_100.0

    /// One chord per chapter, low to high, as MIDI note numbers. Ends by coming home to C.
    static let chords: [[Int]] = [
        [48, 55, 64, 71, 74],     // C major 9
        [45, 52, 60, 67, 71],     // A minor 9
        [41, 48, 57, 64, 67],     // F major 9
        [43, 50, 59, 62, 69],     // G add 9
        [45, 52, 60, 64, 71],     // A minor 9
        [48, 55, 64, 67, 74],     // C, home
    ]

    private static func frequency(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }

    /// Mono samples for a film with chapters starting at `starts` and ending at `length` seconds.
    static func samples(starts: [Double], length: Double, cues: [Film.Cue]) -> [Float] {
        let count = Int(length * sampleRate)
        var out = [Float](repeating: 0, count: count)
        func add(_ note: Int, from start: Double, to end: Double, attack: Double, release: Double, level: Double, detune: Double = 0) {
            let f = frequency(note) * (1 + detune), first = max(0, Int(start * sampleRate)), last = min(count, Int((end + release) * sampleRate))
            guard first < last else { return }
            for i in first..<last {
                let t = Double(i) / sampleRate - start
                var envelope = min(1, t / attack)
                if t > end - start { envelope *= max(0, 1 - (t - (end - start)) / release) }
                // a little second and third harmonic keeps it from sounding like a test tone
                let wave = sin(2 * .pi * f * t) + 0.22 * sin(4 * .pi * f * t) + 0.08 * sin(6 * .pi * f * t)
                out[i] += Float(wave * envelope * envelope * level)
            }
        }
        func pluck(_ note: Int, at start: Double, level: Double) {
            let f = frequency(note), first = max(0, Int(start * sampleRate)), last = min(count, first + Int(1.6 * sampleRate))
            guard first < last else { return }
            for i in first..<last {
                let t = Double(i) / sampleRate - start
                out[i] += Float(sin(2 * .pi * f * t) * exp(-t * 3.2) * min(1, t / 0.008) * level)
            }
        }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : length
            let chord = chords[index % chords.count]
            for (k, note) in chord.enumerated() {
                let level = k == 0 ? 0.09 : 0.045
                add(note, from: start, to: end, attack: 1.3, release: 1.6, level: level, detune: 0.0015)
                add(note, from: start, to: end, attack: 1.3, release: 1.6, level: level, detune: -0.0015)
            }
        }
        // One plucked note for each thing that appears, taken from the chord of the chapter it falls in.
        for cue in cues {
            let chapter = starts.lastIndex { $0 <= cue.time + 0.001 } ?? 0
            let chord = chords[chapter % chords.count]
            let note = chord[cue.step % chord.count] + 12 * (cue.step / chord.count) + 12
            pluck(note, at: cue.time + 0.03, level: 0.12 * cue.level)
            pluck(note + 12, at: cue.time + 0.03, level: 0.03 * cue.level)        // a little sparkle an octave up
        }
        // A simple echo for some space, then fades at both ends.
        let delay = Int(0.36 * sampleRate)
        if count > delay { for i in delay..<count { out[i] += out[i - delay] * 0.18 } }
        let fadeIn = Int(1.0 * sampleRate), fadeOut = Int(3.2 * sampleRate)
        for i in 0..<min(fadeIn, count) { out[i] *= Float(i) / Float(fadeIn) }
        for i in 0..<min(fadeOut, count) { out[count - 1 - i] *= Float(i) / Float(fadeOut) }
        let peak = out.map { abs($0) }.max() ?? 1
        if peak > 0.89 { for i in out.indices { out[i] *= 0.89 / peak } }
        return out
    }

    /// Writes the music as an AAC file ready to sit alongside the picture.
    static func write(starts: [Double], length: Double, cues: [Film.Cue], to url: URL) throws {
        let mono = samples(starts: starts, length: length, cues: cues)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count)),
              let channels = buffer.floatChannelData else { throw Exporter.Failure.writer("could not make the soundtrack") }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        // The echo is offset a touch on the right, which is enough to open the sound out.
        let offset = Int(0.011 * sampleRate)
        for i in mono.indices {
            channels[0][i] = mono[i]
            channels[1][i] = i >= offset ? 0.7 * mono[i] + 0.3 * mono[i - offset] : mono[i]
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
        ])
        try file.write(from: buffer)
    }
}
