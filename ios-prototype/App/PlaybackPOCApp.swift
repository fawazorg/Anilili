import SwiftUI
import AVKit

@main
struct PlaybackPOCApp: App {
    var body: some Scene { WindowGroup { PlaybackView() } }
}

struct PlaybackView: View {
    @StateObject private var model = PlaybackModel()
    @State private var address = ""
    @State private var headers = ""
    @State private var inputError: String?
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Anilili playback proof of concept").font(.headline)
                TextField("Supplied video URL", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                TextField("Request headers as JSON (optional)", text: $headers)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Text("User-Agent is supported. Other headers are reported as unsupported. No credentials are stored.").font(.caption)
                Button("Load") {
                    inputError = nil
                    guard let url = URL(string: address), url.scheme != nil else { inputError = "Enter a valid URL."; return }
                    do {
                        let fields = headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [:] : try JSONDecoder().decode([String: String].self, from: Data(headers.utf8))
                        model.load(url, headers: fields)
                    } catch { inputError = "Headers must be a JSON object with string values." }
                }
                VideoPlayer(player: model.player).frame(height: 230)
                HStack {
                    Button("−10 s") { model.seek(by: -10) }
                    Button("Play") { model.play() }
                    Button("Pause") { model.pause() }
                    Button("+10 s") { model.seek(by: 10) }
                }
                Button("Cancel / release media") { model.stop() }
                Text("\(model.state) · \(model.seconds, specifier: "%.1f") s")
                if let message = inputError ?? model.errorMessage { Text(message).foregroundStyle(.red) }
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
            }.padding()
        }.onDisappear { model.stop() }
    }
}
