import SwiftUI

private let brand = Color(red: 0.98, green: 0.43, blue: 0.08)

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) { Image(systemName: app.isRecording ? "waveform" : "waveform.badge.mic").foregroundStyle(brand).font(.title3); Text("Vaani").font(.headline); Spacer(); Circle().fill(app.isRecording ? .red : .green).frame(width: 8, height: 8) }
            Text(app.isRecording ? "Recording — release \(app.shortcut.displayName) to finish" : app.status).font(.caption).foregroundStyle(.secondary)
            HStack { Label(app.activeProviderName, systemImage: app.usesCloudForCurrentMode ? "cloud.fill" : "laptopcomputer"); Spacer(); Text(app.outputMode.rawValue) }.font(.caption).foregroundStyle(.secondary)
            if !app.lastOutput.isEmpty { Divider(); Text(app.lastOutput).lineLimit(3).textSelection(.enabled); Button("Copy latest") { app.copyToClipboard(app.lastOutput) } }
            Divider()
            Button("Open Vaani") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "settings") }
            Button("Quit Vaani") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }.padding(14).frame(width: 340).onAppear { app.refreshPermissions() }
    }
}

private enum DashboardPage: String, CaseIterable, Identifiable {
    case home = "Home", insights = "Insights", dictionary = "Dictionary", settings = "Settings"
    var id: String { rawValue }
    var icon: String { switch self { case .home: "house.fill"; case .insights: "chart.bar.xaxis"; case .dictionary: "text.book.closed.fill"; case .settings: "gearshape.fill" } }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var page: DashboardPage = .home
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page); Divider()
            Group { switch page { case .home: HomePage(); case .insights: InsightsPage(); case .dictionary: DictionaryPage(); case .settings: SettingsPage() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(36).background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 960, minHeight: 650).preferredColorScheme(.dark).onAppear { app.refreshPermissions() }
    }
}

private struct Sidebar: View {
    @Binding var page: DashboardPage
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) { ZStack { RoundedRectangle(cornerRadius: 9).fill(brand.opacity(0.16)); Image(systemName: "waveform").foregroundStyle(brand) }.frame(width: 34, height: 34); Text("Vaani").font(.title3.weight(.bold)) }.padding(.bottom, 26)
            ForEach(DashboardPage.allCases) { item in Button { page = item } label: { Label(item.rawValue, systemImage: item.icon).font(.body.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10).background(page == item ? brand.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(page == item ? brand : .primary) }.buttonStyle(.plain) }
            Spacer()
            Label("Private by design", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            Text("Your dictation history stays on this Mac.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 218, alignment: .leading).background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct HomePage: View {
    @EnvironmentObject var app: AppState
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .top) { VStack(alignment: .leading, spacing: 6) { Text("Speak naturally. Type anywhere.").font(.system(size: 31, weight: .bold)); Text("Hold \(app.shortcut.displayName), speak, and release. Vaani writes into your focused app.").foregroundStyle(.secondary) }; Spacer(); StatusPill() }
        HStack(alignment: .top, spacing: 18) { DictationStudio().frame(maxWidth: .infinity); TodayCard().frame(width: 230) }
        HStack { Text("Recent dictations").font(.title3.weight(.bold)); Spacer(); Text("Stored locally").font(.caption).foregroundStyle(.secondary) }
        RecentList(records: Array(app.history.prefix(5)))
    } }.scrollIndicators(.hidden) }
}

private struct StatusPill: View { @EnvironmentObject var app: AppState
    var body: some View { Label(app.isRecording ? "Listening" : app.activeProviderName, systemImage: app.isRecording ? "waveform" : (app.usesCloudForCurrentMode ? "cloud.fill" : "laptopcomputer")).font(.caption.weight(.semibold)).foregroundStyle(app.isRecording ? .red : brand).padding(.horizontal, 11).padding(.vertical, 7).background((app.isRecording ? Color.red : brand).opacity(0.13), in: Capsule()) }
}

