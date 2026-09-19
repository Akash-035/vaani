import Foundation

/// Streams 16 kHz PCM while push-to-talk is held and exposes Sarvam partial results.
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
        // This is Sarvam's current Realtime endpoint. The older /speech-to-text/ws
        // endpoint returns only final segments and therefore cannot power a live UI.
        var components = URLComponents(string: "wss://api.sarvam.ai/speech-to-text-realtime/ws")!
        components.queryItems = [
            .init(name: "language_code", value: language), .init(name: "model", value: "saaras:v3-realtime"),
            .init(name: "mode", value: mode), .init(name: "sample_rate", value: "16000"),
            .init(name: "encoding", value: "linear16"), .init(name: "endpointing", value: "manual"),
            .init(name: "stream_type", value: "balanced")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task; task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        sendEvent("speech_start")
    }

    func send(_ pcm: Data) {
        guard let socket else { return }
        let payload: [String: Any] = ["event": "audio_input", "audio": pcm.base64EncodedString()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }

    func finish() async -> String {
        sendEvent("speech_end")
        sendEvent("flush")
        try? await Task.sleep(for: .milliseconds(1_200))
        sendEvent("end")
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
                guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let text = payload["text"] as? String ?? (payload["data"] as? [String: Any])?["transcript"] as? String
                guard let text, !text.isEmpty else { continue }
                lastTranscript = text
                await MainActor.run { self.onTranscript(text) }
            } catch { break }
        }
    }

    private func sendEvent(_ event: String) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: ["event": event]), let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }
}
