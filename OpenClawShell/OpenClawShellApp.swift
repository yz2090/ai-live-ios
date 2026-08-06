import SwiftUI
import WebKit

@main
struct OpenClawShellApp: App {
    var body: some Scene {
        WindowGroup {
            ShellWebView()
                .ignoresSafeArea()
                .statusBarHidden(true)
        }
    }
}

// MARK: - WKWebView 壳：全屏加载 OpenClaw 网关面板
struct ShellWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.isOpaque = false
        let serverURL = Bundle.main.object(forInfoDictionaryKey: "ServerURL") as? String ?? ""
        if let url = URL(string: serverURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
