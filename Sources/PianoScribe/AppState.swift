import AppKit
import Foundation
import ScoreKit
import SwiftUI
import Transcriber
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case loadingAudio
        case loadingModel
        case transcribing(Double)
        case building
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .loadingAudio, .loadingModel, .transcribing, .building: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sourceURL: URL?
    @Published private(set) var audioDuration: Double = 0
    @Published private(set) var score: Score?
    @Published private(set) var musicXML: String? {
        didSet { if let xml = musicXML { scoreView.render(xml) } }
    }
    @Published private(set) var noteCount = 0
    @Published private(set) var detectedKey: (fifths: Int, mode: String)?

    @Published var decoding = DecodingOptions() { didSet { if decoding != oldValue { scheduleRebuild(redecode: true) } } }
    @Published var notation = NotationOptions() { didSet { if notation != oldValue { scheduleRebuild(redecode: false) } } }
    @Published var zoom: Double = 45 { didSet { scoreView.setZoom(zoom) } }

    let scoreView = ScoreController()
    let playback = Playback()

    private var activations: ModelActivations?
    private var events: [NoteEvent] = []
    private var needsRedecode = true
    private var model: BasicPitchModel?
    private var job: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildGeneration = 0

    // MARK: Opening & transcription

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video or audio recording of piano music"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        job?.cancel()
        rebuildTask?.cancel()
        rebuildGeneration += 1
        playback.stop()
        sourceURL = url
        activations = nil
        events = []
        needsRedecode = true
        score = nil
        musicXML = nil
        noteCount = 0
        detectedKey = nil
        notation.title = url.deletingPathExtension().lastPathComponent
        phase = .loadingAudio

        job = Task { [weak self] in
            guard let self else { return }
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                let audio = try await AudioDecoder.decode(url: url)
                try Task.checkCancellation()
                guard audio.count > BasicPitch.sampleRate / 4 else { throw TranscriberError.noAudioTrack }
                self.audioDuration = Double(audio.count) / Double(BasicPitch.sampleRate)

                self.phase = .loadingModel
                let model = try await self.loadModel()
                self.phase = .transcribing(0)

                let act = try await Self.runModel(model, audio: audio) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .transcribing = self.phase { self.phase = .transcribing(fraction) }
                    }
                }
                try Task.checkCancellation()
                self.activations = act
                await self.rebuild()
            } catch is CancellationError {
                // a newer file was opened
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func loadModel() async throws -> BasicPitchModel {
        if let model { return model }
        let m = try await BasicPitchModel.load()
        model = m
        return m
    }

    /// Runs inference off the main actor; cancellation of the calling task is forwarded.
    nonisolated private static func runModel(_ model: BasicPitchModel, audio: [Float],
                                             progress: @escaping @Sendable (Double) -> Void) async throws -> ModelActivations {
        let work = Task.detached(priority: .userInitiated) {
            try model.activations(for: audio, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: Score building (re-runs quickly whenever a setting changes)

    private func scheduleRebuild(redecode: Bool) {
        if redecode { needsRedecode = true }
        guard activations != nil else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        guard let act = activations else { return }
        let decodingOptions = decoding
        let notationOptions = notation
        let redecode = needsRedecode || events.isEmpty
        let cached = events
        rebuildGeneration += 1
        let generation = rebuildGeneration
        phase = .building

        let result = await Task.detached(priority: .userInitiated) { () -> Result<([NoteEvent], Score, String), Error> in
            do {
                let ev = redecode ? BasicPitch.decode(act, options: decodingOptions) : cached
                let sc = try ScoreBuilder.build(notes: ev, options: notationOptions)
                return .success((ev, sc, MusicXMLWriter.write(sc)))
            } catch {
                return .failure(error)
            }
        }.value

        // Ignore results from a build that a newer one (or a newly opened file) has superseded.
        guard !Task.isCancelled, generation == rebuildGeneration, activations != nil else { return }
        switch result {
        case .success(let (ev, sc, xml)):
            events = ev
            if redecode { needsRedecode = false }
            noteCount = ev.count
            if notationOptions.keyFifths == nil { detectedKey = (sc.keyFifths, sc.mode) }
            score = sc
            musicXML = xml
            phase = .ready
        case .failure(let error):
            if redecode { events = []; needsRedecode = false }
            score = nil
            musicXML = nil
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Tempo helpers

    var displayedTempo: Double { notation.tempo ?? score?.tempo ?? 100 }

    func scaleTempo(_ factor: Double) {
        notation.tempo = min(260, max(30, (displayedTempo * factor).rounded()))
    }

    // MARK: Export

    private var baseName: String { sourceURL?.deletingPathExtension().lastPathComponent ?? "Transcription" }

    func exportMusicXML() {
        guard let xml = musicXML else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "musicxml") ?? .xml]
        panel.nameFieldStringValue = baseName + ".musicxml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try xml.write(to: url, atomically: true, encoding: .utf8) } catch { showError(error) }
    }

    func exportMIDI(asPlayed: Bool) {
        guard let data = midiData(asPlayed: asPlayed) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.midi]
        panel.nameFieldStringValue = baseName + (asPlayed ? " (as played)" : "") + ".mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) } catch { showError(error) }
    }

    func midiData(asPlayed: Bool) -> Data? {
        guard let score else { return nil }
        if asPlayed {
            var notes = events
            if notation.removeOvertones { notes = Rhythm.removeOvertones(notes.sorted { $0.start < $1.start }) }
            return MIDIWriter.performance(notes, quarterBPM: score.quarterTempo)
        }
        return MIDIWriter.quantized(score)
    }

    /// Writes the MusicXML to a temporary file and opens it in the default app (MuseScore, Dorico, Finale…).
    func openInNotationApp() {
        guard let xml = musicXML else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PianoScribe", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(baseName + ".musicxml")
            try xml.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            showError(error)
        }
    }

    func printScore() {
        guard musicXML != nil else { return }
        scoreView.printScore(title: notation.title, window: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    // MARK: Playback

    func playScore() {
        guard let data = midiData(asPlayed: false) else { return }
        playback.playMIDI(data)
    }

    func playOriginal() {
        guard let url = sourceURL else { return }
        playback.playSource(url)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
