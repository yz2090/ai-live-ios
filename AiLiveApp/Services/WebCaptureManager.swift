import Foundation
import WebKit
import Combine

// MARK: - 网页采集管理器 v11.6
// 统一单页面方案：一个 WKWebView 加载「直播大屏基础版」维持登录态，
// 评论/订单/核心数据全部用 URLSession 直连百应接口（1秒轮询 + cursor 增量）
// 实测接口（2026-08-01）:
//   评论: business_api/author/screen/anchor/live_comment?live_room_id=X&cursor=0
//         返回 fetch_interval:1000(官方推荐1秒轮询) + cursor 游标增量
//   订单: compass_api/content_live/author/live_screen/live_order?room_id=X&order_status=3
//   核心: compass_api/author/live/basic_live_screen/base_info?room_id=X (成交金额/件数/人数/在线/粉丝)
class WebCaptureManager: NSObject, ObservableObject {
    static let shared = WebCaptureManager()

    @Published var isRunning = false
    @Published var lastStatus = "未启动"
    @Published var capturedCount = 0
    @Published var recentLog: String = ""
    @Published var showLoginSheet = false   // 是否显示登录 WebView
    @Published var isLoggedIn = false       // 是否已登录
    @Published var loginURL: URL = URL(string: "https://buyin.jinritemai.com")!  // 当前登录页 URL
    var isCompassStep = false   // 统一登录：是否已切到 compass 补登阶段

    private var webView: WKWebView?          // 唯一 WebView：加载基础版大屏，维持登录态
    private var deviceId: String = ""
    private var serverHost = kServerHost
    private var serverPort = kServerPort
    /// 发数据用的 pid：优先用用户填的目标手机/绑定的安卓手机（服务器才能查到 bark_key/配置），否则用自身 deviceId
    private var effectivePid: String {
        let target = WebSocketManager.shared.effectiveTargetPid
        return target.isEmpty ? deviceId : target
    }
    private var seenKeys = Set<String>()     // 评论去重
    private var timer: Timer?                // 状态检查
    var loginDetectCount = 0
    private var lastConsoleLoadTime: TimeInterval = 0
    @Published var orderCapturedCount = 0
    @Published var orderLastInfo = ""
    private var seenOrderIds = Set<String>() // 已见订单号
    private var lastDiagSummary = ""

    // ── v11.6 新：接口直连状态 ──
    private var commentCursor = "0"          // 评论游标（增量拉取）
    private var commentTimer: Timer?         // 评论 1秒轮询
    private var orderTimer: Timer?           // 订单 1秒轮询
    private var coreTimer: Timer?            // 核心数据 5分钟
    private var commentRunning = false
    private var orderRunning = false
    private var lastCorePush = ""            // 上次核心数据摘要（变化才推 Bark）
    private var isFetchingComment = false    // 防重入
    private var isFetchingOrder = false

    // 直播间 ID（实测：豆豆生活馆）
    private let roomId = "7668676207549991720"
    private let liveAppId = "1128"

    // ── v11.6 统一页面：直播大屏基础版（评论+订单+核心数据都在这里）──
    private let compassURL = URL(string: "https://compass.jinritemai.com/screen/talent/main?live_room_id=7668676207549991720&live_app_id=1128&source=compass_inner")!

