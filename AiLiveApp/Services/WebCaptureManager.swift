import Foundation
import WebKit
import Combine

// MARK: - 网页采集管理器：后台 WKWebView 加载百应控制台，JS 抓评论 → POST 服务器
class WebCaptureManager: NSObject, ObservableObject {
    static let shared = WebCaptureManager()

    @Published var isRunning = false
    @Published var lastStatus = "未启动"
    @Published var capturedCount = 0
    @Published var recentLog: String = ""
    @Published var showLoginSheet = false   // 是否显示登录 WebView
    @Published var isLoggedIn = false       // 是否已登录（检测到评论区元素）

    private var webView: WKWebView?
    private var loginWebView: WKWebView?   // 登录用可视 WebView（共享Cookie）
    private var deviceId: String = ""
    private var serverHost = kServerHost
    private var serverPort = kServerPort
    private var seenKeys = Set<String>()
    private var timer: Timer?
    var loginDetectCount = 0        // 连续检测到未登录的次数

    // 百应直播中控台（登录后自动跳转到这里采集）
    private let buyinConsoleURL = URL(string: "https://buyin.jinritemai.com/dashboard/live/control?btm_ppre=a0.b0.c0.d0&btm_pre=a10091.b089178.c809509.d0&btm_show_id=1ea37d54-1224-4379-b7e3-483630e500c9&pre_universal_page_params_id=&universal_page_params_id=eba566c6-400f-4464-9ebf-dc368e39aa88")!

    // 首次加载页面：达人工作台登录页（用户提供，type=24）
    private let buyinURL = URL(string: "https://buyin.jinritemai.com/mpa/account/login?log_out=1&type=24")!

    // 百应登录页（扫码登录）
    private let buyinLoginURL = URL(string: "https://buyin.jinritemai.com/mpa/account/login?log_out=1&type=24")!
    // 供登录 WebView 使用的公开登录地址
    var buyinLoginURLForWeb: URL { buyinLoginURL }

    // 注入 JS：每1.5秒扫描评论区新增文本，通过 WebKit message handler 回传
    private let captureJS = """
    (function() {
        if (window.__capInit) return;
        window.__capInit = true;
        window.__capSeen = new Set();
        setInterval(function() {
            var texts = [];
            var nodes = document.querySelectorAll(
                '[class*="comment"] [class*="content"], ' +
                '[class*="comment"] [class*="text"], ' +
                '[class*="danmaku"] [class*="content"], ' +
                '[class*="danmaku"] [class*="text"], ' +
                '[class*="chat"] [class*="content"], ' +
                '[class*="chat"] [class*="text"], ' +
                '[class*="message"] [class*="content"]'
            );
            for (var i = 0; i < nodes.length; i++) {
                var t = nodes[i].innerText || nodes[i].textContent || '';
                t = t.trim();
                if (t.length < 2 || t.length > 200) continue;
                var key = t + '_' + nodes[i].getBoundingClientRect().top.toFixed(0);
                if (!window.__capSeen.has(key)) {
                    window.__capSeen.add(key);
                    texts.push(t);
                }
            }
            if (texts.length > 0) {
                try {
                    window.webkit.messageHandlers.capBridge.postMessage(texts.join('\\n'));
                } catch(e) {}
            }
        }, 1500);
    })();
    """

    override private init() {
        super.init()
        deviceId = UserDefaults.standard.string(forKey: "ailive_iphone_device_id") ?? ""
        if deviceId.isEmpty {
            deviceId = "iphone_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(14).lowercased()
            UserDefaults.standard.set(deviceId, forKey: "ailive_iphone_device_id")
        }
    }

