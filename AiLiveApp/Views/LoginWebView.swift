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
                let phase = parent.manager.loginPhase
                // v11.16 分步状态机：buyin登录 → compass建Cookie → 大屏 → 完成
                if phase == .buyinLogin && !url.contains("login") && !url.contains("passport") && !url.contains("douyinec") {
                    // buyin 登录成功（进入控制台/任意非登录页）
                    parent.manager.isLoggedIn = true
                    parent.manager.loginDetectCount = 0
                    parent.manager.addLog("🎉 buyin 登录成功！")
                    parent.manager.continueOrderLogin()
                } else if phase == .compassVisit && url.contains("compass.jinritemai.com") {
                    // compass 主页加载完成 → 已建立 compass 域 Cookie
                    parent.manager.compassVisitedOK()
                } else if phase == .finished && url.contains("compass.jinritemai.com/screen") {
                    // 大屏页加载完成 = 全部登录完成
                    parent.manager.addLog("✅ 统一登录完成！评论+订单都可采集")
                    parent.manager.closeLogin()
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
