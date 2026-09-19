import AVFoundation

enum RecordingError: LocalizedError { case notRecording
    var errorDescription: String? { "No active recording." }
}

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    private var streamingConverter: AVAudioConverter?
    private var streamFormat: AVAudioFormat?
    private var onPCMChunk: ((Data) -> Void)?
    private var pendingPCM = Data()
    private let audioLock = NSLock()

    func start(onPCMChunk: ((Data) -> Void)? = nil) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        self.onPCMChunk = onPCMChunk
        if onPCMChunk != nil {
            let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            streamingConverter = AVAudioConverter(from: format, to: target)
            streamFormat = target
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("gujtype-\(UUID().uuidString).caf")
        // Live dictation needs only a bounded in-memory packet buffer.
        file = onPCMChunk == nil ? try AVAudioFile(forWriting: destination, settings: format.settings) : nil
        pendingPCM.removeAll()
        url = destination
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.audioLock.lock(); defer { self.audioLock.unlock() }
            try? self.file?.write(from: buffer)
            self.stream(buffer)
        }
        engine.prepare()
        try engine.start()
    }
    func stop() throws -> URL {
        guard let url else { throw RecordingError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioLock.lock(); defer { audioLock.unlock() }
        if !pendingPCM.isEmpty { onPCMChunk?(pendingPCM); pendingPCM.removeAll() }
        file = nil; self.url = nil; streamingConverter = nil; streamFormat = nil; onPCMChunk = nil
        return url
    }

    private func stream(_ buffer: AVAudioPCMBuffer) {
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
        guard error == nil, let samples = output.int16ChannelData, output.frameLength > 0 else { return }
        pendingPCM.append(Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        while pendingPCM.count >= 3200 {
            callback(Data(pendingPCM.prefix(3200)))
            pendingPCM.removeFirst(3200)
        }
    }
}