    // ── v11.6 核心：页面内接口轮询 JS ──
    // 原理：JS 在 WKWebView 页面内 fetch，天然携带页面 Cookie（登录态）
    // 三个接口：评论(live_comment+cursor增量) / 订单(live_order+order_id去重) / 核心数据(base_info)
    // 回传：postMessage 给原生 → 原生解析 → POST 服务器
    private let pollJS = """
    (function() {
        if (window.__pollInit) return;
        window.__pollInit = true;
        var roomId = '7668676207549991720';
        var cursor = '0';
        var seenOrders = {};
        var seenComments = {};
        // 从 URL 动态提取 room_id（换直播间自动跟随）
        function refreshRoomId() {
            var m = window.location.href.match(/live_room_id=(\\d+)/);
            if (m && m[1] && m[1].length >= 10 && m[1] !== '0') roomId = m[1];
        }
        function postMsg(type, payload) {
            try { window.webkit.messageHandlers.capBridge.postMessage(JSON.stringify({type: type, data: payload})); } catch(e) {}
        }
        // 评论：1秒轮询 live_comment 接口，cursor 增量
        function pollComments() {
            refreshRoomId();
            fetch('https://compass.jinritemai.com/business_api/author/screen/anchor/live_comment?live_room_id=' + roomId + '&cursor=' + cursor + '&version_code=100&fe_version=1&device_id=7019359764', {
                credentials: 'include'
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d || !d.data) return;
                if (d.data.cursor) cursor = d.data.cursor;
                var list = d.data.comments || [];
                var fresh = [];
                for (var i = 0; i < list.length; i++) {
                    var c = list[i];
                    var key = c.comment_id || (c.content || '') + '_' + (c.create_time || '');
                    if (!key || seenComments[key]) continue;
                    seenComments[key] = true;
                    fresh.push(c);
                }
                if (fresh.length > 0) postMsg('comments', fresh);
            }).catch(function(e) {});
        }
        // 订单：1秒轮询 live_order，order_id 去重
        function pollOrders() {
            refreshRoomId();
            fetch('https://compass.jinritemai.com/compass_api/content_live/author/live_screen/live_order?room_id=' + roomId + '&order_status=3&page_no=1&page_size=10', {
                credentials: 'include'
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d || !d.data || !d.data.order_list) return;
                var list = d.data.order_list;
                var fresh = [];
                for (var i = 0; i < list.length; i++) {
                    var o = list[i];
                    if (!o.order_id || seenOrders[o.order_id]) continue;
                    seenOrders[o.order_id] = true;
                    fresh.push(o);
                }
                if (fresh.length > 0) postMsg('orders', fresh);
            }).catch(function(e) {});
        }
        // 核心数据：5分钟 base_info
        function pollCore() {
            refreshRoomId();
            fetch('https://compass.jinritemai.com/compass_api/author/live/basic_live_screen/base_info?room_id=' + roomId, {
                credentials: 'include'
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (!d || !d.data) return;
                postMsg('core', d.data);
            }).catch(function(e) {});
        }
        setInterval(pollComments, 1000);
        setInterval(pollOrders, 1000);
        setInterval(pollCore, 300000);
        setTimeout(pollComments, 500);
        setTimeout(pollOrders, 800);
        setTimeout(pollCore, 1500);
    })();
    """

    // 接口地址
    private let commentAPI = "https://compass.jinritemai.com/business_api/author/screen/anchor/live_comment"
    private let orderAPI = "https://compass.jinritemai.com/compass_api/content_live/author/live_screen/live_order"
    private let coreAPI = "https://compass.jinritemai.com/compass_api/author/live/basic_live_screen/base_info"

