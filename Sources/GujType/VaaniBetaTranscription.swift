import Foundation

enum VaaniBetaError: LocalizedError {
    case missingConfiguration, missingSession, invalidEndpoint, invalidResponse
    case service(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "Add the Vaani beta API address in Settings."
        case .missingSession: return "Add your beta invite code in Settings."
        case .invalidEndpoint: return "The Vaani beta API address is invalid."
        case .invalidResponse: return "Vaani returned an unreadable transcription response."
        case .service(let status, _):
            switch status {
            case 401: return "Your beta session expired. Add your invite code again."
            case 413: return "That recording is too long for the beta service."
            case 429: return "Beta quota reached. Please try again later."
            case 502, 503: return "Vaani transcription is temporarily unavailable."
            default: return "Vaani beta service error (\(status))."
            }
        }
    }
}

struct VaaniBetaTranscriber {
    private struct SessionReply: Decodable { let accessToken: String; let expiresIn: TimeInterval }
    private struct Reply: Decodable { let transcript: String }
    private let service = "GujType"
    private let tokenAccount = "vaani-beta-access-token"

    func startSession(endpoint: String, inviteCode: String) async throws -> Date {
        guard let baseURL = normalizedURL(endpoint) else { throw VaaniBetaError.invalidEndpoint }
        var request = URLRequest(url: baseURL.appending(path: "v1/beta/session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["inviteCode": inviteCode])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VaaniBetaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw VaaniBetaError.service(status: http.statusCode, message: "") }
        let reply = try JSONDecoder().decode(SessionReply.self, from: data)
        try KeychainStore.save(reply.accessToken, service: service, account: tokenAccount)
        return Date().addingTimeInterval(reply.expiresIn)
    }

    func transcribe(audioAt url: URL, outputMode: OutputMode, endpoint: String) async throws -> Transcript {
        guard let baseURL = normalizedURL(endpoint) else { throw VaaniBetaError.missingConfiguration }
        guard let token = KeychainStore.read(service: service, account: tokenAccount) else { throw VaaniBetaError.missingSession }
        let wavURL = url.deletingPathExtension().appendingPathExtension("vaani-beta.wav")
        try LocalAudioConverter.convertToWAV(from: url, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let boundary = "Vaani-\(UUID().uuidString)"
        var payload = Data()
        func append(_ string: String) { payload.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        payload.append(try Data(contentsOf: wavURL))
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: baseURL.appending(path: "v1/transcriptions").appending(queryItems: [URLQueryItem(name: "mode", value: modeValue(outputMode))]))
        request.httpMethod = "POST"
        request.timeoutInterval = 50
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: payload)
        guard let http = response as? HTTPURLResponse else { throw VaaniBetaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw VaaniBetaError.service(status: http.statusCode, message: String(data: data, encoding: .utf8) ?? "") }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard !reply.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaaniBetaError.invalidResponse }
        return Transcript(text: reply.transcript, language: outputMode.whisperLanguage)
    }

    private func normalizedURL(_ raw: String) -> URL? { URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private func modeValue(_ mode: OutputMode) -> String {
        switch mode { case .gujarati: return "gujarati"; case .gujlish: return "gujlish"; case .hindi: return "hindi"; case .hinglish: return "hinglish"; case .english: return "english" }
    }
}
