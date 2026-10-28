// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PianoScribe",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ScoreKit", targets: ["ScoreKit"]),
    ],
    targets: [
        // Pure Swift: Basic Pitch post-processing, rhythm/key/hand analysis, MusicXML + MIDI writers.
        .target(name: "ScoreKit"),
        .testTarget(name: "ScoreKitTests", dependencies: ["ScoreKit"], resources: [.copy("Fixtures")]),
    ]
)

#if os(macOS)
package.products.append(.executable(name: "PianoScribe", targets: ["PianoScribe"]))
package.targets += [
    // AVFoundation audio extraction + Core ML inference (bundles Spotify's Basic Pitch model).
    .target(
        name: "Transcriber",
        dependencies: ["ScoreKit"],
        resources: [.copy("Resources/nmp.mlpackage")]
    ),
    // SwiftUI app. Sheet music is rendered by Verovio (bundled JS/WASM) in a WKWebView.
    .executableTarget(
        name: "PianoScribe",
        dependencies: ["ScoreKit", "Transcriber"],
        resources: [.copy("Resources/Web")]
    ),
    .testTarget(name: "TranscriberTests", dependencies: ["Transcriber", "ScoreKit"], resources: [.copy("Fixtures")]),
]
#endif
