import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {
    private let recordButton = UIButton(type: .system)
    private let speakButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let languageButton = UIButton(type: .system)
    private var isProcessing = false
    private var requestID: String?
    private var poll: Timer?
    private var launcher: UIHostingController<AnyView>?
    private let offButton = UIButton(type: .system)
    private var alive: Bool { Date().timeIntervalSince1970 - defaults.double(forKey: "flowHeartbeat") < 3 }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncSession()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.syncSession() }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); poll?.invalidate(); poll = nil }

    private func syncSession() {
        guard !isProcessing else { return }
        launcher?.view.isHidden = alive
        offButton.isHidden = !alive
        if alive, defaults.string(forKey: "flowCommand") == "start", let id = defaults.string(forKey: "flowRecordingID") {
            requestID = id; showDoneUI()
        } else if requestID == nil || !alive {
            requestID = nil; recordButton.isHidden = true; speakButton.isHidden = !alive
            let seconds = max(0, Int(defaults.double(forKey: "flowDeadline") - Date().timeIntervalSince1970))
            statusLabel.text = alive ? "Mic active · \(seconds / 60):\(String(format: "%02d", seconds % 60)) remaining" : "Start a conversation in Vaani, then swipe back"
        }
    }
    private var mode: KeyboardOutputMode { KeyboardOutputMode(rawValue: defaults.string(forKey: "keyboardOutputMode") ?? "") ?? .gujlish }
    private let defaults = UserDefaults(suiteName: "group.com.vaani.ios")!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupInterface()
        restoreActiveRequestIfNeeded()
    }

    private func setupInterface() {
        view.backgroundColor = UIColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1)
        recordButton.configuration = .filled()
        recordButton.configuration?.baseBackgroundColor = .systemOrange
        recordButton.configuration?.baseForegroundColor = .white
        recordButton.configuration?.image = UIImage(systemName: "checkmark")
        recordButton.configuration?.title = "  Done"
        recordButton.configuration?.cornerStyle = .capsule
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)

        languageButton.configuration = .plain()
        languageButton.configuration?.baseForegroundColor = .white
        languageButton.addTarget(self, action: #selector(changeLanguage), for: .touchUpInside)

        statusLabel.textColor = .lightGray
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        speakButton.configuration = .filled(); speakButton.configuration?.baseBackgroundColor = .systemOrange; speakButton.configuration?.baseForegroundColor = .white; speakButton.configuration?.image = UIImage(systemName: "mic.fill"); speakButton.configuration?.title = "  Speak"; speakButton.configuration?.cornerStyle = .capsule
        speakButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        recordButton.accessibilityLabel = "Finish dictation"
        recordButton.isHidden = true
        let host = UIHostingController(rootView: AnyView(Link("Start conversation", destination: URL(string: "vaani://dictate")!).font(.headline).padding(12).foregroundStyle(.orange)))
        launcher = host; addChild(host); host.view.backgroundColor = .clear; host.didMove(toParent: self)
        offButton.setTitle("Mic off", for: .normal)
        offButton.addTarget(self, action: #selector(micOff), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [languageButton, host.view!, speakButton, recordButton, statusLabel, offButton])
        stack.axis = .vertical; stack.spacing = 9; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            speakButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        refreshIdleState()
    }

    private func refreshIdleState() {
        languageButton.configuration?.title = "\(mode.rawValue)  ▾"
        statusLabel.text = "Tap Speak, then Done to insert at the cursor"
    }

    @objc private func changeLanguage() {
        let modes = KeyboardOutputMode.allCases
        guard let index = modes.firstIndex(of: mode) else { return }
        defaults.set(modes[(index + 1) % modes.count].rawValue, forKey: "keyboardOutputMode")
        refreshIdleState()
    }

    @objc private func recordTapped() {
        guard !isProcessing else { return }
        requestID == nil ? startRecording() : finishRecording()
    }

    private func startRecording() {
        guard hasFullAccess else { showError("Enable Allow Full Access in Keyboard Settings."); return }
        guard alive else { syncSession(); return }
        let id: String
        if defaults.string(forKey: "flowCommand") == "start", let active = defaults.string(forKey: "flowRequestID") { id = active }
        else {
            id = UUID().uuidString
            defaults.removeObject(forKey: "flowResult"); defaults.removeObject(forKey: "flowError"); defaults.removeObject(forKey: "flowCompletedRequestID")
            defaults.set(id, forKey: "flowRequestID"); defaults.set("awaitingStart", forKey: "flowCommand")
        }
        requestID = id
        defaults.set("start", forKey: "flowCommand")
        showDoneUI()
    }

    @objc private func micOff() { defaults.set("off", forKey: "flowCommand"); defaults.set(0, forKey: "flowHeartbeat"); requestID = nil; syncSession() }

    private func showDoneUI() {
        recordButton.configuration?.baseBackgroundColor = .systemRed
        recordButton.configuration?.image = UIImage(systemName: "checkmark")
        recordButton.configuration?.title = "  Done"
        speakButton.isHidden = true; recordButton.isHidden = false
        statusLabel.text = "Recording in Vaani… tap Done when finished"
    }

    private func showSpeakUI() {
        requestID = nil; recordButton.isHidden = true; speakButton.isHidden = false
        recordButton.configuration?.baseBackgroundColor = .systemOrange
        statusLabel.text = "Tap Speak to open Vaani and start a short dictation"
    }

    private func finishRecording() {
        guard let requestID else { return }
        defaults.set("stop", forKey: "flowCommand")
        isProcessing = true; recordButton.isEnabled = false
        statusLabel.text = "Transcribing…"
        Task { @MainActor in
            defer { isProcessing = false; recordButton.isEnabled = true; self.requestID = nil; recordButton.isHidden = true; speakButton.isHidden = !alive }
            for _ in 0..<90 {
                if defaults.string(forKey: "flowCompletedRequestID") == requestID {
                    if let text = defaults.string(forKey: "flowResult"), !text.isEmpty { textDocumentProxy.insertText(text) }
                    else { showError(defaults.string(forKey: "flowError") ?? "Vaani could not finish this dictation.") }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            showError("Vaani did not respond. Open Vaani and enable Flow Session first.")
        }
    }

    private func showError(_ message: String) {
        requestID = nil; recordButton.isHidden = true; speakButton.isHidden = false
        statusLabel.text = message
        recordButton.configuration?.baseBackgroundColor = .systemOrange
        recordButton.configuration?.image = UIImage(systemName: "checkmark")
        recordButton.configuration?.title = "  Done"
    }

    private func restoreActiveRequestIfNeeded() {
        guard defaults.string(forKey: "flowCommand") == "start", let id = defaults.string(forKey: "flowRequestID") else { return }
        requestID = id
        showDoneUI()
    }
}

private enum KeyboardOutputMode: String, CaseIterable { case gujarati = "Gujarati", gujlish = "Gujlish", hindi = "Hindi", hinglish = "Hinglish", english = "English" }
