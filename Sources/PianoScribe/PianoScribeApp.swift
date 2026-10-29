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
            CommandGroup(replacing: .appInfo) {
                Button("About PianoScribe") {
                    // Passed in code rather than via NSHumanReadableCopyright so it also shows when run from Xcode.
                    NSApp.orderFrontStandardAboutPanel(options: [.init(rawValue: "Copyright"): "by Nick Bradbury"])
                }
            }
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
        // A bare executable has no Info.plist icon, so set the Dock icon directly.
        NSApp.applicationIconImage = AppResources.appIcon
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
    static var webDirectory: URL? { url(forResource: "Web", withExtension: nil) }

    static var appIcon: NSImage? {
        url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    static var sampleSong: URL? { url(forResource: "Hannah's Song by Nick Bradbury", withExtension: "m4a") }

    private static func url(forResource name: String, withExtension ext: String?) -> URL? {
        let bundleName = "PianoScribe_PianoScribe.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let b = Bundle(url: root.appendingPathComponent(bundleName)),
               let url = b.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