    // 百应直播中控台（评论老方案保留，登录后自动跳转）
    private let buyinConsoleURL = URL(string: "https://buyin.jinritemai.com/dashboard/live/control")!
    private let buyinURL = URL(string: "https://buyin.jinritemai.com/mpa/account/login?log_out=1&type=24")!
    private let buyinLoginURL = URL(string: "https://buyin.jinritemai.com/mpa/account/login?log_out=1&type=24")!

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
        addLog("🌐 网页采集启动（v11.6 单页面+接口JS轮询）")

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "capBridge")
        // v11.6: 接口轮询 JS 自动注入（页面内 fetch 自带 Cookie）
        userContentController.addUserScript(
            WKUserScript(source: pollJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController = userContentController
        config.websiteDataStore = WKWebsiteDataStore.default()  // Cookie 持久化（登录态）

        // 强制桌面版浏览器（百应只适配电脑浏览器）
        let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        config.applicationNameForUserAgent = desktopUA

        webView = WKWebView(frame: .zero, configuration: config)
        webView?.navigationDelegate = self
        webView?.customUserAgent = desktopUA
        webView?.load(URLRequest(url: compassURL))
        addLog("📄 加载直播大屏基础版（统一采集页）…")

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
        commentTimer?.invalidate()
        commentTimer = nil
        orderTimer?.invalidate()
        orderTimer = nil
        coreTimer?.invalidate()
        coreTimer = nil
        webView?.stopLoading()
        webView = nil
        commentRunning = false
        orderRunning = false
        addLog("🛑 网页采集停止")
    }

    // MARK: - 状态检查：页面加载好后启动接口轮询
    private func checkStatus() {
        guard let webView = webView else { return }
        webView.evaluateJavaScript("document.readyState") { [weak self] result, _ in
            guard let self = self else { return }
            if let state = result as? String, state == "complete" {
                self.lastStatus = "页面加载完成"
                // 检测登录态 + 启动轮询
                self.checkLoginAndStartPolling()
            }
        }
    }

    /// 检测是否已登录：看页面 URL / 是否有订单数据区；已登录则启动 3 个轮询
    private func checkLoginAndStartPolling() {
        guard let webView = webView else { return }
        let js = """
        (function() {
            var url = window.location.href;
            var isLoginPage = url.indexOf('login') > -1 || url.indexOf('passport') > -1 ||
                document.querySelector('input[type="password"], [class*="qrcode"], [class*="login"]') != null;
            var hasData = document.body ? document.body.innerText.indexOf('直播间') > -1 : false;
            return JSON.stringify({isLoginPage: isLoginPage, hasData: hasData, url: url});
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            if let s = result as? String,
               let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                let isLoginPage = d["isLoginPage"] as? Bool ?? false
                if isLoginPage {
                    self.isLoggedIn = false
                    self.lastStatus = "⚠️ 需要登录百应"
                    self.loginDetectCount += 1
                    if self.loginDetectCount >= 2 && !self.showLoginSheet {
                        self.addLog("🔐 检测到未登录，请点击「百应登录」扫码登录")
                    }
                } else {
                    self.isLoggedIn = true
                    self.lastStatus = "✅ 已登录，启动实时采集"
                    self.loginDetectCount = 0
                    self.startPolling()
                }
            }
        }
    }

    /// 轮询由页面内 JS 执行（pollJS），这里只记录状态
    private func startPolling() {
        addLog("🚀 JS 实时采集已注入（评论1s / 订单1s / 核心5min）")
    }

    // MARK: - JS 回传处理：评论/订单/核心数据（v11.6）
    // JS 在页面内 fetch（带 Cookie），postMessage 回传 JSON
    private func handleComments(_ list: [[String: Any]]) {
        for c in list {
            var text = c["content"] as? String ?? ""
            if text.isEmpty { text = c["text"] as? String ?? "" }
            if text.isEmpty { text = c["comment_content"] as? String ?? "" }
            if text.isEmpty { text = c["message"] as? String ?? "" }
            // 可能有用户信息嵌套
            if text.isEmpty, let user = c["user"] as? [String: Any] {
                text = user["nickname"] as? String ?? ""
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.count < 2 || text.count > 200 { continue }
            if let isAnchor = c["is_anchor"] as? Bool, isAnchor { continue }

            if seenKeys.contains(text) { continue }
            seenKeys.insert(text)
            if seenKeys.count > 5000 { seenKeys.removeAll() }

            if isSystemText(text) { continue }

            capturedCount += 1
            addLog("💬 \(text)")
            postToServer(text)
        }
    }

    private func handleOrders(_ list: [[String: Any]]) {
        for o in list {
            guard let orderId = o["order_id"] as? String else { continue }
            if seenOrderIds.contains(orderId) { continue }
            seenOrderIds.insert(orderId)

            let nick = o["nick_name"] as? String ?? ""
            var product = o["sku_product_title"] as? String ?? (o["product_title"] as? String ?? "")
            if product.count > 12 {
                product = String(product.prefix(12))
            }
            let amountFen = (o["order_amount"] as? [String: Any])?["value"] as? Double ?? 0
            let amount = amountFen / 100.0

            orderCapturedCount += 1
            orderLastInfo = "\(nick) 下单 \(product) ¥\(String(format: "%.2f", amount))"
            addLog("🛒 \(nick) 下单 \(product) ¥\(String(format: "%.2f", amount))")
            postOrderToServer(nick: nick, product: product, amount: amount)
        }
    }

    private var lastCoreTime: Date?          // 上次核心推送时间
    private var lastCoreSummary = ""         // 上次核心摘要（防重复推送）

    private func handleCoreData(_ d: [String: Any]) {
        let gmvFen = d["gmv"] as? Double ?? 0
        let gmv = gmvFen / 100.0
        let payCnt = (d["pay_cnt"] as? [String: Any])?["value"] as? Double ?? 0
        let payUcnt = (d["pay_ucnt"] as? [String: Any])?["value"] as? Double ?? 0
        let online = (d["online_user_cnt"] as? [String: Any])?["value"] as? Double ?? 0
        let totalView = (d["online_user_ucnt"] as? [String: Any])?["value"] as? Double ?? 0
        let fans = (d["incr_fans_cnt"] as? [String: Any])?["value"] as? Double ?? 0
        let rate = (d["product_click_to_pay_rate"] as? [String: Any])?["value"] as? Double ?? 0
        let title = d["title"] as? String ?? "直播间"
        let liveDuration = d["live_duration"] as? String ?? ""

        let summary = "💰¥\(String(format: "%.0f", gmv)) 件\(Int(payCnt)) 人\(Int(payUcnt)) 在线\(Int(online)) 累计\(Int(totalView)) 粉\(Int(fans))"
        addLog("📊 核心数据: \(summary)")

        // 5分钟推送：JS 每5分钟拉一次 base_info，这里限制每4分钟推一次（防 JS 重载重复）
        let now = Date()
        if let last = lastCoreTime, now.timeIntervalSince(last) < 240 {
            return
        }
        lastCoreTime = now

        let rateStr = String(format: "%.1f%%", rate * 100)
        let msg = """
        📊 \(title) 直播数据
        💰 成交金额 ¥\(String(format: "%.0f", gmv))（件\(Int(payCnt)) 人\(Int(payUcnt))）
        👥 在线 \(Int(online)) 人 | 累计 \(Int(totalView))
        ⭐ 新增粉丝 \(Int(fans)) | 转化率 \(rateStr)
        🕐 \(liveDuration)
        """
        pushBark(title: "📊直播数据", body: msg)
    }

    /// Bark 推送：优先本地 key，无则走服务器（服务器有各手机 bark_key）
    private func pushBark(title: String, body: String) {
        let barkKey = UserDefaults.standard.string(forKey: "ailive_bark_key") ?? ""
        guard !barkKey.isEmpty else {
            postToServerCoreData(body)
            return
        }
        guard let url = URL(string: "https://api.day.app/push") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let json: [String: Any] = [
            "title": title,
            "body": body,
            "device_key": barkKey
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        URLSession.shared.dataTask(with: request) { [weak self] _, _, error in
            if let error = error {
                self?.addLog("⚠️ Bark推送失败: \(error.localizedDescription)")
            }
        }.resume()
    }

    /// 核心数据走服务器推送（服务器有 bark_key 配置）
    private func postToServerCoreData(_ text: String) {
        let urlStr = "http://\(serverHost):\(serverPort)/api/say"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let json: [String: Any] = [
            "phone_id": effectivePid,
            "text": text,
            "type": "core_data"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - 评论过滤（沿用）
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

    // MARK: - POST 服务器
    private func postToServer(_ text: String) {
        let urlStr = "http://\(serverHost):\(serverPort)/api/say"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let json: [String: Any] = [
            "phone_id": effectivePid,
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

    private func postOrderToServer(nick: String, product: String, amount: Double) {
        let urlStr = "http://\(serverHost):\(serverPort)/api/say"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let json: [String: Any] = [
            "phone_id": effectivePid,
            "text": "\(nick)下单\(product)",
            "type": "order",
            "nick": nick,
            "product": product,
            "amount": amount
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                self?.addLog("❌ 订单发送失败: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse {
                self?.addLog("📤 订单已发送 -> \(http.statusCode)")
            }
        }.resume()
    }

    // MARK: - 登录（沿用统一登录）
    func openLogin() {
        loginURL = buyinLoginURL
        showLoginSheet = true
        addLog("🔐 统一登录：先登 buyin（评论）…")
    }

    /// 重新加载采集页（登录成功后刷新 Cookie/登录态）
    func loadConsole() {
        guard let webView = webView else { return }
        webView.load(URLRequest(url: compassURL))
        addLog("📄 重新加载采集页（刷新登录态）…")
    }

    func continueOrderLogin() {
        loginURL = compassURL
        isCompassStep = true
        addLog("🔁 buyin 已登录，自动跳 compass 补登（订单）…")
    }

    func closeLogin() {
        showLoginSheet = false
        isCompassStep = false
        loginDetectCount = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkStatus()
        }
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

// MARK: - WKNavigationDelegate
extension WebCaptureManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            addLog("✅ 页面加载完成")
            checkStatus()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        addLog("⚠️ 页面加载失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        addLog("⚠️ 页面连接失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            addLog("🪟 拦截新窗口: \(url.absoluteString.prefix(80))")
            if isAppScheme(url) {
                UIApplication.shared.open(url, options: [:]) { ok in
                    self.addLog(ok ? "📱 已唤起抖音 App" : "⚠️ 无法唤起抖音 App（未安装？）")
                }
            } else {
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

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
        }
        decisionHandler(.allow)
    }

    private func isAppScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        let appSchemes = ["snssdk1128", "aweme", "douyin", "bytewebview", "sslocal", "byteimg"]
        return appSchemes.contains(scheme)
    }
}

// MARK: - WKScriptMessageHandler：JS 接口轮询回传（v11.6）
// JS 回传 JSON {type: "comments"|"orders"|"core", data: [...]}
extension WebCaptureManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "capBridge" else { return }
        guard let jsonStr = message.body as? String,
              let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "comments":
            if let list = obj["data"] as? [[String: Any]] {
                handleComments(list)
            }
        case "orders":
            if let list = obj["data"] as? [[String: Any]] {
                handleOrders(list)
            }
        case "core":
            if let core = obj["data"] as? [String: Any] {
                handleCoreData(core)
            }
        default:
            break
        }
    }
}
