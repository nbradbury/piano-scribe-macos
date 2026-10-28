import AVFoundation
import Foundation

/// Plays either the transcribed score (MIDI through the built-in General MIDI synth) or the original recording.
@MainActor
final class Playback: ObservableObject {
    enum Source { case idle, score, original }
    @Published private(set) var playing: Source = .idle

    private var midiPlayer: AVMIDIPlayer?
    private var audioPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func playMIDI(_ data: Data) {
        stop()
        do {
            // nil sound bank = the default General MIDI bank built into macOS.
            let player = try AVMIDIPlayer(data: data, soundBankURL: nil)
            player.prepareToPlay()
            midiPlayer = player
            playing = .score
            player.play { [weak self] in
                Task { @MainActor in
                    if self?.midiPlayer === player { self?.playing = .idle }
                }
            }
        } catch {
            NSLog("MIDI playback failed: %@", error.localizedDescription)
            playing = .idle
        }
    }

    func playSource(_ url: URL) {
        stop()
        let player = AVPlayer(url: url)
        audioPlayer = player
        playing = .original
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playing = .idle }
        }
        player.play()
    }

    func stop() {
        midiPlayer?.stop()
        midiPlayer = nil
        audioPlayer?.pause()
        audioPlayer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playing = .idle
    }
}
