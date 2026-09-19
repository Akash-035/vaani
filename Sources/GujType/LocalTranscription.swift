import Foundation

struct Transcript { let text: String; let language: String }
protocol LocalTranscribing { func transcribe(audioAt url: URL, languageHint: String) async throws -> Transcript }
enum TranscriptionError: LocalizedError {
    case modelUnavailable, runnerUnavailable, audioConversionFailed(String), transcriptionFailed(String)
    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Local Whisper model missing. Put ggml-small.bin in ~/Library/Application Support/GujType/models/."
        case .runnerUnavailable:
            return "whisper.cpp is missing. Install its whisper-cli binary, then restart GujType."
        case .audioConversionFailed(let detail): return "Could not prepare audio for Whisper: \(detail)"
        case .transcriptionFailed(let detail): return "Local Whisper failed: \(detail)"
        }
    }
}

/// Invokes a locally installed whisper.cpp binary. Audio and text never leave the Mac.
struct WhisperTranscriber: LocalTranscribing {
    func transcribe(audioAt url: URL, languageHint: String) async throws -> Transcript {
        let model = try modelURL()
        let executable = try executableURL()
        let wavURL = url.deletingPathExtension().appendingPathExtension("wav")
        try LocalAudioConverter.convertToWAV(from: url, to: wavURL)

        let outputBase = wavURL.deletingPathExtension().appendingPathExtension("transcript")
        let process = Process()
        process.executableURL = executable
        // Auto-detection is unreliable for short, code-switched Gujarati clips. The chosen
        // output mode supplies a stable decoding language instead.
        process.arguments = ["-m", model.path, "-f", wavURL.path, "-l", languageHint, "-nt", "-otxt", "-of", outputBase.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw TranscriptionError.transcriptionFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let textURL = outputBase.appendingPathExtension("txt")
        let text = (try? String(contentsOf: textURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: textURL)
        return Transcript(text: text, language: languageHint)
    }

    private func modelURL() throws -> URL {
        let fileManager = FileManager.default
        let modelsDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GujType/models")
        let configured = ProcessInfo.processInfo.environment["GUJTYPE_WHISPER_MODEL"].map(URL.init(fileURLWithPath:))
        // Prefer the substantially more accurate multilingual medium model when installed.
        let candidates = [configured,
                          modelsDirectory.appendingPathComponent("ggml-medium.bin"),
                          modelsDirectory.appendingPathComponent("ggml-small.bin")].compactMap { $0 }
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) { return candidate }
        throw TranscriptionError.modelUnavailable
    }

    private func executableURL() throws -> URL {
        let fileManager = FileManager.default
        let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: path) }
        throw TranscriptionError.runnerUnavailable
    }

}

enum LocalAudioConverter {
    static func convertToWAV(from source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw TranscriptionError.audioConversionFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Gujarati-specific ASR. It launches the locally installed ONNX helper, never a network service.
struct GujaratiIndicTranscriber: LocalTranscribing {
    func transcribe(audioAt url: URL, languageHint: String) async throws -> Transcript {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Application Support/GujType")
        let python = base.appendingPathComponent("runtime/bin/python")
        let model = base.appendingPathComponent("models/indicconformer-gu")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: model.appendingPathComponent("model.int8.onnx").path) else {
            throw GujaratiEngineError.notInstalled
        }
        guard let helper = Bundle.main.url(forResource: "gujarati_asr", withExtension: "py") else {
            throw GujaratiEngineError.helperMissing
        }

        let wavURL = url.deletingPathExtension().appendingPathExtension("wav")
        try LocalAudioConverter.convertToWAV(from: url, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let process = Process()
        process.executableURL = python
        process.arguments = [helper.path, model.path, wavURL.path]
        let output = Pipe(); let errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw GujaratiEngineError.failed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Transcript(text: text, language: "gu")
    }
}

enum GujaratiEngineError: LocalizedError {
    case notInstalled, helperMissing, failed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Gujarati IndicConformer is not installed."
        case .helperMissing: return "Gujarati transcription helper is missing from the app bundle."
        case .failed(let detail): return "Gujarati local ASR failed: \(detail)"
        }
    }
}

enum OutputFormatter {
    static func format(_ transcript: Transcript, mode: OutputMode) -> String {
        switch mode {
        case .gujarati: return transcript.text
        case .hindi: return transcript.text
        case .english: return transcript.text
        case .gujlish: return IndicXlit.transliteratePreservingLatin(transcript.text)
        case .hinglish: return IndicXlit.transliterateDevanagariPreservingLatin(transcript.text)
        }
    }
}

