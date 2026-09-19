import Foundation

/// Streams 16 kHz PCM while a push-to-talk key is held. The final REST path remains
/// available when Live Preview is disabled.
final class LiveSarvamStreaming {
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var lastTranscript = ""
    private let onTranscript: (String) -> Void

    init(onTranscript: @escaping (String) -> Void) { self.onTranscript = onTranscript }

    func start(outputMode: OutputMode) throws {
        guard let key = KeychainStore.read(service: "GujType", account: "sarvam-api-key") else { throw SarvamError.missingKey }
        let language: String
        let mode: String
        switch outputMode {
        case .gujarati: language = "gu-IN"; mode = "transcribe"
        case .gujlish: language = "gu-IN"; mode = "translit"
        case .hindi: language = "hi-IN"; mode = "transcribe"
        case .hinglish: language = "hi-IN"; mode = "translit"
        case .english: throw SarvamError.service("Live Sarvam is not used for English.")
        }
        var components = URLComponents(string: "wss://api.sarvam.ai/speech-to-text/ws")!
        components.queryItems = [
            .init(name: "language-code", value: language), .init(name: "model", value: "saaras:v4"),
            .init(name: "mode", value: mode), .init(name: "sample_rate", value: "16000"),
            .init(name: "input_audio_codec", value: "pcm_s16le"), .init(name: "flush_signal", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task; task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    func send(_ pcm: Data) {
        guard let socket else { return }
        let payload: [String: Any] = ["audio": ["data": pcm.base64EncodedString(), "sample_rate": 16000, "encoding": "pcm_s16le"]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }

    func finish() async -> String {
        // Sarvam's streaming protocol supports a flush signal to finalize its current buffer.
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "flush"]), let text = String(data: data, encoding: .utf8) {
            try? await socket?.send(.string(text))
        }
        try? await Task.sleep(for: .milliseconds(900))
        socket?.cancel(with: .normalClosure, reason: nil)
        receiveTask?.cancel()
        return lastTranscript
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message { case .string(let text): data = Data(text.utf8); case .data(let value): data = value; @unknown default: continue }
                guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let body = payload["data"] as? [String: Any], let text = body["transcript"] as? String else { continue }
                lastTranscript = text
                await MainActor.run { self.onTranscript(text) }
            } catch { break }
        }
    }
}
