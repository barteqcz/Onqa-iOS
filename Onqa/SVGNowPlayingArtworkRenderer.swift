import UIKit
import WebKit

/// Rasterizes SVG station art for MPNowPlayingInfoCenter. The in-app logo
/// can display SVG in a WKWebView, but MPMediaItemArtwork requires a UIImage.
@MainActor
final class SVGNowPlayingArtworkRenderer: NSObject, WKNavigationDelegate {
    private static let artworkSize = CGSize(width: 512, height: 512)

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// A logo that never finishes rendering must not hang its caller forever.
    private static let renderTimeout: Duration = .seconds(8)

    static func render(data: Data) async -> UIImage? {
        let renderer = SVGNowPlayingArtworkRenderer()
        return await renderer.load(data: data)
    }

    private func load(data: Data) async -> UIImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let configuration = WKWebViewConfiguration()
            let view = WKWebView(
                frame: CGRect(origin: .zero, size: Self.artworkSize),
                configuration: configuration
            )
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.backgroundColor = .clear
            view.scrollView.isScrollEnabled = false
            view.scrollView.bounces = false
            view.scrollView.contentInsetAdjustmentBehavior = .never
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            view.navigationDelegate = self
            self.webView = view

            let encodedSVG = data.base64EncodedString()
            let html = """
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
              <style>
                html, body {
                  width: 100%;
                  height: 100%;
                  margin: 0;
                  padding: 0;
                  overflow: hidden;
                  background: transparent;
                }
                body {
                  display: flex;
                  align-items: center;
                  justify-content: center;
                }
                img {
                  display: block;
                  width: 100%;
                  height: 100%;
                  object-fit: contain;
                }
              </style>
            </head>
            <body><img id="station-artwork" src="data:image/svg+xml;base64,\(encodedSVG)" alt=""></body>
            </html>
            """
            view.loadHTMLString(html, baseURL: nil)

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.renderTimeout)
                guard !Task.isCancelled else { return }
                Log.playback.debug("SVG logo rendering timed out")
                self?.finish(with: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            "document.getElementById('station-artwork').naturalWidth > 0"
        ) { [weak self, weak webView] result, error in
            guard
                error == nil,
                (result as? Bool) == true,
                let self,
                let webView
            else {
                self?.finish(with: nil)
                return
            }

            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: Self.artworkSize)
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self, let image else {
                    self?.finish(with: nil)
                    return
                }
                self.finish(with: image)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(with: nil)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(with: nil)
    }

    private func finish(with image: UIImage?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(returning: image)
    }
}
