import AppKit
import SwiftUI

@main
struct PianoScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup("PianoScribe") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 960, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { state.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export MusicXML…") { state.exportMusicXML() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(state.musicXML == nil)
                Button("Export MIDI…") { state.exportMIDI(asPlayed: false) }
                    .disabled(state.score == nil)
                Button("Open in Notation App") { state.openInNotationApp() }
                    .disabled(state.musicXML == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print / Save as PDF…") { state.printScore() }
                    .keyboardShortcut("p")
                    .disabled(state.musicXML == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (swift run / Xcode) so the window comes to front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            Task { @MainActor in AppState.shared.open(url) }
        }
    }
}

enum AppResources {
    /// The bundled Web folder (score.html + Verovio), in a packaged .app or a SwiftPM/Xcode build.
    static var webDirectory: URL? {
        let bundleName = "PianoScribe_PianoScribe.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let b = Bundle(url: root.appendingPathComponent(bundleName)),
               let url = b.url(forResource: "Web", withExtension: nil) {
                return url
            }
        }
        return Bundle.module.url(forResource: "Web", withExtension: nil)
    }
}
