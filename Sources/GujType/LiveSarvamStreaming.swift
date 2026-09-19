import Foundation

/// The historical name is retained for project compatibility. The server owns provider credentials.
@MainActor
final class LiveSarvamStreaming {
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private let stream: AsyncStream<Data>
    nonisolated private let continuation: AsyncStream<Data>.Continuation
    private var ready = false
    private var done = false
    private var failure: Error?
    private var committed = ""
    private var draft = ""
    private var lastSequence = 0
    private let onTranscript: (String, Bool) -> Void
    private let onError: (String) -> Void

    init(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (String) -> Void) {
        self.onTranscript = onTranscript; self.onError = onError
        var captured: AsyncStream<Data>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingOldest(50)) { captured = $0 }
        continuation = captured
    }

    func start(outputMode: OutputMode, endpoint: String) throws {
        guard var url = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw VaaniBetaError.invalidEndpoint
        }
        guard let token = KeychainStore.read(service: "GujType", account: "vaani-beta-access-token") else {
            throw VaaniBetaError.missingSession
        }
        let mode: String
        switch outputMode {
        case .gujarati: mode = "gujarati"
        case .gujlish: mode = "gujlish"
        case .hindi: mode = "hindi"
        case .hinglish: mode = "hinglish"
        case .english: mode = "english"
        }
        url.scheme = scheme == "https" ? "wss" : "ws"
        let prefix = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = "/" + (prefix.isEmpty ? "" : prefix + "/") + "v1/realtime"
        url.queryItems = [.init(name: "mode", value: mode)]
        guard let address = url.url else { throw VaaniBetaError.invalidEndpoint }
        var request = URLRequest(url: address)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket; socket.maximumMessageSize = 256 * 1024; socket.resume()
        receiver = Task { [weak self] in await self?.receiveLoop() }
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                let deadline = Date().addingTimeInterval(12)
                while !ready && failure == nil && Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                if let failure { throw failure }
                guard ready else { throw SarvamError.service("Live connection timed out.") }
                for await chunk in stream {
                    try Task.checkCancellation()
                    try await socket.send(.data(chunk))
                }
                if failure == nil { try await socket.send(.string("{\"event\":\"end\"}")) }
            } catch { if !Task.isCancelled { fail(error) } }
        }
    }

    nonisolated func send(_ pcm: Data) {
        if case .dropped = continuation.yield(pcm) {
            Task { @MainActor [weak self] in self?.fail(SarvamError.service("Connection too slow for live dictation.")) }
        }
    }

    func finish() async throws -> String {
        continuation.finish()
        let deadline = Date().addingTimeInterval(20)
        while !done && failure == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        defer { cancel() }
        if let failure { throw failure }
        guard done else { throw SarvamError.service("Final words timed out. The live preview has been preserved.") }
        return committed
    }

    func cancel() {
        continuation.finish(); sender?.cancel(); receiver?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
    }

    private func fail(_ error: Error) {
        guard failure == nil, !done else { return }
        failure = error; onError(error.localizedDescription); cancel()
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message { case .string(let text): data = Data(text.utf8); case .data(let value): data = value; @unknown default: continue }
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = payload["event"] as? String else { throw VaaniBetaError.invalidResponse }
                let sequence = payload["sequence"] as? Int ?? 0
                guard sequence > lastSequence else { continue }
                lastSequence = sequence
                switch event {
                case "ready": ready = true
                case "transcript.partial", "transcript.final":
                    guard let text = payload["text"] as? String else { throw VaaniBetaError.invalidResponse }
                    if event == "transcript.final" {
                        committed = [committed, text].filter { !$0.isEmpty }.joined(separator: " "); draft = ""
                    } else { draft = text }
                    onTranscript(text, event == "transcript.final")
                case "done": done = true; return
                case "error": throw SarvamError.service("Live dictation: \(payload["code"] as? String ?? "connection error"). Release the shortcut and retry.")
                default: break
                }
            } catch { if !Task.isCancelled { fail(error) }; return }
        }
    }
}