private struct DictationStudio: View { @EnvironmentObject var app: AppState
    var body: some View { VStack(alignment: .leading, spacing: 17) {
        HStack { Label("Try Vaani", systemImage: "mic.fill").font(.headline); Spacer(); Text(app.outputMode.rawValue).font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 5).background(.white.opacity(0.13), in: Capsule()) }
        Text(app.isRecording ? (app.liveTranscript.isEmpty ? "Listening… speak naturally." : app.liveTranscript) : "Hold \(app.shortcut.displayName) anywhere to dictate.").font(.title3.weight(.semibold))
        Text(app.isRecording ? "Release the shortcut when you are done. Your words will appear below." : "Use this space to review your latest result before you share it anywhere.").foregroundStyle(.white.opacity(0.78))
        HStack(alignment: .top, spacing: 12) { Image(systemName: app.isRecording ? "waveform" : "text.cursor").font(.title2).frame(width: 24).foregroundStyle(.white); Text(app.lastOutput.isEmpty ? "Your latest dictation will appear here…" : app.lastOutput).frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading).foregroundStyle(app.lastOutput.isEmpty ? .white.opacity(0.55) : .white).textSelection(.enabled); if !app.lastOutput.isEmpty { Button { app.copyToClipboard(app.lastOutput) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).foregroundStyle(.white) } }.padding(15).background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 13))
    }.padding(23).foregroundStyle(.white).background(LinearGradient(colors: [Color(red: 0.28, green: 0.10, blue: 0.02), Color(red: 0.86, green: 0.30, blue: 0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22)) }
}

private struct TodayCard: View { @EnvironmentObject var app: AppState
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("Today").font(.headline); Metric(value: "\(app.totalWords)", label: "words dictated"); Metric(value: app.wordsPerMinute == 0 ? "—" : "\(app.wordsPerMinute)", label: "words / min"); Metric(value: "\(app.history.count)", label: "dictations"); Metric(value: compactTime(app.timeSaved), label: "saved vs typing") }.padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.07))) }
}
private struct Metric: View { let value: String; let label: String; var body: some View { HStack(alignment: .firstTextBaseline, spacing: 6) { Text(value).font(.title2.weight(.bold)); Text(label).font(.caption).foregroundStyle(.secondary) } } }

