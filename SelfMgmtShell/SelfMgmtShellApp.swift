import SwiftUI
import WebKit

@main
struct SelfMgmtShellApp: App {
    var body: some Scene {
        WindowGroup {
            ShellWebView()
                .ignoresSafeArea()
                .statusBarHidden(false)
        }
    }
}

// MARK: - WKWebView 壳：全屏加载个人管理网页
struct ShellWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1) // 深蓝底色，配合网页
        let serverURL = Bundle.main.object(forInfoDictionaryKey: "ServerURL") as? String ?? ""
        if let url = URL(string: serverURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
