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
    @Published var loginURL: URL = URL(string: "https://buyin.jinritemai.com")!  // 当前登录页 URL
    var isCompassStep = false   // 统一登录：是否已切到 compass 补登阶段

    private var webView: WKWebView?
    private var orderWebView: WKWebView?   // 订单采集 WebView（compass 大屏）
    private var deviceId: String = ""
    private var serverHost = kServerHost
    private var serverPort = kServerPort
    private var seenKeys = Set<String>()
    private var timer: Timer?
    var loginDetectCount = 0        // 连续检测到未登录的次数
    @Published var orderCapturedCount = 0   // 已抓订单数
    @Published var orderLastInfo = ""      // 最后一条订单信息
    private var seenOrderIds = Set<String>()  // 已见过的订单号

    // 百应直播中控台（登录后自动跳转到这里采集）
    // 参考闪控猫(智播魔方) media_url_list.txt 抖音入口：用无参数标准 URL，
    // 避免 btm_ppre / btm_show_id 等临时参数过期导致进不去直播间
    private let buyinConsoleURL = URL(string: "https://buyin.jinritemai.com/dashboard/live/control")!

    // 首次加载页面：达人工作台登录页（用户提供，type=24）
    private let buyinURL = URL(string: "https://buyin.jinritemai.com/mpa/account/login?log_out=1&type=24")!

    // 百应登录页（扫码登录）
    private let buyinLoginURL = URL(string: "https://buyin.jinritemai.com/mpa/account/login?log_out=1&type=24")!

    // 巨量百应数据大屏（订单采集）：登录后能看到直播实时订单
    // 实测接口: compass_api/content_live/author/live_screen/live_order?room_id=XXX&order_status=3&page_no=1&page_size=4
    // room_id 写死一个默认值，页面加载后 JS 会从 URL 动态提取实际 room_id（换直播间也能采集）
    private let compassURL = URL(string: "https://compass.jinritemai.com/screen/talent/main?live_room_id=7668676207549991720&live_app_id=1128")!

    // 订单采集 JS：每2.5秒轮询 live_order 接口，发现新订单回传
    // 实测接口返回（2026-08-01）:
    //   {"data":{"order_list":[{"item_num":1,"nick_name":"🎧***","order_amount":{"value":881},
    //     "order_id":"6928387...","order_status":3,"order_ts":1785517022,
    //     "product_title":"企鹅公道杯...","sku_product_title":"蓝把鹰嘴公杯加厚350ml"}],
    //     "page_result":{"page_no":1,"page_size":4,"total":21}}}
    private let orderJS = """
    (function() {
        if (window.__orderInit) return;
        window.__orderInit = true;
        window.__orderSeen = new Set();
        // room_id 动态提取：优先从当前页面 URL 拿（换直播间自动跟随），取不到用默认
        var roomId = '7668676207549991720';
        function refreshRoomId() {
            var m = window.location.href.match(/live_room_id=(\\d+)/);
            if (m && m[1]) roomId = m[1];
        }
        function poll() {
            refreshRoomId();
            fetch('https://compass.jinritemai.com/compass_api/content_live/author/live_screen/live_order?room_id=' + roomId + '&order_status=3&page_no=1&page_size=4', {
                credentials: 'include'
            }).then(function(r) { return r.json(); }).then(function(d) {
                var list = (d.data && d.data.order_list) || [];
                var fresh = [];
                for (var i = 0; i < list.length; i++) {
                    var o = list[i];
                    if (!o.order_id) continue;
                    if (window.__orderSeen.has(o.order_id)) continue;
                    window.__orderSeen.add(o.order_id);
                    fresh.push(o);
                }
                if (fresh.length > 0) {
                    try {
                        window.webkit.messageHandlers.orderBridge.postMessage(JSON.stringify(fresh));
                    } catch(e) {}
                }
            }).catch(function(e) {});
        }
        setInterval(poll, 2500);
        setTimeout(poll, 1500);
    })();
    """

    // 注入 JS：每1.5秒扫描评论区新增文本，通过 WebKit message handler 回传
    // 选择器基于百应控制台实测 DOM（2026-08-01）:
    //   <div class="commentItem-xxx">
    //     <div class="nickname-xxx"><span class="tag-xxx">主播</span>我：</div>
    //     <div class="description-xxx">评论内容</div>
    //   </div>
    private let captureJS = """
    (function() {
        if (window.__capInit) return;
        window.__capInit = true;
        window.__capSeen = new Set();
        setInterval(function() {
            var texts = [];
            // 评论条目：commentItem-xxx（hash后缀），内容在 description-xxx
            var items = document.querySelectorAll('[class*="commentItem"]');
            for (var i = 0; i < items.length; i++) {
                var item = items[i];
                // 跳过主播自己的消息
                if (item.querySelector('[class*="tag"]')) continue;
                // 找评论内容（description 或直接子文本）
                var desc = item.querySelector('[class*="description"]');
                var t = '';
                if (desc) {
                    t = desc.innerText || desc.textContent || '';
                } else {
                    t = item.innerText || item.textContent || '';
                }
                t = t.trim();
                if (t.length < 2 || t.length > 200) continue;
                var key = t + '_' + item.getBoundingClientRect().top.toFixed(0);
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

        // === 订单采集 WebView（compass 大屏）===
        startOrderCapture(desktopUA: desktopUA)

        // 定时检查状态
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
    }

    /// 启动订单采集：加载 compass 大屏页，注入订单轮询 JS
    private func startOrderCapture(desktopUA: String) {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "orderBridge")
        config.userContentController = userContentController
        config.websiteDataStore = WKWebsiteDataStore.default()  // 共享 Cookie
        config.applicationNameForUserAgent = desktopUA

        orderWebView = WKWebView(frame: .zero, configuration: config)
        orderWebView?.navigationDelegate = self
        orderWebView?.customUserAgent = desktopUA
        orderWebView?.load(URLRequest(url: compassURL))
        addLog("📄 加载巨量百应大屏（订单采集）…")
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
        // 订单 WebView 也停
        orderWebView?.stopLoading()
        orderWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "orderBridge")
        orderWebView = nil
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
        // 检查订单 WebView 状态（compass 大屏）
        if let orderWebView = orderWebView {
            orderWebView.evaluateJavaScript("document.readyState") { [weak self] result, _ in
                guard let self = self else { return }
                if let state = result as? String, state == "complete" {
                    // 检查 compass 是否已登录：页面是否包含订单数据区
                    let js = """
                    (function() {
                        var url = window.location.href;
                        var hasLogin = url.indexOf('login') > -1 || url.indexOf('passport') > -1;
                        var hasOrderData = document.querySelectorAll('[class*="order"], [class*="core_data"]').length > 0;
                        return JSON.stringify({hasLogin: hasLogin, hasOrderData: hasOrderData, url: url});
                    })();
                    """
                    orderWebView.evaluateJavaScript(js) { result2, _ in
                        if let s = result2 as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                            let hasLogin = d["hasLogin"] as? Bool ?? false
                            if hasLogin {
                                self.addLog("⚠️ 大屏未登录，请点「统一登录」扫码")
                            }
                        }
                    }
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
    /// 统一登录：一个按钮完成 buyin（评论）+ compass（订单）两个域的登录
    /// 原理：buyin 与 compass 同属 *.jinritemai.com，SSO 登录 Cookie 域级共享，
    /// 登一次 buyin 后 compass 自动继承；本方法在 buyin 登录成功后自动跳 compass 补登，
    /// 全部完成后自动关闭登录页
    func openLogin() {
        loginURL = buyinLoginURL
        showLoginSheet = true
        addLog("🔐 统一登录：先登 buyin（评论）…")
    }

    /// 统一登录第二步：buyin 登录成功后自动跳 compass 补登（订单）
    /// 通过更新 @Published loginURL 触发 LoginWebView 重新导航
    func continueOrderLogin() {
        loginURL = compassURL
        isCompassStep = true
        addLog("🔁 buyin 已登录，自动跳 compass 补登（订单）…")
    }

    func closeLogin() {
        showLoginSheet = false
        isCompassStep = false
        // 登录页 WebView 由 SwiftUI sheet 管理，这里只重置状态
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

    // MARK: - 订单处理：解析 JSON → 格式化 → POST 服务器
    private func handleOrders(_ jsonStr: String) {
        guard let data = jsonStr.data(using: .utf8),
              let orders = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            addLog("⚠️ 订单解析失败")
            return
        }
        for o in orders {
            let nick = o["nick_name"] as? String ?? ""
            let product = o["sku_product_title"] as? String ?? (o["product_title"] as? String ?? "")
            let amount = (o["order_amount"] as? [String: Any])?["value"] as? Double ?? 0

            // 格式化为服务器认识的文本：{昵称}下单{商品}
            // 服务器 parse_order 会提取昵称和商品，生成点名感谢
            let text = "\(nick)下单\(product)"
            orderCapturedCount += 1
            orderLastInfo = "\(nick) 下单 \(product) ¥\(Int(amount))"
            addLog("🛒 \(nick) 下单 \(product) ¥\(Int(amount))")
            postOrderToServer(nick: nick, product: product, amount: amount)
        }
    }

    /// 订单 POST：直接带结构化数据，服务器生成感谢语
    private func postOrderToServer(nick: String, product: String, amount: Double) {
        let urlStr = "http://\(serverHost):\(serverPort)/api/say"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let json: [String: Any] = [
            "phone_id": deviceId,
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
        if message.name == "capBridge", let text = message.body as? String {
            handleComments(text)
        } else if message.name == "orderBridge", let jsonStr = message.body as? String {
            handleOrders(jsonStr)
        }
    }
}

// MARK: - WKNavigationDelegate
extension WebCaptureManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 订单 WebView（compass 大屏）：加载完成注入订单轮询 JS
        if webView === self.orderWebView {
            addLog("📊 大屏页加载完成，注入订单轮询JS")
            webView.evaluateJavaScript(orderJS) { [weak self] _, error in
                if let error = error {
                    self?.addLog("⚠️ 订单JS注入失败: \(error.localizedDescription)")
                } else {
                    self?.addLog("✅ 订单抓取JS已注入")
                }
            }
            return
        }
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