extension OutputMode {
    /// Whisper's ISO 639-1 Gujarati language token is `gu`.
    var whisperLanguage: String {
        switch self {
        case .gujarati, .gujlish: return "gu"
        case .hindi, .hinglish: return "hi"
        case .english: return "en"
        }
    }

    var usesGujaratiEngine: Bool {
        self == .gujarati || self == .gujlish
    }
}

enum IndicXlit {
    /// Everyday Gujlish differs from scholarly romanization. Common speech and product terms
    /// use their normal keyboard spellings; unfamiliar Gujarati words use an ICU fallback.
    private static let everydayLexicon: [String: String] = [
        "ગુડ": "good", "મોર્નિંગ": "morning", "ભાઈ": "bhai", "ભાઇ": "bhai", "શું": "shu",
        "કરે": "kare", "છે": "chhe", "તું": "tu", "તુ": "tu", "તુમ": "tu", "તો": "to",
        "ગુજરાતી": "gujarati", "સમજતો": "samjto", "સમજતું": "samjto", "સમજાતું": "samjto", "જ": "j", "નથી": "nthi",
        "કાલે": "kale", "કાલેની": "kaleni", "કાલાની": "kaleni", "મીટિંગ": "meeting", "માટે": "maate", "રાખજો": "rakhjo", "તૈયારી": "taiyari",
        "એટલે": "etle", "એતલે": "etle", "ધીમે": "dhime", "બોલજે": "bolje",
        "આજે": "aaje", "પીડીએફ": "PDF", "પીડીેફ": "PDF", "PDF": "PDF",
        "વહોટ્સઅપ": "whatsapp", "વોટ્સઅપ": "whatsapp", "વ્હોટ્સઅપ": "whatsapp", "વ્હોટ્સએપ": "whatsapp", "વ્હોટ્સઅપ્પ": "whatsapp", "WhatsApp": "whatsapp",
        "પર": "pr", "અને": "ane", "મોકલી": "mokali", "મોકલેલા": "mokalela", "દેજો": "dejo",
        "મેસેજ": "message", "મેસજા": "message", "ચેક": "check", "ચેકા": "check", "કરી": "kari",
        "સવારે": "savare", "દસ": "das", "દસા": "das", "વાગ્યે": "vagye", "વાગે": "vagye",
        "ઓફિસ": "office", "ઓફિસમાં": "office ma", "માં": "ma", "ક્લાયન્ટ": "client", "ક્લિએન્ટ": "client",
        "સાથે": "sathe", "પ્રોજેક્ટ": "project", "પ્રોજેક્ટા": "project", "ની": "ni", "વાત": "vaat", "વાતા": "vaat", "કરવી": "karvi"
    ]

    static func transliteratePreservingLatin(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).map { transliterateToken(String($0)) }.joined(separator: " ")
    }

    static func transliterateDevanagariPreservingLatin(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).map { token in
            let mutable = NSMutableString(string: String(token))
            guard CFStringTransform(mutable, nil, "Devanagari-Latin" as CFString, false) else { return String(token) }
            CFStringTransform(mutable, nil, "Latin-ASCII" as CFString, false)
            return mutable as String
        }.joined(separator: " ")
    }

    private static func transliterateToken(_ token: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let leading = String(token.prefix { String($0).rangeOfCharacter(from: punctuation) != nil })
        let trailing = String(token.reversed().prefix { String($0).rangeOfCharacter(from: punctuation) != nil }.reversed())
        let word = String(token.dropFirst(leading.count).dropLast(trailing.count))
        guard !word.isEmpty else { return token }
        if let preferred = everydayLexicon[word] { return leading + preferred + trailing }
        // The recognizer can emit abbreviations such as પી.ડી.એફ.; match their letters as one term.
        let compactWord = word.unicodeScalars.filter { !punctuation.contains($0) }.map(String.init).joined()
        if let preferred = everydayLexicon[compactWord] { return leading + preferred + trailing }

        let mutable = NSMutableString(string: word)
        let transformed = CFStringTransform(mutable, nil, "Gujarati-Latin" as CFString, false)
        guard transformed else { return token }
        // Gujlish is normally typed without diacritics. This keeps it keyboard-friendly.
        CFStringTransform(mutable, nil, "Latin-ASCII" as CFString, false)
        return leading + (mutable as String) + trailing
    }
}