    // MARK: - 启动/停止
    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastStatus = "启动中…"
        addLog("🌐 网页采集启动")

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "capBridge")
        config.userContentController = userContentController

        // 允许 Cookie 持久化（登录态）
        let websiteDataStore = WKWebsiteDataStore.default()
        config.websiteDataStore = websiteDataStore

        // === MOD: 2026-07-31 强制桌面版浏览器（百应官网只适配电脑浏览器） ===
        // 用桌面 Safari UA，让百应打开电脑版界面（含评论区，可正常采集）
        let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        config.applicationNameForUserAgent = desktopUA

        webView = WKWebView(frame: .zero, configuration: config)
        webView?.navigationDelegate = self
        webView?.customUserAgent = desktopUA
        webView?.load(URLRequest(url: buyinURL))
        addLog("📄 加载百应控制台（桌面版）…")

        // 定时检查状态
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lastStatus = "已停止"
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "capBridge")
        webView = nil
        addLog("🛑 网页采集停止")
    }

    private func checkStatus() {
        guard let webView = webView else { return }
        webView.evaluateJavaScript("document.readyState") { [weak self] result, error in
            guard let self = self else { return }
            if let state = result as? String {
                self.lastStatus = "页面状态: \(state)"
                if state == "complete" {
                    self.checkLoginState()
                    self.injectCaptureJS()
                }
            }
        }
    }

    /// 检测是否已登录：看页面里有没有评论区元素 / 是否跳到了登录页
    private func checkLoginState() {
        guard let webView = webView else { return }
        let js = """
        (function() {
            var url = window.location.href;
            var hasComment = document.querySelectorAll(
                '[class*="comment"], [class*="danmaku"], [class*="chat"]'
            ).length > 0;
            var isLoginPage = url.indexOf('login') > -1 || url.indexOf('passport') > -1 ||
                document.querySelector('input[type="password"], [class*="qrcode"], [class*="login"]') != null;
            return JSON.stringify({hasComment: hasComment, isLoginPage: isLoginPage, url: url});
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            if let s = result as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                let hasComment = d["hasComment"] as? Bool ?? false
                let isLoginPage = d["isLoginPage"] as? Bool ?? false
                let currentURL = d["url"] as? String ?? ""

                if hasComment {
                    // 已登录且在控制台 → 正常采集
                    self.isLoggedIn = true
                    self.loginDetectCount = 0
                    self.lastStatus = "已登录，采集中"
                } else if isLoginPage {
                    self.loginDetectCount += 1
                    self.isLoggedIn = false
                    self.lastStatus = "⚠️ 需要登录百应"
                    if self.loginDetectCount >= 2 && !self.showLoginSheet {
                        self.addLog("🔐 检测到未登录，请点击「百应登录」扫码登录")
                    }
                } else if !currentURL.contains("live/control") && !self.isLoggedIn {
                    // 已登录但不在控制台（比如登录成功后停在登录页/首页）→ 自动跳转控制台
                    self.addLog("🔁 已登录，自动跳转直播控制台…")
                    self.loadConsole()
                } else {
                    // 既没检测到评论区也没检测到登录页：可能页面还在加载或布局变了
                    self.lastStatus = "等待页面加载…"
                }
            }
        }
    }

    /// 跳转到直播控制台（采集页）
    func loadConsole() {
        guard let webView = webView else { return }
        webView.load(URLRequest(url: buyinConsoleURL))
        addLog("📄 加载直播控制台…")
    }

    // MARK: - 登录
    func openLogin() {
        showLoginSheet = true
        if loginWebView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore.default()  // 共享 Cookie
            // 桌面版 UA（百应只适配电脑浏览器）
            let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
            config.applicationNameForUserAgent = desktopUA
            loginWebView = WKWebView(frame: .zero, configuration: config)
            loginWebView?.customUserAgent = desktopUA
            loginWebView?.navigationDelegate = self
            loginWebView?.load(URLRequest(url: buyinLoginURL))
        }
        addLog("🔐 打开百应登录页（桌面版）…")
    }

    func closeLogin() {
        showLoginSheet = false
        loginWebView?.stopLoading()
        loginWebView = nil
        // 关闭登录后重新检测（可能已登录）
        loginDetectCount = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkLoginState()
        }
    }

    private func injectCaptureJS() {
        guard let webView = webView else { return }
        webView.evaluateJavaScript(captureJS) { [weak self] _, error in
            if let error = error {
                self?.addLog("⚠️ JS注入失败: \(error.localizedDescription)")
            } else {
                self?.addLog("✅ 评论抓取JS已注入")
                self?.lastStatus = "采集中"
            }
        }
    }

    // MARK: - 评论处理：过滤 + POST 服务器
    private func handleComments(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count < 2 || t.count > 200 { continue }
            if isSystemText(t) { continue }
            // 去重（App 层再兜底）
            let key = t
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)
            if seenKeys.count > 5000 { seenKeys.removeAll() }

            capturedCount += 1
            addLog("💬 \(t)")
            postToServer(t)
        }
    }

    private static let filterWords: Set<String> = [
        "进入", "来了", "直播间", "浏览", "送出", "分享", "粉丝", "购物车",
        "小黄车", "心愿", "优惠", "红包", "福袋", "灯牌", "升级", "按钮",
        "点赞", "榜单", "人气", "更多", "取消", "确定", "关闭", "返回",
        "搜索", "消息", "推荐", "订单", "退款", "售后", "商品列表", "说点什么",
        "表情入口", "小心心", "礼物", "自建活动", "活动报名", "本机共有",
        "双击清理", "停止直播", "小窗应用", "连接中", "已连接", "截图",
        "保存图片", "编辑", "下载", "管理", "设置", "账号", "登录", "注册",
        "绑定", "验证", "同意", "拒绝", "我知道了", "知道了"
    ]

    private func isSystemText(_ t: String) -> Bool {
        for w in WebCaptureManager.filterWords {
            if t.contains(w) { return true }
        }
        return false
    }

    private func postToServer(_ text: String) {
        let urlStr = "http://\(serverHost):\(serverPort)/api/say"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let json: [String: Any] = [
            "phone_id": deviceId,
            "text": text,
            "type": "danmaku"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                self?.addLog("❌ 评论发送失败: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse {
                self?.addLog("📤 已发送 -> \(http.statusCode)")
            }
        }.resume()
    }

    func addLog(_ msg: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let ts = fmt.string(from: Date())
        DispatchQueue.main.async {
            self.recentLog = "[\(ts)] \(msg)\n" + self.recentLog
            if self.recentLog.count > 2000 {
                self.recentLog = String(self.recentLog.prefix(2000))
            }
        }
    }
}

// MARK: - WKScriptMessageHandler：JS 评论回传
extension WebCaptureManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "capBridge",
              let text = message.body as? String else { return }
        handleComments(text)
    }
}

// MARK: - WKNavigationDelegate
extension WebCaptureManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 只对后台采集 WebView 注入抓取 JS（登录页不需要）
        if webView === self.webView {
            // 加载完成后检测登录状态：已登录自动跳控制台，未登录停在登录页
            if let url = webView.url?.absoluteString {
                if url.contains("login") || url.contains("passport") {
                    addLog("🔐 当前在登录页（未登录或等待登录）")
                    self.isLoggedIn = false
                    self.lastStatus = "⚠️ 请先登录百应"
                } else if url.contains("live/control") {
                    addLog("✅ 已在直播控制台，注入抓取JS")
                    self.isLoggedIn = true
                    self.loginDetectCount = 0
                    injectCaptureJS()
                } else {
                    // 其他页面（如登录成功后的跳转页）→ 等几秒再检测，已登录则跳控制台
                    addLog("✅ 页面加载完成: \(url.prefix(60))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.checkLoginState()
                    }
                }
            }
        } else {
            addLog("✅ 登录页加载完成")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        addLog("⚠️ 页面加载失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        addLog("⚠️ 页面连接失败: \(error.localizedDescription)")
    }

    /// 拦截网页 window.open 新窗口：在当前 WebView 里打开（百应登录用新窗口弹授权页）
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            addLog("🪟 拦截新窗口: \(url.absoluteString.prefix(80))")
            if isAppScheme(url) {
                // 抖音/头条唤起协议 → 交给系统打开抖音 App
                UIApplication.shared.open(url, options: [:]) { ok in
                    self.addLog(ok ? "📱 已唤起抖音 App" : "⚠️ 无法唤起抖音 App（未安装？）")
                }
            } else {
                // 普通网页 → 在当前 WebView 里打开
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

    /// 导航策略：拦截自定义协议（抖音唤起等）交给系统处理
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if isAppScheme(url) {
                addLog("📱 唤起 App: \(scheme)://")
                UIApplication.shared.open(url, options: [:]) { ok in
                    self.addLog(ok ? "✅ 已打开抖音" : "⚠️ 无法打开抖音")
                }
                decisionHandler(.cancel)
                return
            }
            // 登录成功后可能跳回控制台 URL，记录一下
            if url.absoluteString.contains("live/control") {
                self.isLoggedIn = true
                self.loginDetectCount = 0
                self.addLog("🎉 已进入直播控制台，登录成功！")
            }
        }
        decisionHandler(.allow)
    }

    /// 判断是否是抖音系 App 唤起协议
    private func isAppScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        // 抖音/头条/巨量百应等 App 协议
        let appSchemes = ["snssdk1128", "aweme", "douyin", "bytewebview", "sslocal", "byteimg"]
        return appSchemes.contains(scheme)
    }
}
