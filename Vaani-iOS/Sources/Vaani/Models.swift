import Foundation

enum OutputMode: String, CaseIterable, Identifiable {
    case gujarati = "Gujarati"
    case gujlish = "Gujlish"
    case hindi = "Hindi"
    case hinglish = "Hinglish"
    case english = "English"

    var id: String { rawValue }
    var languageCode: String {
        switch self {
        case .gujarati, .gujlish: return "gu-IN"
        case .hindi, .hinglish: return "hi-IN"
        case .english: return "en-IN"
        }
    }
    var sarvamMode: String { self == .gujlish || self == .hinglish ? "translit" : "transcribe" }
    var betaValue: String { switch self { case .gujarati: return "gujarati"; case .gujlish: return "gujlish"; case .hindi: return "hindi"; case .hinglish: return "hinglish"; case .english: return "english" } }
}

enum VaaniError: LocalizedError {
    case missingKey, badResponse, message(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Sarvam API key in Settings."
        case .badResponse: return "Vaani could not read the transcription response."
        case .message(let message): return message
        }
    }
}
