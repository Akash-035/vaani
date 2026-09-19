import Foundation
import Security

enum VaaniBetaError: LocalizedError {
    case missingEndpoint, missingSession, invalidResponse, service(Int)
    var errorDescription: String? {
        switch self {
        case .missingEndpoint: return "Add the Vaani beta API address in Settings."
        case .missingSession: return "Connect with your beta invite code first."
        case .invalidResponse: return "Vaani returned an unreadable response."
        case .service(let status):
            switch status { case 401: return "Your beta session expired. Connect again with your invite code."; case 429: return "Beta quota reached. Try again later."; case 413: return "That recording is too long for beta."; case 504: return "Transcription took too long. Please try again."; default: return "Vaani beta service error (\(status))." }
        }
    }
}

enum VaaniBetaKeychain {
    static let service = "com.vaani.ios"
    static let account = "beta-access-token"
    static let accessGroup = "FYV9PR66S6.com.vaani.shared"
    static func read() -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrAccessGroup as String: accessGroup, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrAccessGroup as String: accessGroup]
        SecItemDelete(query as CFDictionary)
        var item = query; item[kSecValueData as String] = Data(value.utf8)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VaaniError.message("Could not securely save the beta session.") }
    }
}

struct VaaniBetaClient {
    private struct SessionReply: Decodable { let accessToken: String }
    private struct TranscriptReply: Decodable { let transcript: String }

    func connect(endpoint: String, inviteCode: String) async throws {
        guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VaaniBetaError.missingEndpoint }
        var request = URLRequest(url: base.appending(path: "v1/beta/session"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["inviteCode": inviteCode])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VaaniBetaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw VaaniError.message("That beta invite code was not accepted.") }
            throw VaaniBetaError.service(http.statusCode)
        }
        try VaaniBetaKeychain.save(try JSONDecoder().decode(SessionReply.self, from: data).accessToken)
    }

    func transcribe(audioURL: URL, mode: OutputMode, endpoint: String) async throws -> String {
        guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VaaniBetaError.missingEndpoint }
        guard let token = VaaniBetaKeychain.read() else { throw VaaniBetaError.missingSession }
        let boundary = "Vaani-\(UUID().uuidString)"; var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audioURL)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: base.appending(path: "v1/transcriptions").appending(queryItems: [URLQueryItem(name: "mode", value: mode.betaValue)]))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw VaaniBetaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw VaaniBetaError.service(http.statusCode) }
        let reply = try JSONDecoder().decode(TranscriptReply.self, from: data)
        guard !reply.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaaniBetaError.invalidResponse }
        return reply.transcript
    }
}
