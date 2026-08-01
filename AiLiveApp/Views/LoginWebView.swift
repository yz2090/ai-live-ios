import SwiftUI
import WebKit

// MARK: - 百应登录页（可交互 WebView，共享 Cookie）
struct LoginWebView: UIViewRepresentable {
    let manager: WebCaptureManager
    var url: URL? = nil   // 可指定登录哪个页面（buyin 或 compass）

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
        // url 变化时重新导航（统一登录：buyin 成功 → 自动跳 compass）
        let targetURL = url ?? manager.loginURL
        if uiView.url == nil || uiView.url?.absoluteString != targetURL.absoluteString {
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
            // 登录成功跳转后，可能已进入控制台
            if let url = webView.url?.absoluteString {
                print("[AiLive] 登录页导航: \(url)")
                // buyin 登录成功（进入控制台）→ 自动跳 compass 补登订单
                if url.contains("live/control") {
                    parent.manager.isLoggedIn = true
                    parent.manager.loginDetectCount = 0
                    parent.manager.addLog("🎉 buyin 登录成功！自动跳 compass 补登…")
                    parent.manager.continueOrderLogin()
                }
                // compass 大屏页加载成功 = 订单采集可用，且已在补登阶段 → 全部完成，自动关闭
                if url.contains("compass.jinritemai.com/screen") && parent.manager.isCompassStep {
                    // 大屏页能正常加载（未跳登录页）= 继承登录态成功
                    parent.manager.addLog("✅ 统一登录完成！评论+订单都可采集")
                    parent.manager.closeLogin()
                } else if url.contains("compass.jinritemai.com/screen") {
                    // compass 需要独立登录（未继承 buyin 态）→ 停在页面让用户扫码
                    parent.manager.addLog("📊 大屏需要登录，请扫码（订单采集）")
                }
            }
        }

        // 拦截 window.open 新窗口：在当前 WebView 打开（百应用新窗口弹授权）
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if Self.isAppScheme(url) {
                    // 抖音唤起协议 → 系统打开抖音 App
                    UIApplication.shared.open(url, options: [:]) { ok in
                        print("[AiLive] 唤起抖音: \(ok)")
                    }
                } else {
                    webView.load(URLRequest(url: url))
                }
            }
            return nil
        }

        // 导航策略：拦截抖音唤起协议交给系统
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, Self.isAppScheme(url) {
                UIApplication.shared.open(url, options: [:]) { ok in
                    print("[AiLive] 唤起抖音(策略): \(ok)")
                }
                decisionHandler(.cancel)
                return
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