private struct RecentList: View { let records: [DictationRecord]; @EnvironmentObject var app: AppState
    var body: some View { VStack(spacing: 0) { if records.isEmpty { EmptyState(icon: "waveform", title: "No dictations yet", message: "Your completed dictations will be saved here on this Mac.").frame(maxWidth: .infinity).padding(36) } else { ForEach(records) { record in HStack(spacing: 14) { Text(record.date, format: .dateTime.hour().minute()).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 50, alignment: .leading); VStack(alignment: .leading, spacing: 3) { Text(record.text).lineLimit(2); Text("\(record.mode) · \(record.provider)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { app.copyToClipboard(record.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless); Button { app.deleteHistory(record) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary) }.padding(.vertical, 13); if record.id != records.last?.id { Divider() } } } }.padding(.horizontal, 16).background(.quaternary, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07))) }
}

private struct InsightsPage: View { @EnvironmentObject var app: AppState
    var body: some View { VStack(alignment: .leading, spacing: 24) { Text("Your voice, in numbers").font(.system(size: 31, weight: .bold)); Text("A local view of your Vaani activity. Nothing is synced or shared.").foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 8) { Text("Time saved").font(.headline); Text(compactTime(app.timeSaved)).font(.system(size: 48, weight: .bold)).foregroundStyle(brand); Text("Based on 40 words per minute typing speed.").foregroundStyle(.secondary) }.padding(25).frame(maxWidth: .infinity, alignment: .leading).background(brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 22)); HStack(spacing: 14) { InsightStat(title: "Words dictated", value: "\(app.totalWords)", icon: "textformat"); InsightStat(title: "Dictations", value: "\(app.history.count)", icon: "waveform"); InsightStat(title: "Time speaking", value: compactTime(app.totalDuration), icon: "clock"); InsightStat(title: "Speaking pace", value: app.wordsPerMinute == 0 ? "—" : "\(app.wordsPerMinute) wpm", icon: "speedometer") }; Spacer() } }
}
private struct InsightStat: View { let title: String; let value: String; let icon: String; var body: some View { VStack(alignment: .leading, spacing: 13) { Image(systemName: icon).foregroundStyle(brand); Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.weight(.bold)) }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 16)) } }

private struct DictionaryPage: View { @EnvironmentObject var app: AppState; @State private var term = ""
    var body: some View { VStack(alignment: .leading, spacing: 24) { Text("Personal dictionary").font(.system(size: 31, weight: .bold)); Text("Names, companies and jargon Vaani should spell your way.").foregroundStyle(.secondary); HStack { TextField("e.g. Akash Patel, Vaani, Ahmedabad", text: $term).textFieldStyle(.roundedBorder); Button("Add term") { app.addDictionaryTerm(term); term = "" }.buttonStyle(.borderedProminent).tint(brand).disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }; Text("Saved only on this Mac.").font(.caption).foregroundStyle(.secondary); if app.personalDictionary.isEmpty { EmptyState(icon: "text.badge.plus", title: "Make Vaani yours", message: "Add people, businesses, places, and product terms you say often.") } else { FlowLayout(items: app.personalDictionary) { word in HStack(spacing: 7) { Text(word); Button { app.removeDictionaryTerm(word) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary) }.padding(.horizontal, 11).padding(.vertical, 8).background(.quaternary, in: Capsule()) } }; Spacer() } }
}

private struct SettingsPage: View { @EnvironmentObject var app: AppState; @State private var inviteCode = ""
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 25) { Text("Settings").font(.system(size: 31, weight: .bold)); SettingsCard(title: "Dictation shortcut", subtitle: "Hold to talk; release to finish transcription.") { Picker("Shortcut", selection: $app.shortcut) { ForEach(Hotkey.known) { Text($0.displayName).tag($0) } }.labelsHidden().frame(width: 160) }; SettingsCard(title: "Language & output", subtitle: "Choose how the next dictation is written.") { Picker("Output", selection: $app.outputMode) { ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 210) }; SettingsCard(title: "Transcription provider", subtitle: "Local keeps audio on this Mac. Vaani Cloud supports completed recordings and live dictation through the beta service.") { Picker("Provider", selection: $app.transcriptionProvider) { ForEach(TranscriptionProvider.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 190) }; SettingsCard(title: "Live dictation (experimental)", subtitle: "Words appear while you speak in compatible fields. Other fields use a live preview; copy the result from History. Gujlish/Hinglish spelling may change as phrases finish. Maximum 2 minutes.") { Toggle("Live dictation", isOn: $app.useLivePreview).disabled(app.transcriptionProvider != .beta || app.isRecording || app.isProcessing) }; SettingsCard(title: "Vaani Cloud beta", subtitle: "Enter the private beta HTTPS address and your one-time invite code. The invite code is not stored; only a short-lived session is kept in Keychain.") { VStack(alignment: .trailing, spacing: 8) { TextField("https://…", text: $app.betaAPIEndpoint).textFieldStyle(.roundedBorder).frame(width: 280); HStack { SecureField("Beta invite code", text: $inviteCode).textFieldStyle(.roundedBorder).frame(width: 180); Button("Connect") { Task { await app.startBetaSession(inviteCode: inviteCode); inviteCode = "" } }.disabled(inviteCode.isEmpty || app.betaAPIEndpoint.isEmpty) } } }; SettingsCard(title: "Permissions", subtitle: "Microphone records speech. Accessibility enables global typing.") { HStack { Button(app.microphonePermission == .granted ? "Microphone ready" : "Allow microphone") { app.requestMicrophone() }.disabled(app.microphonePermission == .granted); Button(app.accessibilityPermission == .granted ? "Accessibility ready" : "Allow accessibility") { app.requestAccessibility() }.disabled(app.accessibilityPermission == .granted) } } } } }
}

private struct SettingsCard<Content: View>: View { let title: String; let subtitle: String; @ViewBuilder let content: Content; var body: some View { HStack(alignment: .center, spacing: 20) { VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }; Spacer(); content }.padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07))) } }
private struct EmptyState: View { let icon: String; let title: String; let message: String; var body: some View { VStack(spacing: 9) { Image(systemName: icon).font(.title).foregroundStyle(brand); Text(title).font(.headline); Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) } } }
private struct FlowLayout<Item: Hashable, Content: View>: View { let items: [Item]; let content: (Item) -> Content; init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) { self.items = items; self.content = content }; var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], alignment: .leading, spacing: 10) { ForEach(items, id: \.self) { content($0) } } } }
private func compactTime(_ seconds: TimeInterval) -> String { if seconds < 60 { return seconds < 1 ? "0 min" : "<1 min" }; return "\(Int(seconds / 60)) min" }
