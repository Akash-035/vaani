import Foundation

struct SarvamClient {
    private struct Response: Decodable { let transcript: String?; let text: String? }

    func transcribe(audioURL: URL, mode: OutputMode, apiKey: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaaniError.missingKey }
        let audio = try Data(contentsOf: audioURL)
        let boundary = "Vaani-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.sarvam.ai/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "saaras:v4")
        field("language_code", mode.languageCode)
        field("mode", mode.sarvamMode)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VaaniError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "Request failed"
            throw VaaniError.message("Sarvam error \(http.statusCode): \(detail)")
        }
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        guard let text = parsed.transcript ?? parsed.text, !text.isEmpty else { throw VaaniError.badResponse }
        return text
    }
}
