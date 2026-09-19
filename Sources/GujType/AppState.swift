import AppKit
import AVFoundation
import ApplicationServices
import Combine

enum OutputMode: String, CaseIterable, Identifiable {
    case gujarati = "Gujarati"
    case gujlish = "Gujlish"
    case hindi = "Hindi (देवनागरी)"
    case hinglish = "Hinglish (Roman)"
    case english = "English fallback"
    var id: String { rawValue }
}

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case local = "Local on this Mac"
    case beta = "Vaani Cloud (beta)"
    var id: String { rawValue }
}

enum PermissionState {
    case unknown, granted, denied
}

struct DictationRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let mode: String
    let provider: String
    let date: Date
    let duration: TimeInterval

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

@MainActor
final class AppState: ObservableObject {
    @Published var microphonePermission: PermissionState = .unknown
    @Published var accessibilityPermission: PermissionState = .unknown
    @Published var isRecording = false
    @Published var outputMode: OutputMode {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode") }
    }
    @Published var transcriptionProvider: TranscriptionProvider {
        didSet { UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: "transcriptionProvider") }
    }
    @Published var shortcut: Hotkey {
        didSet {
            UserDefaults.standard.set(shortcut.identifier, forKey: "shortcut")
            hotkeyMonitor?.stop()
            hotkeyMonitor = makeHotkeyMonitor()
            hotkeyMonitor?.start()
        }
    }
    @Published var status = "Ready"
    @Published var lastTranscript = ""
    @Published var lastOutput = ""
    @Published var betaAPIEndpoint: String { didSet { UserDefaults.standard.set(betaAPIEndpoint, forKey: "betaAPIEndpoint") } }
    @Published private(set) var betaSessionExpiresAt: Date?
    @Published var useLivePreview: Bool {
        didSet { UserDefaults.standard.set(useLivePreview, forKey: "useLivePreview") }
    }
    @Published var typeWhileSpeaking: Bool {
        didSet { UserDefaults.standard.set(typeWhileSpeaking, forKey: "typeWhileSpeaking") }
    }
    @Published var liveTranscript = ""
    @Published var isProcessing = false
    @Published private(set) var dictationError: String?
    private var dictationSessionID = UUID()
    @Published private(set) var personalDictionary: [String] {
        didSet { UserDefaults.standard.set(personalDictionary, forKey: "personalDictionary") }
    }
    @Published private(set) var history: [DictationRecord] {
        didSet { saveHistory() }
    }

    let recorder = AudioRecorder()
    let whisperTranscriber: any LocalTranscribing = WhisperTranscriber()
    let gujaratiTranscriber: any LocalTranscribing = GujaratiIndicTranscriber()
    let inserter = FocusedTextInserter()
    private var hotkeyMonitor: HotkeyMonitor?
    private var recordingStartedAt: Date?
    private var recordingOutputMode: OutputMode?
    private var liveStreamer: LiveSarvamStreaming?
    private var livePresentation = LiveTranscriptPresentation()
    private var liveUpdateTask: Task<Void, Never>?
    private var liveComposition: LiveTextComposition?
    private let liveOverlay = LiveOverlayController()

    /// English Whisper is already strong locally, so cloud STT is reserved for Indic modes.
    var usesCloudForCurrentMode: Bool {
        transcriptionProvider == .beta
    }

    var activeProviderName: String {
        usesCloudForCurrentMode ? "Vaani Cloud (beta)" : "Local Whisper"
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "outputMode")
        outputMode = OutputMode(rawValue: saved ?? "") ?? .gujarati
        let savedProvider = UserDefaults.standard.string(forKey: "transcriptionProvider")
        transcriptionProvider = TranscriptionProvider(rawValue: savedProvider ?? "") ?? .local
        betaAPIEndpoint = UserDefaults.standard.string(forKey: "betaAPIEndpoint") ?? ""
        betaSessionExpiresAt = UserDefaults.standard.object(forKey: "betaSessionExpiresAt") as? Date
        useLivePreview = UserDefaults.standard.bool(forKey: "useLivePreview")
        typeWhileSpeaking = UserDefaults.standard.bool(forKey: "typeWhileSpeaking")
        personalDictionary = UserDefaults.standard.stringArray(forKey: "personalDictionary") ?? []
        history = Self.loadHistory()
        let savedShortcut = UserDefaults.standard.string(forKey: "shortcut")
        let legacyDefault = Hotkey(keyCode: 49, modifiers: [.control, .option]).identifier
        shortcut = savedShortcut == legacyDefault
            ? .defaultShortcut
            : Hotkey.known.first { $0.identifier == savedShortcut } ?? .defaultShortcut
        refreshPermissions()
        hotkeyMonitor = makeHotkeyMonitor()
        hotkeyMonitor?.start()
    }

    private func makeHotkeyMonitor() -> HotkeyMonitor {
        HotkeyMonitor(shortcut: shortcut, onPress: { [weak self] in
            Task { @MainActor in self?.startRecording() }
        }, onRelease: { [weak self] in
            Task { @MainActor in await self?.stopAndTranscribe() }
        })
    }

    func refreshPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphonePermission = .granted
        case .notDetermined: microphonePermission = .unknown
        default: microphonePermission = .denied
        }
        accessibilityPermission = AXIsProcessTrusted() ? .granted : .denied
    }

    func requestMicrophone() {
        NSApp.activate(ignoringOtherApps: true)
        status = "Requesting microphone permission…"
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
                self?.status = self?.microphonePermission == .granted ? "Microphone ready" : "Microphone access was not granted"
            }
        }
    }

    func requestAccessibility() {
        status = "Approve Vaani in System Settings, then return here"
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshPermissions()
            self?.restartHotkeyMonitor()
        }
    }

    func startRecording() {
        guard !isRecording, !isProcessing else { return }
        guard microphonePermission == .granted else {
            status = "Allow microphone access first"
            if microphonePermission == .unknown { requestMicrophone() }
            return
        }
        do {
            dictationSessionID = UUID()
            let sessionID = dictationSessionID
            dictationError = nil
            recordingOutputMode = outputMode
            // Whisper runs only after release, so it has no partial text to display. Always
            // clear the previous session first; the overlay will correctly say Listening…
            // instead of showing a stale Sarvam result during local English recording.
            liveTranscript = ""
            if useLivePreview && usesCloudForCurrentMode {
                liveUpdateTask?.cancel(); liveUpdateTask = nil
                livePresentation = LiveTranscriptPresentation()
                liveComposition = LiveTextComposition.begin()
                let streamer = LiveSarvamStreaming(onTranscript: { [weak self] text, isFinal in self?.acceptLiveTranscript(text, isFinal: isFinal) }, onError: { [weak self] error in
                    guard self?.dictationSessionID == sessionID else { return }
                    self?.dictationError = error
                    self?.status = error
                    Task {
                        guard self?.dictationSessionID == sessionID else { return }
                        await self?.stopAndTranscribe()
                    }
                })
                try streamer.start(outputMode: outputMode, endpoint: betaAPIEndpoint)
                liveStreamer = streamer
                try recorder.start { [weak streamer] chunk in streamer?.send(chunk) }
            } else {
                try recorder.start()
            }
            isRecording = true
            isProcessing = false
            liveOverlay.show(appState: self)
            recordingStartedAt = Date()
            status = liveStreamer == nil ? "Recording… release \(shortcut.displayName) to transcribe" : "Live dictation — speak now (2-minute limit)"
        } catch {
            liveStreamer?.cancel(); liveStreamer = nil
            recorder.cancel()
            isRecording = false; isProcessing = false
            dictationError = error.localizedDescription
            status = "Could not start dictation: \(error.localizedDescription)"
            liveOverlay.show(appState: self)
        }
    }

    func stopAndTranscribe() async {
        guard isRecording else { return }
        isRecording = false
        isProcessing = true
        let recordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt ?? Date()))
        recordingStartedAt = nil
        let liveRun = liveStreamer != nil
        let sessionID = dictationSessionID
        let outputMode = recordingOutputMode ?? self.outputMode
        defer {
            liveUpdateTask?.cancel(); liveUpdateTask = nil
            liveStreamer?.cancel(); liveStreamer = nil; liveComposition = nil
            recordingOutputMode = nil; isProcessing = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.dictationSessionID == sessionID, self.dictationError == nil,
                      !self.isRecording, !self.isProcessing else { return }
                self.liveOverlay.hide()
            }
        }
        status = liveRun ? "Finalizing live transcript…" : (usesCloudForCurrentMode ? "Transcribing with Vaani Cloud…" : "Transcribing locally…")
        do {
            let audioURL = try recorder.stop()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let transcript: Transcript
            if let liveStreamer {
                let finalText = try await liveStreamer.finish()
                self.liveStreamer = nil
                transcript = Transcript(text: finalText, language: outputMode.whisperLanguage)
            } else if usesCloudForCurrentMode {
                transcript = try await VaaniBetaTranscriber().transcribe(audioAt: audioURL, outputMode: outputMode, endpoint: betaAPIEndpoint)
            } else {
                let transcriber = outputMode.usesGujaratiEngine ? gujaratiTranscriber : whisperTranscriber
                transcript = try await transcriber.transcribe(audioAt: audioURL, languageHint: outputMode.whisperLanguage)
            }
            lastTranscript = transcript.text
            var output = usesCloudForCurrentMode
                ? transcript.text
                : OutputFormatter.format(transcript, mode: outputMode)
            // Sarvam realtime partial/final events can be native script even for a translit
            // request. Format streamed text locally so the preview always matches the picker.
            if liveRun { output = livePresentation.committed }
            lastOutput = output
            guard !output.isEmpty else { status = "No speech detected"; return }
            let method: String
            if liveRun, let composition = liveComposition, composition.replace(with: output, committedUTF16Length: output.utf16.count) {
                method = "live Accessibility composition"
            } else if liveRun {
                method = "live preview — copy from History"
            } else {
                method = inserter.insert(output)
            }
            liveComposition = nil
            history.insert(DictationRecord(
                id: UUID(), text: output, mode: outputMode.rawValue,
                provider: activeProviderName, date: Date(), duration: recordingDuration
            ), at: 0)
            if history.count > 100 { history.removeLast(history.count - 100) }
            status = method == "live preview — copy from History" ? "Live dictation saved — copy from History" : "Inserted via \(usesCloudForCurrentMode ? "Vaani Cloud" : "local Whisper") using \(method)"
        } catch {
            dictationError = error.localizedDescription
            if liveRun { lastOutput = liveTranscript }
            status = error.localizedDescription
        }
        // Keep the final result visible briefly so the bottom bar feels conclusive,
        // rather than vanishing the moment the key is released.
    }

    func startBetaSession(inviteCode: String) async {
        guard !inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Enter your beta invite code"; return }
        status = "Connecting to Vaani Cloud…"
        do {
            let expiry = try await VaaniBetaTranscriber().startSession(endpoint: betaAPIEndpoint, inviteCode: inviteCode)
            betaSessionExpiresAt = expiry
            UserDefaults.standard.set(expiry, forKey: "betaSessionExpiresAt")
            status = "Vaani Cloud beta session ready"
        } catch { status = error.localizedDescription }
    }

    func addDictionaryTerm(_ rawTerm: String) {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        guard term.count <= 64 else {
            status = "Dictionary terms must be 64 characters or fewer"
            return
        }
        guard !personalDictionary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        guard personalDictionary.count < 42 else {
            status = "Dictionary is full (42 custom terms)"
            return
        }
        personalDictionary.append(term)
        personalDictionary.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        status = "Added \(term) to your dictionary"
    }

    func removeDictionaryTerm(_ term: String) {
        personalDictionary.removeAll { $0 == term }
    }

    private func acceptLiveTranscript(_ rawText: String, isFinal: Bool) {
        let outputMode = recordingOutputMode ?? self.outputMode
        let display = OutputFormatter.format(Transcript(text: rawText, language: outputMode.whisperLanguage), mode: outputMode)
        livePresentation.receive(display, isFinal: isFinal)
        if liveTranscript != livePresentation.preview { liveTranscript = livePresentation.preview }
        if isFinal {
            liveUpdateTask?.cancel(); liveUpdateTask = nil
            renderLiveText()
        } else if liveUpdateTask == nil {
            // Coalesce rather than debounce: continuous partials cannot postpone
            // rendering indefinitely. Romanized output gets more settling time.
            let delay: UInt64 = (outputMode == .gujlish || outputMode == .hinglish) ? 250_000_000 : 120_000_000
            liveUpdateTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self else { return }
                self.liveUpdateTask = nil
                self.renderLiveText()
            }
        }
    }

    private func renderLiveText() {
        let mode = recordingOutputMode ?? outputMode
        let display = livePresentation.editorText(holdLastWord: mode == .gujlish || mode == .hinglish)
        if let composition = liveComposition,
           !composition.replace(with: display, committedUTF16Length: livePresentation.committed.utf16.count) {
            liveComposition = nil
            status = "Live preview only — field or cursor changed. Copy the result from History."
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied to clipboard"
    }

    func deleteHistory(_ record: DictationRecord) {
        history.removeAll { $0.id == record.id }
    }

    var totalWords: Int { history.reduce(0) { $0 + $1.wordCount } }
    var totalDuration: TimeInterval { history.reduce(0) { $0 + $1.duration } }
    var wordsPerMinute: Int {
        guard totalDuration > 1 else { return 0 }
        return Int((Double(totalWords) / totalDuration * 60).rounded())
    }
    var timeSaved: TimeInterval { max(0, Double(totalWords) / 40 * 60 - totalDuration) }

    private static func loadHistory() -> [DictationRecord] {
        guard let data = UserDefaults.standard.data(forKey: "dictationHistory"),
              let items = try? JSONDecoder().decode([DictationRecord].self, from: data) else { return [] }
        return items
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: "dictationHistory")
    }

    private func restartHotkeyMonitor() {
        hotkeyMonitor?.stop()
        hotkeyMonitor = makeHotkeyMonitor()
        hotkeyMonitor?.start()
    }
}
