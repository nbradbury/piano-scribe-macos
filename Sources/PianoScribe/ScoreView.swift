import AppKit
import SwiftUI
import WebKit

/// Owns the WKWebView that renders MusicXML with Verovio (Resources/Web/score.html).
/// Lives as long as the app (owned by AppState.shared), so registering itself as the
/// script message handler is fine.
@MainActor
final class ScoreController: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private var ready = false
    private var pendingXML: String?
    private var zoom: Double = 45

    override init() {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        config.userContentController = content
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        content.add(self, name: "score")
        if let dir = AppResources.webDirectory {
            webView.loadFileURL(dir.appendingPathComponent("score.html"), allowingReadAccessTo: dir)
        } else {
            webView.loadHTMLString("<p style='font-family:-apple-system'>Missing Web resources.</p>", baseURL: nil)
        }
    }

    func render(_ xml: String) {
        guard ready else { pendingXML = xml; return }
        pendingXML = nil
        run("window.renderScore(\(Self.jsString(xml)))")
    }

    func setZoom(_ z: Double) {
        zoom = z
        guard ready else { return }
        run("window.setZoom(\(z))")
    }

    private func run(_ script: String) {
        // Every call returns a value so the result bridges cleanly.
        webView.evaluateJavaScript(script + "; true", completionHandler: nil)
    }

    // MARK: Printing (the macOS print panel also offers "Save as PDF")

    func printScore(title: String, window: NSWindow?) {
        guard ready else { return }
        Task { @MainActor in
            // Re-layout into paper-sized Verovio pages, then hand the web view to AppKit printing.
            _ = try? await webView.evaluateJavaScript("window.preparePrint(true); true")
            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = false
            info.topMargin = 36
            info.bottomMargin = 36
            info.leftMargin = 36
            info.rightMargin = 36
            let op = webView.printOperation(with: info)
            op.jobTitle = title
            op.showsPrintPanel = true
            op.showsProgressPanel = true
            op.view?.frame = webView.bounds
            // (NSPrintOperation.run() prints blank pages for WKWebView, so always run it as a sheet.)
            guard let window = window ?? webView.window else { endPrint(); return }
            op.runModal(for: window, delegate: self,
                        didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc nonisolated func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.endPrint() }
    }

    private func endPrint() {
        run("window.preparePrint(false)")
    }

    // MARK: Messages from score.html

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
        handle(event: event, detail: body["message"] as? String)
    }

    private func handle(event: String, detail: String?) {
        switch event {
        case "ready":
            ready = true
            if zoom != 45 { setZoom(zoom) }
            if let xml = pendingXML { render(xml) }
        case "error":
            NSLog("Verovio error: %@", detail ?? "unknown")
        default:
            break
        }
    }

    static func jsString(_ s: String) -> String {
        // JSON-encode via a one-element array, then strip the brackets.
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}

struct ScoreView: NSViewRepresentable {
    let controller: ScoreController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
