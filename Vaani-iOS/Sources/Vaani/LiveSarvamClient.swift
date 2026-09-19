import Foundation

final class LiveSarvamClient {
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var latest = ""
    private let onTranscript: @MainActor (String) -> Void

    init(onTranscript: @escaping @MainActor (String) -> Void) { self.onTranscript = onTranscript }

    func start(mode: OutputMode, apiKey: String) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaaniError.missingKey }
        var components = URLComponents(string: "wss://api.sarvam.ai/speech-to-text-realtime/ws")!
        components.queryItems = [
            .init(name: "language_code", value: mode.languageCode), .init(name: "model", value: "saaras:v3-realtime"),
            .init(name: "mode", value: mode.sarvamMode), .init(name: "sample_rate", value: "16000"),
            .init(name: "encoding", value: "linear16"), .init(name: "endpointing", value: "manual"), .init(name: "stream_type", value: "balanced")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket; socket.resume(); send(event: "speech_start")
        receiver = Task { [weak self] in await self?.receiveLoop() }
    }

    func send(pcm: Data) {
        let payload: [String: Any] = ["event": "audio_input", "audio": pcm.base64EncodedString()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let message = String(data: data, encoding: .utf8), let socket else { return }
        Task { try? await socket.send(.string(message)) }
    }

    func finish() async -> String {
        send(event: "speech_end"); send(event: "flush")
        try? await Task.sleep(for: .milliseconds(1_200)); send(event: "end")
        socket?.cancel(with: .normalClosure, reason: nil); receiver?.cancel()
        return latest
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            guard let message = try? await socket.receive() else { break }
            let data: Data
            switch message { case .string(let value): data = Data(value.utf8); case .data(let value): data = value; @unknown default: continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let value = object["text"] as? String ?? (object["data"] as? [String: Any])?["transcript"] as? String
            guard let value, !value.isEmpty else { continue }
            latest = value; await onTranscript(value)
        }
    }

    private func send(event: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["event": event]), let value = String(data: data, encoding: .utf8), let socket else { return }
        Task { try? await socket.send(.string(value)) }
    }
}
