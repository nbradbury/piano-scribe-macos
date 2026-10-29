import ScoreKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false

    var body: some View {
        // Not NavigationSplitView: a .grouped Form in its sidebar column doesn't receive clicks
        // (each control ends up under a non-hit-testable section clip view).
        HStack(spacing: 0) {
            SettingsSidebar().frame(width: 300)
            Divider()
            ZStack {
                ScoreView(controller: state.scoreView)
                    .opacity(state.musicXML == nil ? 0 : 1)
                overlay
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in AppState.shared.open(url) } }
                }
                return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle(state.sourceURL?.lastPathComponent ?? "PianoScribe")
        .toolbar { toolbar }
    }

    @ViewBuilder private var overlay: some View {
        switch state.phase {
        case .idle:
            VStack(spacing: 14) {
                Image(systemName: "pianokeys")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop a video or audio file here")
                    .font(.title2)
                Text("MP4, MOV, M4A, MP3, WAV… Works best on solo piano recordings.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open…") { state.presentOpenPanel() }
                        .keyboardShortcut(.defaultAction)
                    if let sample = AppResources.sampleSong {
                        Button("Use Sample Song") { state.open(sample) }
                    }
                }
                .controlSize(.large)
            }
            .padding(40)
        case .loadingAudio:
            ProgressCard(title: "Reading audio…", fraction: nil)
        case .loadingModel:
            ProgressCard(title: "Preparing the transcription model…", fraction: nil)
        case .transcribing(let f):
            ProgressCard(title: "Listening for notes…", fraction: f)
        case .building where state.musicXML == nil:
            ProgressCard(title: "Writing the score…", fraction: nil)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Open Another File…") { state.presentOpenPanel() }
            }
            .padding(40)
        default:
            EmptyView()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { state.presentOpenPanel() } label: { Label("Open", systemImage: "folder") }
                .help("Open a video or audio file")

            PlaybackButtons(playback: state.playback)

            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $state.zoom, in: 25...90)
                    .frame(width: 110)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .help("Zoom")
            .disabled(state.musicXML == nil)

            Menu {
                Button("MusicXML…") { state.exportMusicXML() }
                Button("MIDI (as notated)…") { state.exportMIDI(asPlayed: false) }
                Button("MIDI (as played)…") { state.exportMIDI(asPlayed: true) }
                Divider()
                Button("Open in Notation App") { state.openInNotationApp() }
                Button("Print / Save as PDF…") { state.printScore() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(state.musicXML == nil)
        }
    }
}

private struct PlaybackButtons: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var playback: Playback

    var body: some View {
        if playback.playing == .idle {
            Button { state.playScore() } label: { Label("Play Score", systemImage: "play.fill") }
                .help("Play the transcription")
                .disabled(state.score == nil)
            Button { state.playOriginal() } label: { Label("Play Original", systemImage: "waveform") }
                .help("Play the original recording")
                .disabled(state.sourceURL == nil)
        } else {
            Button { playback.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .help("Stop playback")
        }
    }
}

private struct ProgressCard: View {
    let title: String
    let fraction: Double?

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            if let fraction {
                ProgressView(value: fraction).frame(width: 260)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Settings

struct SettingsSidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Score") {
                TextField("Title", text: $state.notation.title)

                Picker("Time signature", selection: $state.notation.timeSignature) {
                    ForEach(TimeSignature.allCases) { Text($0.rawValue).tag($0) }
                }

                Picker("Key", selection: $state.notation.keyFifths) {
                    Text(autoKeyLabel).tag(Int?.none)
                    Divider()
                    ForEach(-7...7, id: \.self) { f in
                        Text(KeyNames.label(fifths: f)).tag(Int?.some(f))
                    }
                }

                tempoControls

                Picker("Rhythm grid", selection: $state.notation.grid) {
                    Text("16th notes").tag(GridResolution.sixteenth)
                    Text("8th notes (simpler)").tag(GridResolution.eighth)
                }

                handControls
            }

