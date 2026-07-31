import SwiftUI
import WebKit

// MARK: - 百应登录页（可交互 WebView，共享 Cookie）
struct LoginWebView: UIViewRepresentable {
    let manager: WebCaptureManager

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()  // 与后台采集共享登录态
        // 桌面版 UA（百应官网只适配电脑浏览器）
        let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        config.applicationNameForUserAgent = desktopUA
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = desktopUA
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 只在首次加载时导航
        if uiView.url == nil {
            uiView.load(URLRequest(url: manager.buyinLoginURLForWeb))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView

        init(_ parent: LoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 登录成功跳转后，可能已进入控制台
            if let url = webView.url?.absoluteString {
                print("[AiLive] 登录页导航: \(url)")
            }
        }
    }
}
