import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var flowSession = FlowSession()
    @AppStorage("betaAPIEndpoint") private var betaAPIEndpoint = ""
    @State private var mode: OutputMode = .gujlish
    @State private var text = ""
    @State private var isProcessing = false
    @State private var showSettings = false
    @State private var errorMessage: String?
    @State private var showReturnGuide = false
    private let sharedDefaults = UserDefaults(suiteName: "group.com.vaani.ios")!

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.15), Color(red: 0.20, green: 0.07, blue: 0.02)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Vaani").font(.system(size: 32, weight: .bold, design: .rounded))
                                Text("Speak. Copy. Paste anywhere.").font(.subheadline).foregroundStyle(.white.opacity(0.66))
                            }
                            Spacer()
                            Button { showSettings = true } label: {
                                Image(systemName: "gearshape.fill").font(.title3).padding(11).background(.white.opacity(0.12), in: Circle())
                            }.accessibilityLabel("Settings")
                        }
                        Picker("Output language", selection: $mode) { ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.menu).tint(.white).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 15).padding(.vertical, 11)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        Button { errorMessage = "Flow Session is not part of the cloud beta yet." } label: {
                            Label(flowSession.isEnabled ? "Flow Session Active — 5 min" : "Start Flow Session — 5 min", systemImage: flowSession.isEnabled ? "waveform.circle.fill" : "waveform.circle")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }.buttonStyle(.bordered).tint(flowSession.isEnabled ? .green : .white).disabled(flowSession.isEnabled)
                        Text(flowSession.status).font(.footnote).foregroundStyle(.white.opacity(0.66)).multilineTextAlignment(.center)
                        if flowSession.isEnabled {
                            Text("Mic active · \(flowSession.remainingSeconds / 60):\(String(format: "%02d", flowSession.remainingSeconds % 60)) remaining").monospacedDigit()
                            Button("Mic off") { flowSession.stop(); showReturnGuide = false }.tint(.red)
                        }
                        Text("The microphone stays active during a conversation. It shuts off after 5 idle minutes, with a 30-minute session limit.").font(.caption)
                        Button(action: recordAction) {
                            ZStack {
                                Circle().fill(recorder.isRecording ? Color.red : Color.orange).frame(width: 120, height: 120)
                                Circle().stroke(.white.opacity(0.30), lineWidth: 7).frame(width: 138, height: 138)
                                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
                            }
                        }.disabled(isProcessing || flowSession.isEnabled).accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording").padding(.top, 6)
                        VStack(spacing: 7) {
                            Text(isProcessing ? "Processing your input…" : (recorder.isRecording ? "Recording \(durationText)" : "Tap to start dictation")).font(.headline)
                            Text(isProcessing ? "Turning your voice into text" : (recorder.isRecording ? "Tap again when you are finished" : "\(mode.rawValue) output"))
                                .font(.subheadline).foregroundStyle(.white.opacity(0.66))
                        }
                        VStack(alignment: .leading, spacing: 13) {
                            HStack { Label("Result", systemImage: "text.quote").font(.headline); Spacer(); if !text.isEmpty { Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).accessibilityLabel("Copy result") } }
                            Text(text.isEmpty ? "Your dictation will appear here." : text).frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading).foregroundStyle(text.isEmpty ? .white.opacity(0.55) : .white).textSelection(.enabled)
                            if !text.isEmpty { HStack { Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.borderedProminent).tint(.orange); ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered) } }
                        }.padding(18).background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                    }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 30)
                }.scrollIndicators(.hidden)
            }.foregroundStyle(.white)
            .sheet(isPresented: $showSettings) { SettingsSheet(endpoint: $betaAPIEndpoint) }
            .onAppear { sharedDefaults.set(mode.rawValue, forKey: "keyboardOutputMode") }
            .onOpenURL { url in
                guard url.scheme == "vaani", url.host == "dictate" else { return }
                Task {
                    do {
                        if !flowSession.isEnabled { try await flowSession.startTimed() }
                        sharedDefaults.set(UUID().uuidString, forKey: "flowRequestID")
                        sharedDefaults.set("start", forKey: "flowCommand")
                        showReturnGuide = true
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            .overlay { if showReturnGuide && flowSession.isEnabled { ReturnToAppGuide { showReturnGuide = false } } }
            .onChange(of: mode) { _, newValue in sharedDefaults.set(newValue.rawValue, forKey: "keyboardOutputMode") }
            .alert("Vaani", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }

    private var durationText: String { String(format: "%02d:%02d", Int(recorder.duration) / 60, Int(recorder.duration) % 60) }
    private func recordAction() {
        Task {
            do {
                if let audioURL = try await recorder.toggle() {
                    isProcessing = true
                    defer { isProcessing = false; try? FileManager.default.removeItem(at: audioURL) }
                    text = try await VaaniBetaClient().transcribe(audioURL: audioURL, mode: mode, endpoint: betaAPIEndpoint)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ReturnToAppGuide: View {
    let dismiss: () -> Void
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.70).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "arrow.left.circle.fill")
                    .font(.system(size: 72)).foregroundStyle(.orange)
                    .scaleEffect(pulse ? 1.13 : 0.92)
                    .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
                Text("Recording has started")
                    .font(.title2.weight(.bold)).foregroundStyle(.white)
                Text("Swipe right along the bottom home indicator to return to your app.\n\nYour dictation is starting. Speak, then tap Done on Vaani Keyboard.\n\nIf another keyboard appears, select Vaani with the globe key; your recording continues.")
                    .multilineTextAlignment(.leading).foregroundStyle(.white.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
                Button("Dismiss guide", action: dismiss)
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding(28).frame(maxWidth: 360)
            .background(Color(red: 0.10, green: 0.11, blue: 0.16), in: RoundedRectangle(cornerRadius: 28))
            .padding(24)
        }
    }
}

private struct SettingsSheet: View {
    @Binding var endpoint: String
    @State private var inviteCode = ""
    @State private var status = VaaniBetaKeychain.read() == nil ? "Not connected" : "Saved beta session is active"
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { Form { Section("Vaani Cloud beta") { TextField("https://…", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled(); SecureField("Beta invite code", text: $inviteCode); Button("Connect") { Task { do { try await VaaniBetaClient().connect(endpoint: endpoint, inviteCode: inviteCode); inviteCode = ""; status = "Connected — session saved securely" } catch { status = error.localizedDescription } } }; Text(status).font(.footnote).foregroundStyle(status.hasPrefix("Connected") || status.hasPrefix("Saved") ? .green : .secondary); Text("The invite code is exchanged for a short-lived session and is not stored on this iPhone.").font(.footnote).foregroundStyle(.secondary) }; Section("Keyboard") { Text("Keyboard cloud dictation is being migrated separately. Enable Vaani Keyboard only after its beta update is installed.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Settings").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } } }
}
