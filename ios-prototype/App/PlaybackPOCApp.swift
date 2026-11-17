import SwiftUI
import AVKit

@main
struct PlaybackPOCApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                JourneyView().tabItem { Label("Demo journey", systemImage: "play.circle") }
                CatalogView().tabItem { Label("AniList", systemImage: "magnifyingglass") }
                PlaybackView().tabItem { Label("Playback", systemImage: "play.rectangle") }
            }
        }
    }
}

struct PlaybackView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var provider = ProviderPlaybackModel()
    private var model: PlaybackModel { provider.playback }
    @State private var resolveProvider = false
    @State private var address = ""
    @State private var headers = ""
    @State private var inputError: String?
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Anilili playback proof of concept").font(.headline)
                Toggle("Resolve AniDB App server endpoint", isOn: $resolveProvider)
                if resolveProvider {
                    Text("Supply a known AniDB App JSON server endpoint. Title matching and protected/browser sources are not supported here.").font(.caption)
                }
                TextField(resolveProvider ? "AniDB server endpoint URL" : "Supplied video URL", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                TextField("Request headers as JSON (optional)", text: $headers)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).disabled(resolveProvider)
                Text("User-Agent is supported. Other headers are reported as unsupported. No credentials are stored.").font(.caption)
                if provider.isResolving { ProgressView("Resolving media…").accessibilityIdentifier("provider.resolving") }
                if let error = provider.errorMessage {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("provider.error")
                    Button("Resolve again") { provider.retry() }.accessibilityIdentifier("provider.retry")
                }
                Button(resolveProvider ? "Resolve and play" : "Load") {
                    inputError = nil
                    guard let url = URL(string: address), url.scheme != nil else { inputError = "Enter a valid URL."; return }
                    if resolveProvider {
                        provider.resolveAndPlay(endpoint: address)
                        return
                    }
                    provider.cancel()
                    do {
                        let fields = headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [:] : try JSONDecoder().decode([String: String].self, from: Data(headers.utf8))
                        model.load(url, headers: fields)
                    } catch { inputError = "Headers must be a JSON object with string values." }
                }.disabled(provider.isResolving)
                if provider.isResolving { Button("Cancel resolution") { provider.cancel() } }
                PlayerControls(model: model)
                if let message = inputError { Text(message).foregroundStyle(.red) }
            }.padding()
        }.onChange(of: resolveProvider) { _, _ in provider.stop() }
         .onChange(of: scenePhase) { _, phase in if phase == .background { provider.background() } }
         .onDisappear { provider.stop() }
    }
}

/// Shared presentation for the manual player and the connected episode journey.
struct PlayerControls: View {
    @ObservedObject var model: PlaybackModel
    var body: some View {
        VStack(spacing: 12) {
            VideoPlayer(player: model.player).frame(minHeight: 230)
            HStack {
                Button("−10 s") { model.seek(by: -10) }.accessibilityLabel("Seek backward ten seconds")
                Button("Play") { model.play() }.accessibilityIdentifier("player.play")
                Button("Pause") { model.pause() }.accessibilityIdentifier("player.pause")
                Button("+10 s") { model.seek(by: 10) }.accessibilityLabel("Seek forward ten seconds")
            }
            if model.state == "Buffering" || model.state == "Loading" { ProgressView("Preparing playback…") }
            Text("\(model.state) · \(model.seconds, specifier: "%.1f") s")
                .monospacedDigit().accessibilityIdentifier("player.progress")
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("player.error") }
            Menu("Audio (\(model.audioOptions.count))") {
                ForEach(Array(model.audioOptions.enumerated()), id: \.offset) { _, option in
                    Button(option.displayName) { model.selectAudio(option) }
                }
            }
            Menu("Subtitles (\(model.subtitleOptions.count))") {
                Button("Off") { model.selectSubtitle(nil) }
                ForEach(Array(model.subtitleOptions.enumerated()), id: \.offset) { _, option in
                    Button(option.displayName) { model.selectSubtitle(option) }
                }
            }
            Button("Cancel / release media") { model.stop() }
        }
    }
}
