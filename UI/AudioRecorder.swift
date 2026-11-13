import AVFoundation
import Foundation

/// Rotation and writes share a lock. The engine and converter keep running;
/// each buffer belongs to exactly one segment, even during rapid splits.
final class AudioSegmentWriter {
    private let lock = NSLock()
    private let directory: URL
    private let format: AVAudioFormat
    private let converter: AVAudioConverter
    private var file: AVAudioFile?
    private var level: Float = 0
    private var writeError: Error?

    init(inputFormat: AVAudioFormat, directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Dictation-\(UUID().uuidString)", isDirectory: true)) throws {
        self.directory = directory
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                        channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw NSError(domain: "DictationAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone format is unsupported"])
        }
        self.format = format
        self.converter = converter
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        file = try newFile()
    }

    private func newFile() throws -> AVAudioFile {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        return try autoreleasepool {
            let output = try AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: .pcmFormatInt16, interleaved: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return output
        }
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        // Drain Objective-C temporary retains before releasing the write lock.
        // This also makes ARC-based finalization deterministic on macOS 13–14.
        try autoreleasepool {
            guard let file else { return }
            if let writeError { throw writeError }
            do {
                let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 64
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw NSError(domain: "DictationAudio", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio buffer"])
                }
                var supplied = false
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, state in
                    if supplied {
                        state.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    state.pointee = .haveData
                    return input
                }
                if let conversionError { throw conversionError }
                guard status != .error else {
                    throw NSError(domain: "DictationAudio", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed"])
                }
                if output.frameLength > 0 {
                    try file.write(from: output)
                    if let samples = output.int16ChannelData?[0] {
                        var energy: Float = 0
                        for i in 0..<Int(output.frameLength) {
                            let sample = Float(samples[i]) / 32768
                            energy += sample * sample
                        }
                        let rms = sqrt(energy / Float(output.frameLength))
                        level = max(0, min(1, (20 * log10(max(rms, 0.000001)) + 50) / 50))
                    }
                }
            } catch {
                writeError = error
                throw error
            }
        }
    }

    func rotate() throws -> URL {
        // If creation fails (e.g. disk full), leave the active file intact.
        let replacement = try newFile()
        lock.lock()
        defer { lock.unlock() }
        if let writeError { throw writeError }
        guard let previous = file?.url else {
            throw NSError(domain: "DictationAudio", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Recording has already stopped"])
        }
        if #available(macOS 15.0, *) { file?.close() }
        file = replacement // ARC finalizes the previous WAV on macOS 13–14.
        return previous
    }

    func stop() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let url = file?.url
        // Drain the sample-rate converter's remaining frames only at final stop.
        // It stays live during rotate(), preserving continuity across segments.
        if let file, writeError == nil,
           let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
            var status: AVAudioConverterOutputStatus = .haveData
            while status == .haveData {
                var error: NSError?
                status = converter.convert(to: tail, error: &error) { _, state in
                    state.pointee = .endOfStream
                    return nil
                }
                if let error { writeError = error; break }
                do {
                    if tail.frameLength > 0 { try file.write(from: tail) }
                } catch {
                    writeError = error
                    break
                }
            }
        }
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
        level = 0
        return url
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return writeError
    }

    func currentAudioLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }
}

final class QuickAudioRecorder {
    private var engine: AVAudioEngine?
    private var writer: AudioSegmentWriter?
    private(set) var isRecording = false
    private(set) var lastError: Error?
    var onFailure: ((URL?, Error) -> Void)?

    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    @discardableResult
    func startRecording() -> Bool {
        guard !isRecording else { return true }
        guard Self.hasMicrophonePermission else { return false }
        lastError = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return false }
        do {
            let writer = try AudioSegmentWriter(inputFormat: inputFormat)
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                do {
                    try writer.append(buffer)
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.writer === writer else { return }
                        let url = self.stopRecording()
                        self.onFailure?(url, error)
                    }
                }
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
            self.engine = engine
            self.writer = writer
            isRecording = true
            return true
        } catch {
            print("Failed to start audio capture: \(error.localizedDescription)")
            return false
        }
    }

    func splitRecording() throws -> URL {
        guard let writer, isRecording else {
            throw NSError(domain: "DictationAudio", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No active recording"])
        }
        return try writer.rotate()
    }

    func currentAudioLevel() -> Float { writer?.currentAudioLevel() ?? 0 }

    @discardableResult
    func stopRecording() -> URL? {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        let url = writer?.stop()
        lastError = writer?.failure
        writer = nil
        isRecording = false
        return url
    }
}
