import AVFoundation

enum RecordingError: LocalizedError { case notRecording, unavailable, formatChanged
    var errorDescription: String? {
        switch self {
        case .notRecording: return "No active recording."
        case .unavailable: return "Microphone audio is unavailable. Check the selected input device and retry."
        case .formatChanged: return "The microphone format changed during recording. Please start a new dictation."
        }
    }
}

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var url: URL?
    private var streamingConverter: AVAudioConverter?
    private var streamFormat: AVAudioFormat?
    private var onPCMChunk: ((Data) -> Void)?
    private var pendingPCM = Data()
    private let audioLock = NSLock()
    private var hasTap = false
    private var captureError: Error?
    private var onError: ((String) -> Void)?

    func start(onPCMChunk: ((Data) -> Void)? = nil, onError: ((String) -> Void)? = nil) throws {
        cancel()
        // Input routes (especially Bluetooth) can change sample rate between
        // sessions. Never reuse a graph that negotiated the previous format.
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { cancel(); throw RecordingError.unavailable }
        self.onPCMChunk = onPCMChunk
        self.onError = onError
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("gujtype-\(UUID().uuidString).caf")
        // Live dictation needs only a bounded in-memory packet buffer.
        pendingPCM.removeAll()
        url = destination
        // nil adopts the input node's native format; conversion is downstream.
        input.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.audioLock.lock(); defer { self.audioLock.unlock() }
            guard self.captureError == nil else { return }
            do {
                if self.onPCMChunk != nil { try self.stream(buffer) }
                else if let url = self.url {
                    if self.file == nil { self.file = try AVAudioFile(forWriting: url, settings: buffer.format.settings) }
                    guard self.file?.processingFormat.isEqual(buffer.format) == true else { throw RecordingError.formatChanged }
                    try self.file?.write(from: buffer)
                }
            } catch {
                self.captureError = error
                self.onError?(error.localizedDescription)
            }
        }
        hasTap = true
        engine.prepare()
        do { try engine.start() } catch { cancel(); throw error }
    }
    func stop() throws -> URL {
        guard let url else { throw RecordingError.notRecording }
        engine?.inputNode.removeTap(onBus: 0)
        hasTap = false
        engine?.stop(); engine = nil
        audioLock.lock(); defer { audioLock.unlock() }
        if !pendingPCM.isEmpty { onPCMChunk?(pendingPCM); pendingPCM.removeAll() }
        let error = captureError
        file = nil; self.url = nil; streamingConverter = nil; streamFormat = nil; onPCMChunk = nil; onError = nil; captureError = nil
        if let error { throw error }
        return url
    }

    func cancel() {
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        engine?.stop(); engine = nil
        audioLock.lock(); defer { audioLock.unlock() }
        file = nil; url = nil; streamingConverter = nil; streamFormat = nil
        onPCMChunk = nil; pendingPCM.removeAll()
        onError = nil; captureError = nil
    }

    private func stream(_ buffer: AVAudioPCMBuffer) throws {
        if streamingConverter == nil || streamingConverter?.inputFormat.isEqual(buffer.format) == false {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: buffer.format, to: target) else { throw RecordingError.unavailable }
            streamingConverter = converter; streamFormat = target
        }
        guard let converter = streamingConverter, let outputFormat = streamFormat, let callback = onPCMChunk else { return }
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return }
        var suppliedInput = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !suppliedInput else { status.pointee = .noDataNow; return nil }
            suppliedInput = true; status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let samples = output.int16ChannelData, output.frameLength > 0 else { return }
        pendingPCM.append(Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        while pendingPCM.count >= 3200 {
            callback(Data(pendingPCM.prefix(3200)))
            pendingPCM.removeFirst(3200)
        }
    }
}
