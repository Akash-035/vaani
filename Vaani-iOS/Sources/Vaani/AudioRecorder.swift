import AVFoundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var timer: Timer?

    func toggle() async throws -> URL? {
        if isRecording { return stop() }
        try await start()
        return nil
    }

    private func start() async throws {
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { throw VaaniError.message("Microphone access was not granted.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vaani-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        guard recorder?.record() == true else { throw VaaniError.message("Could not start recording.") }
        duration = 0; isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.duration += 0.2 }
    }

    private func stop() -> URL? {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        let url = recorder?.url
        recorder = nil; isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    func startStreaming(onPCM: @escaping (Data) -> Void) async throws {
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { throw VaaniError.message("Microphone access was not granted.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VaaniError.message("This microphone format is not supported.")
        }
        self.engine = engine; self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate + 128)
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var used = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, outStatus in
                if used { outStatus.pointee = .noDataNow; return nil }
                used = true; outStatus.pointee = .haveData; return buffer
            }
            guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
            onPCM(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        }
        try engine.start()
        duration = 0; isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.duration += 0.2 }
    }

    func stopStreaming() {
        timer?.invalidate(); timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil; converter = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
