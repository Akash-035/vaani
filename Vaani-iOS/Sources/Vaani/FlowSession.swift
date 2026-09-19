import AVFoundation
import Foundation

/// The containing app owns microphone capture. The keyboard extension only sends commands
/// through the App Group because iOS does not permit extensions to capture microphone audio.
@MainActor
final class FlowSession: NSObject, ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var status = "No microphone session is active"

    private let defaults = UserDefaults(suiteName: "group.com.vaani.ios")!
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var commandTimer: Timer?
    private var expiryTimer: Timer?
    private var activeRequestID: String?
    private var pcm = Data()
    private let capture = FlowAudioBuffer()
    private var isTranscribing = false
    private var deadline = Date.distantPast
    private var maximumDeadline = Date.distantPast
    @Published private(set) var remainingSeconds = 0

    /// Arms background capture for a bounded period. Individual dictations are
    /// delimited by start/stop commands from the keyboard.
    func startTimed(minutes: Int = 5) async throws {
        if isEnabled { stop() }
        guard await AVAudioApplication.requestRecordPermission() else { throw VaaniError.message("Microphone access was not granted.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw VaaniError.message("This microphone format is not supported.")
        }
        self.engine = engine; self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate + 128)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false; var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard conversionError == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
            self.capture.append(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        }
        try engine.start()
        maximumDeadline = Date().addingTimeInterval(1800)
        deadline = Date().addingTimeInterval(300)
        defaults.removeObject(forKey: "flowCommand")
        isEnabled = true; status = "Flow is on for \(minutes) minutes — switch to any app and use Vaani Keyboard"
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in Task { @MainActor in self?.readKeyboardCommand() } }
    }

    func stop() {
        commandTimer?.invalidate(); commandTimer = nil
        expiryTimer?.invalidate(); expiryTimer = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil; converter = nil
        activeRequestID = nil; pcm.removeAll()
        _ = capture.finish()
        defaults.removeObject(forKey: "flowRecordingID")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isEnabled = false; status = "No microphone session is active"
        defaults.set(0, forKey: "flowHeartbeat")
        defaults.set("idle", forKey: "flowCommand")
        remainingSeconds = 0
    }

    private func readKeyboardCommand() {
        guard engine?.isRunning == true, Date() < deadline else { stop(); return }
        remainingSeconds = max(0, Int(deadline.timeIntervalSinceNow))
        defaults.set(Date().timeIntervalSince1970, forKey: "flowHeartbeat")
        defaults.set(deadline.timeIntervalSince1970, forKey: "flowDeadline")
        let command = defaults.string(forKey: "flowCommand")
        if command == "off" { stop(); return }
        let requestID = defaults.string(forKey: "flowRequestID")
        guard let command, let requestID else { return }
        if command == "start", activeRequestID == nil, !isTranscribing {
            activeRequestID = requestID; pcm.removeAll(); status = "Listening…"
            capture.begin()
            defaults.set(requestID, forKey: "flowRecordingID")
            deadline = min(Date().addingTimeInterval(300), maximumDeadline)
        } else if command == "stop", activeRequestID == requestID, !isTranscribing {
            isTranscribing = true; status = "Transcribing…"
            let audio = capture.finish()
            Task { await transcribe(requestID: requestID, pcm: audio) }
        }
    }

    private func transcribe(requestID: String, pcm: Data) async {
        // A completed utterance must not end the bounded Flow session. Keep the
        // audio engine alive until its expiry so the keyboard remains usable.
        defer { activeRequestID = nil; self.pcm.removeAll(); isTranscribing = false; status = isEnabled ? "Flow is on — ready for the next dictation" : "No microphone session is active" }
        guard pcm.count > 1_600 else { complete(requestID: requestID, result: nil, error: "No speech was captured."); return }
        do {
            let url = try WAVFile.write(pcm16: pcm, sampleRate: 16_000)
            defer { try? FileManager.default.removeItem(at: url) }
            let rawMode = defaults.string(forKey: "keyboardOutputMode") ?? OutputMode.gujlish.rawValue
            let mode = OutputMode(rawValue: rawMode) ?? .gujlish
            let endpoint = UserDefaults.standard.string(forKey: "betaAPIEndpoint") ?? ""
            let text = try await VaaniBetaClient().transcribe(audioURL: url, mode: mode, endpoint: endpoint)
            complete(requestID: requestID, result: text, error: nil)
        } catch { complete(requestID: requestID, result: nil, error: error.localizedDescription) }
    }

    private func complete(requestID: String, result: String?, error: String?) {
        defaults.removeObject(forKey: "flowRecordingID")
        deadline = min(Date().addingTimeInterval(300), maximumDeadline)
        defaults.set(result, forKey: "flowResult")
        defaults.set(error, forKey: "flowError")
        defaults.set(requestID, forKey: "flowCompletedRequestID")
        defaults.set("complete", forKey: "flowCommand")
    }
}

private final class FlowAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var data = Data()
    func begin() { lock.lock(); defer { lock.unlock() }; data.removeAll(); enabled = true }
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; if enabled && data.count < 9_600_000 { data.append(bytes) } }
    func finish() -> Data { lock.lock(); defer { lock.unlock() }; enabled = false; let result = data; data.removeAll(); return result }
}

private enum WAVFile {
    static func write(pcm16: Data, sampleRate: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vaani-flow-\(UUID().uuidString).wav")
        var data = Data("RIFF".utf8)
        data.appendLE(UInt32(36 + pcm16.count)); data.append(Data("WAVEfmt ".utf8)); data.appendLE(UInt32(16)); data.appendLE(UInt16(1)); data.appendLE(UInt16(1)); data.appendLE(UInt32(sampleRate)); data.appendLE(UInt32(sampleRate * 2)); data.appendLE(UInt16(2)); data.appendLE(UInt16(16)); data.append(Data("data".utf8)); data.appendLE(UInt32(pcm16.count)); data.append(pcm16)
        try data.write(to: url, options: .atomic); return url
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; append(Data(bytes: &little, count: MemoryLayout<T>.size)) }
}
