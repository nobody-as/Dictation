import AVFoundation
import Foundation

@main
struct SessionTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() throws {
        try queueOrderingAndRetry()
        try audioHandoff()
        try failedRotationKeepsRecording()
        try concurrentHandoff()
        print("PASS: session ordering, retries, stale callbacks, audio handoff and file isolation")
    }

    static func queueOrderingAndRetry() throws {
        let queue = DictationSessionQueue<String>()
        typealias Completion = (Result<String, Error>) -> Void
        var finishes: [Completion] = []
        var updates: [(DictationSessionQueue<String>.State) -> Void] = []
        var started: [Int] = []
        queue.process = { session, update, completion in
            started.append(session.number)
            finishes.append(completion)
            updates.append(update)
        }
        for i in 1...3 {
            queue.enqueue(audioURL: URL(fileURLWithPath: "/synthetic/\(i).wav"), destination: "target \(i)")
        }
        expect(started == [1], "Only one session may process at a time")
        expect(queue.pendingCount == 3, "Recordings can queue while the first result is pending")
        expect(queue.sessions.map(\.destination) == ["target 1", "target 2", "target 3"], "Independent destinations")
        updates[0](.formatting)
        finishes[0](.success("First notes"))
        expect(started == [1, 2], "Formatting/delivery must finish before starting the next result")
        let failure = NSError(domain: "Synthetic", code: 1)
        finishes[1](.failure(failure))
        expect(started == [1, 2, 3], "A failed session must not block newer sessions")
        queue.retry(queue.sessions[1])
        queue.retry(queue.sessions[1])
        finishes[2](.success(""))
        expect(started == [1, 2, 3, 2], "Retry should enqueue exactly once")
        finishes[1](.success("Stale response"))
        updates[1](.completed)
        expect(queue.sessions[1].state == .transcribing, "Old callbacks cannot complete a retry")
        finishes[3](.success("Recovered notes"))
        expect(queue.pendingCount == 0, "All jobs finished")
        expect(queue.sessions[0].notes == "First notes", "Earlier notes remain available")
        expect(queue.sessions[1].notes == "Recovered notes", "Retry preserves session identity")
        expect(queue.sessions[2].state == .noSpeech, "Silence completes without insertion")
    }

    static func audioHandoff() throws {
        // Synthetic PCM only. No AVAudioEngine, microphone, network, clipboard or app startup.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: false)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationSynthetic-\(UUID())")
        let split = try AudioSegmentWriter(inputFormat: format, directory: root.appendingPathComponent("split"))
        let whole = try AudioSegmentWriter(inputFormat: format, directory: root.appendingPathComponent("whole"))
        var urls: [URL] = []
        for index in 0..<120 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            for channel in 0..<2 {
                for frame in 0..<480 {
                    buffer.floatChannelData![channel][frame] = Float(sin(Double(index * 480 + frame) * 0.03)) * 0.5
                }
            }
            try split.append(buffer)
            try whole.append(buffer)
            if [20, 21, 50, 85].contains(index) { urls.append(try split.rotate()) }
        }
        urls.append(split.stop()!)
        let wholeURL = whole.stop()!

        let combined = try urls.flatMap { try readSamples($0) }
        let original = try readSamples(wholeURL)
        expect(combined == original, "Splits must not lose, repeat or reorder samples")
        expect(combined.count == 19_200, "Final stop must drain the converter and preserve the full duration")
        expect(Set(urls).count == 5, "Every segment needs an independent filename")
        let oldBytes = try Data(contentsOf: urls[0])
        let other = try AudioSegmentWriter(inputFormat: format, directory: root.appendingPathComponent("other"))
        _ = other.stop()
        expect(tryData(urls[0]) == oldBytes, "Starting another session cannot overwrite a previous WAV")
        print("Verified \(combined.count) synthesized samples across \(urls.count) segments")
    }

    static func failedRotationKeepsRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationSyntheticFailure-\(UUID())")
        let directory = root.appendingPathComponent("audio")
        let moved = root.appendingPathComponent("temporarily-unavailable")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let writer = try AudioSegmentWriter(inputFormat: format, directory: directory)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.25 }
        try writer.append(buffer)
        // Make only this synthetic destination unavailable, simulating file creation failure.
        try FileManager.default.moveItem(at: directory, to: moved)
        var failed = false
        do { _ = try writer.rotate() } catch { failed = true }
        try FileManager.default.moveItem(at: moved, to: directory)
        expect(failed, "Rotation must report an unavailable destination")
        try writer.append(buffer)
        let url = writer.stop()!
        let file = try AVAudioFile(forReading: url)
        expect(file.length == 3200, "Failed rotation must preserve the original file and continued capture")
        expect(writer.stop() == nil, "Repeated stop must be harmless")
    }

    static func concurrentHandoff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationSyntheticConcurrent-\(UUID())")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let split = try AudioSegmentWriter(inputFormat: format, directory: root.appendingPathComponent("split"))
        let whole = try AudioSegmentWriter(inputFormat: format, directory: root.appendingPathComponent("whole"))
        let group = DispatchGroup()
        let began = DispatchSemaphore(value: 0)
        group.enter()
        DispatchQueue(label: "synthetic-audio-tap").async {
            defer { group.leave() }
            for index in 0..<500 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
                buffer.frameLength = 160
                for frame in 0..<160 {
                    buffer.floatChannelData![0][frame] = Float(sin(Double(index * 160 + frame) * 0.05)) * 0.5
                }
                do {
                    try split.append(buffer)
                    try whole.append(buffer)
                } catch { fatalError("Synthetic write failed: \(error)") }
                if index == 0 { began.signal() }
            }
        }
        began.wait()
        var urls: [URL] = []
        for _ in 0..<30 { urls.append(try split.rotate()) }
        group.wait()
        urls.append(split.stop()!)
        let original = whole.stop()!

        let combined = try urls.flatMap { try readSamples($0) }
        let uninterrupted = try readSamples(original)

        expect(combined == uninterrupted && combined.count == 80_000,
               "Concurrent writing and rapid rotation must preserve every sample exactly once")
        print("Verified 80,000 samples during concurrent writes and 30 rotations")
    }

    static func readSamples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1,
               "Both speech backends require 16 kHz mono WAV")
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var result: [Int16] = []
        // A successful AVAudioFile read can return fewer frames than requested.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            result.append(contentsOf: UnsafeBufferPointer(start: buffer.int16ChannelData![0],
                                                          count: Int(buffer.frameLength)))
        }
        expect(result.count == Int(file.length), "Read every frame, including short final reads")
        return result
    }

    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
