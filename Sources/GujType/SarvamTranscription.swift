import Foundation

enum SarvamError: LocalizedError {
    case missingKey, invalidResponse, service(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add a Sarvam API key in Settings before selecting Sarvam Saaras."
        case .invalidResponse: return "Sarvam returned no transcript."
        case .service(let detail): return "Sarvam transcription failed: \(detail)"
        }
    }
}

/// Optional cloud ASR. Saaras accepts a short WAV after the push-to-talk key is released.
struct SarvamTranscriber {
    func transcribe(audioAt url: URL, outputMode: OutputMode, keyterms: [String]) async throws -> Transcript {
        guard let key = KeychainStore.read(service: "GujType", account: "sarvam-api-key") else {
            throw SarvamError.missingKey
        }

        let wavURL = url.deletingPathExtension().appendingPathExtension("sarvam.wav")
        try LocalAudioConverter.convertToWAV(from: url, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let sarvamMode: String
        switch outputMode {
        case .gujarati: sarvamMode = "transcribe"
        case .gujlish: sarvamMode = "translit"
        case .hindi: sarvamMode = "transcribe"
        case .hinglish: sarvamMode = "translit"
        case .english: sarvamMode = "transcribe"
        }
        let language: String
        switch outputMode {
        case .gujarati, .gujlish: language = "gu-IN"
        case .hindi, .hinglish: language = "hi-IN"
        case .english: language = "en-IN"
        }
        let builtInKeyterms = ["PDF", "WhatsApp", "meeting", "office", "client", "project", "message", "check"]
        let mergedKeyterms = Array((builtInKeyterms + keyterms).reduce(into: [String]()) { result, term in
            if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) { result.append(term) }
        }.prefix(50))
        let keytermsJSON = String(data: try JSONSerialization.data(withJSONObject: mergedKeyterms), encoding: .utf8)!
        let fields = [
            "model": "saaras:v4",
            "mode": sarvamMode,
            "language_code": language,
            // Saaras v4 accepts up to 50 JSON-encoded keyterms. These include the user's
            // personal dictionary so names and domain jargon are biased during recognition.
            "keyterms": keytermsJSON
        ]
        let form = try MultipartForm.make(fileURL: wavURL, fields: fields)
        var request = URLRequest(url: URL(string: "https://api.sarvam.ai/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, from: form.data)
        guard let http = response as? HTTPURLResponse else { throw SarvamError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SarvamError.service(String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }
        let reply = try JSONDecoder().decode(SarvamReply.self, from: data)
        let text = reply.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SarvamError.invalidResponse }
        return Transcript(text: text, language: reply.languageCode ?? language)
    }
}

private struct SarvamReply: Decodable {
    let transcript: String
    let languageCode: String?
    enum CodingKeys: String, CodingKey { case transcript; case languageCode = "language_code" }
}

private struct MultipartForm {
    let boundary: String
    let data: Data

    static func make(fileURL: URL, fields: [String: String]) throws -> MultipartForm {
        let boundary = "GujType-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")
        return MultipartForm(boundary: boundary, data: body)
    }
}
