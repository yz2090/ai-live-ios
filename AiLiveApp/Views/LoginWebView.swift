import SwiftUI
import WebKit

// MARK: - 百应登录页（可交互 WebView，共享 Cookie）
struct LoginWebView: UIViewRepresentable {
    let manager: WebCaptureManager
    var url: URL? = nil   // 可指定登录哪个页面（buyin 或 compass）

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()  // 与后台采集共享登录态
        // v11.16: 桌面 Chrome UA（百应大屏对 Safari/WebKit UA 返回"已结束"降级页）
        let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = desktopUA
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // v11.17 手动模式：只在首次加载目标页，之后完全由用户控制跳转（不强制回跳）
        let targetURL = url ?? manager.loginURL
        if uiView.url == nil {
            uiView.load(URLRequest(url: targetURL))
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
            // v11.17 手动模式：不做任何自动跳转/自动关闭
            // 用户自己在窗口里登录、跳转，完成后点"✓ 完成"关闭
            if let url = webView.url?.absoluteString {
                print("[AiLive] 登录页导航: \(url)")
                parent.manager.addLog("🌐 \(url.prefix(60))")
            }
        }

        // 拦截 window.open 新窗口：返回 nil 会导致 WebKit 丢弃导航（点链接没反应）
        // v11.18: 新窗口导航统一在 decidePolicyFor 里处理（targetFrame == nil → 当前 WebView 打开）
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // 返回 nil：不创建新窗口。新窗口导航已由 decidePolicyFor 拦截并转入当前 WebView
            return nil
        }

        // 导航策略：新窗口链接（target=_blank / window.open）→ 当前 WebView 打开；抖音唤起协议 → 系统打开
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if Self.isAppScheme(url) {
                    UIApplication.shared.open(url, options: [:]) { ok in
                        print("[AiLive] 唤起抖音(策略): \(ok)")
                    }
                    decisionHandler(.cancel)
                    return
                }
                // 新窗口导航（targetFrame == nil）：强制在当前 WebView 打开，否则点击无反应
                if navigationAction.targetFrame == nil {
                    print("[AiLive] 新窗口导航 → 当前页打开: \(url.absoluteString.prefix(80))")
                    webView.load(navigationAction.request)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        private static func isAppScheme(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            let appSchemes = ["snssdk1128", "aweme", "douyin", "bytewebview", "sslocal", "byteimg"]
            return appSchemes.contains(scheme)
        }
    }
}
