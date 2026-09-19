import Foundation
import Security

enum CloudCleanupError: LocalizedError {
    case missingKey, invalidResponse, service(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add an OpenAI API key in Settings to enable high-accuracy cleanup."
        case .invalidResponse: return "Cleanup service returned no text."
        case .service(let message): return "Cleanup failed: \(message)"
        }
    }
}

struct OpenAICleaner {
    func clean(rawGujarati: String, preliminary: String, mode: OutputMode) async throws -> String {
        guard let key = KeychainStore.read(service: "GujType", account: "openai-api-key") else { throw CloudCleanupError.missingKey }
        let style: String
        switch mode {
        case .gujarati: style = "Gujarati script"
        case .gujlish: style = "natural everyday Gujlish in Latin letters"
        case .hindi: style = "Hindi in Devanagari script"
        case .hinglish: style = "natural everyday Roman Hindi (Hinglish)"
        case .english: style = "English"
        }
        let prompt = """
        Return only the corrected final text, with no explanation or quotation marks.
        Output style: \(style).
        Preserve the meaning of the raw local transcript. Correct obvious ASR spellings and restore common English terms such as PDF, WhatsApp, office, client, project, message, and meeting. Do not invent facts or rewrite the sentence when uncertain.
        RAW LOCAL TRANSCRIPT: \(rawGujarati)
        PRELIMINARY OUTPUT: \(preliminary)
        """
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.6-luna", "input": prompt, "store": false,
            "reasoning": ["effort": "none"], "max_output_tokens": 120
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudCleanupError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw CloudCleanupError.service(message)
        }
        let decoded = try JSONDecoder().decode(ResponsesReply.self, from: data)
        guard let text = decoded.output.flatMap(\.content).first(where: { $0.type == "output_text" })?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudCleanupError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ResponsesReply: Decodable {
    let output: [ResponsesOutput]
}
private struct ResponsesOutput: Decodable {
    let content: [ResponsesContent]
}
private struct ResponsesContent: Decodable {
    let type: String
    let text: String?
}

enum KeychainStore {
    // Keychain authorization belongs to the running app's code-signing identity. During
    // development that identity can change between builds, so repeatedly reading the same
    // secret may repeatedly trigger macOS's keychain prompt. Cache secrets only in process
    // memory after the first authorized read; nothing is persisted outside Keychain.
    private static var memoryCache: [String: String] = [:]
    private static let lock = NSLock()

    static func read(service: String, account: String) -> String? {
        let cacheKey = "\(service)|\(account)"
        lock.lock()
        if let cached = memoryCache[cacheKey] { lock.unlock(); return cached }
        lock.unlock()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)
        if let value { lock.lock(); memoryCache[cacheKey] = value; lock.unlock() }
        return value
    }
    static func save(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CloudCleanupError.service("Keychain write failed") }
        lock.lock(); memoryCache["\(service)|\(account)"] = value; lock.unlock()
    }
}