            Section {
                LabeledSlider(title: "Note sensitivity", value: invertedBinding(\.onsetThreshold), range: 0.1...0.9,
                              format: { String(format: "%.0f%%", $0 * 100) })
                    .help("Higher finds more notes (lower onset threshold)")
                LabeledSlider(title: "Sustain sensitivity", value: invertedBinding(\.frameThreshold), range: 0.3...0.9,
                              format: { String(format: "%.0f%%", $0 * 100) })
                    .help("Higher keeps notes ringing longer (lower frame threshold)")
                LabeledSlider(title: "Shortest note", value: $state.decoding.minNoteLengthMs, range: 30...300,
                              format: { String(format: "%.0f ms", $0) })
                Toggle("Find notes without clear attacks", isOn: $state.decoding.melodiaTrick)
                Toggle("Remove overtone ghosts", isOn: $state.notation.removeOvertones)
                Button("Reset Detection Settings") {
                    state.decoding = DecodingOptions()
                    state.notation.removeOvertones = true
                }
            } header: {
                Text("Note detection")
            } footer: {
                Text("Changes apply instantly; the recording isn't re-analyzed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let score = state.score {
                Section("Result") {
                    LabeledContent("Notes", value: "\(state.noteCount)")
                    LabeledContent("Measures", value: "\(score.measureCount)")
                    LabeledContent("Length", value: Self.duration(state.audioDuration))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var autoKeyLabel: String {
        if let k = state.detectedKey { return "Automatic (\(KeyNames.name(fifths: k.fifths, mode: k.mode)))" }
        return "Automatic"
    }

    @ViewBuilder private var tempoControls: some View {
        Toggle("Detect tempo", isOn: Binding(
            get: { state.notation.tempo == nil },
            set: { auto in state.notation.tempo = auto ? nil : state.displayedTempo.rounded() }))
        HStack {
            Text("Tempo")
            Spacer()
            if state.notation.tempo == nil {
                Text("\(Int(state.displayedTempo.rounded())) BPM").foregroundStyle(.secondary)
            } else {
                TextField("BPM", value: Binding(
                    get: { state.notation.tempo ?? 100 },
                    set: { state.notation.tempo = min(260, max(30, $0)) }), format: .number.precision(.fractionLength(0)))
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: Binding(
                    get: { state.notation.tempo ?? 100 },
                    set: { state.notation.tempo = min(260, max(30, $0)) }), in: 30...260, step: 1)
                    .labelsHidden()
            }
        }
        HStack {
            Text("Notes look too fast or slow?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("½×") { state.scaleTempo(0.5) }.help("Halve the tempo (shorter note values become longer)")
            Button("2×") { state.scaleTempo(2) }.help("Double the tempo")
        }
        .disabled(state.score == nil)
    }

    @ViewBuilder private var handControls: some View {
        Picker("Hands", selection: Binding(
            get: { if case .fixed = state.notation.hands { return 1 } else { return 0 } },
            set: { state.notation.hands = $0 == 0 ? .automatic : .fixed(splitPitch: 60) })) {
            Text("Automatic").tag(0)
            Text("Split at a note").tag(1)
        }
        if case .fixed(let split) = state.notation.hands {
            Stepper(value: Binding(
                get: { split },
                set: { state.notation.hands = .fixed(splitPitch: min(84, max(36, $0))) }), in: 36...84) {
                HStack {
                    Text("Right hand from")
                    Spacer()
                    Text(KeyNames.pitchName(split)).monospacedDigit()
                }
            }
        }
    }

    /// The UI shows "sensitivity" (higher = more notes); Basic Pitch uses thresholds (lower = more notes).
    private func invertedBinding(_ keyPath: WritableKeyPath<DecodingOptions, Double>) -> Binding<Double> {
        Binding(get: { 1 - state.decoding[keyPath: keyPath] },
                set: { state.decoding[keyPath: keyPath] = 1 - $0 })
    }

    static func duration(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range)
                .labelsHidden()
        }
    }
}

enum KeyNames {
    static let major = ["C♭", "G♭", "D♭", "A♭", "E♭", "B♭", "F", "C", "G", "D", "A", "E", "B", "F♯", "C♯"]
    static let minor = ["A♭", "E♭", "B♭", "F", "C", "G", "D", "A", "E", "B", "F♯", "C♯", "G♯", "D♯", "A♯"]

    static func name(fifths: Int, mode: String) -> String {
        let i = max(-7, min(7, fifths)) + 7
        return mode == "minor" ? "\(minor[i]) minor" : "\(major[i]) major"
    }

    static func label(fifths: Int) -> String {
        let acc = fifths == 0 ? "no ♯/♭" : fifths > 0 ? "\(fifths)♯" : "\(-fifths)♭"
        return "\(name(fifths: fifths, mode: "major")) / \(name(fifths: fifths, mode: "minor")) (\(acc))"
    }

    static func pitchName(_ midi: Int) -> String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return "\(names[midi % 12])\(midi / 12 - 1)"
    }
}
