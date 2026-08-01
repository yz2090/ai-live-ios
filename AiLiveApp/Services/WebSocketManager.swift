import Foundation
import Combine

// MARK: - WebSocket 连接管理器（iPhone 播放端）
class WebSocketManager: NSObject, ObservableObject {
    static let shared = WebSocketManager()

    @Published var isConnected = false
    @Published var statusMessage = "未连接"
    @Published var recentLog: String = ""
    @Published var broadcastHistory: [BroadcastEntry] = []

    // 设备ID：首次启动自动生成，用户可查看并填到安卓端
    @Published var deviceId: String = "" {
        didSet {
            UserDefaults.standard.set(deviceId, forKey: kDeviceIdKey)
        }
    }

    // 绑定的安卓手机 pid（服务器 bound 消息回传；发数据时用绑定pid，服务器才能查到bark_key）
    @Published var boundPid: String = "" {
        didSet {
            UserDefaults.standard.set(boundPid, forKey: "ailive_bound_pid")
        }
    }

    // 用户手动填的目标手机 pid（优先于 boundPid）
    @Published var targetPid: String = "" {
        didSet {
            UserDefaults.standard.set(targetPid, forKey: "ailive_target_pid")
        }
    }

    /// 实际使用的目标 pid：手动填的 > 绑定的 > 空（用本机）
    var effectiveTargetPid: String {
        if !targetPid.isEmpty { return targetPid }
        return boundPid
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var manualDisconnect = false
    private var isConnecting = false
    private var generation = 0          // 连接代次，防止旧连接回调干扰新连接

    override private init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: kDeviceIdKey), !saved.isEmpty {
            deviceId = saved
        } else {
            deviceId = "iphone_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(14).lowercased()
            UserDefaults.standard.set(deviceId, forKey: kDeviceIdKey)
        }
        if let savedPid = UserDefaults.standard.string(forKey: "ailive_bound_pid"), !savedPid.isEmpty {
            boundPid = savedPid
        }
        if let savedTarget = UserDefaults.standard.string(forKey: "ailive_target_pid"), !savedTarget.isEmpty {
            targetPid = savedTarget
        }
    }

    // MARK: - 连接管理（单飞，防重复）
    func connect() {
        // 已连接或正在连接则跳过
        if isConnected || isConnecting { return }
        isConnecting = true
        manualDisconnect = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        let gen = generation + 1
        generation = gen

        let urlStr = "ws://\(kServerHost):\(kServerPort)/ws_iphone/\(deviceId)"
        guard let url = URL(string: urlStr) else {
            statusMessage = "URL错误"
            isConnecting = false
            return
        }

        // 清理旧连接（不触发回调风暴）
        let oldTask = webSocketTask
        webSocketTask = nil
        oldTask?.cancel(with: .goingAway, reason: nil)

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        let task = session?.webSocketTask(with: url)
        webSocketTask = task
        task?.resume()
        receiveMessage(gen)

        statusMessage = "连接中..."
        addLog("连接服务器: \(urlStr)")

        // 心跳：应用层 JSON ping（服务器支持 {"type":"ping"} → pong）
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    func disconnect() {
        manualDisconnect = true
        isConnecting = false
        generation += 1
        pingTimer?.invalidate()
        pingTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        statusMessage = "已断开"
    }

    private func sendPing() {
        guard isConnected, let task = webSocketTask else { return }
        let payload: [String: Any] = ["type": "ping", "ts": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: d, encoding: .utf8) {
            task.send(.string(s)) { _ in }
        }
    }

    // MARK: - 接收
    private func receiveMessage(_ gen: Int) {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            // 旧代次的回调直接丢弃
            guard gen == self.generation else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    AudioPlayerService.shared.enqueueAudio(data)
                    self.addLog("▶ 音频 (\(data.count) 字节)")
                case .string(let text):
                    self.handleText(text)
                @unknown default:
                    break
                }
                self.receiveMessage(gen)

            case .failure(let error):
                print("[AiLive] 接收失败: \(error)")
                // 只有非手动断开才重连
                if !self.manualDisconnect {
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        isConnected = false
        isConnecting = false
        reconnectTimer?.invalidate()
        statusMessage = "断线，3秒后重连"
        addLog("❌ 连接断开，3秒后重连")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    // 处理服务器JSON消息：meta（类型+文字）/ welcome / bound / pong
    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            addLog("📩 \(text)")
            return
        }
        let type = json["type"] as? String ?? ""
        switch type {
        case "meta":
            let msgType = json["msg_type"] as? String ?? ""
            let msgText = json["text"] as? String ?? ""
            addHistory(msgType, msgText)
            addLog("📢 [\(msgType)] \(msgText)")
        case "welcome":
            addLog("👋 服务器欢迎，设备ID: \(deviceId)")
        case "bound":
            let pid = json["pid"] as? String ?? ""
            if !pid.isEmpty {
                boundPid = pid
                addLog("🔗 已绑定安卓手机: \(pid)")
            }
        case "pong":
            break
        default:
            addLog("📩 \(text)")
        }
    }

    private func addHistory(_ type: String, _ text: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let ts = fmt.string(from: Date())
        let entry = BroadcastEntry(time: ts, type: type, text: text)
        DispatchQueue.main.async {
            self.broadcastHistory.insert(entry, at: 0)
            if self.broadcastHistory.count > 200 {
                self.broadcastHistory.removeLast(self.broadcastHistory.count - 200)
            }
        }
    }

    private func addLog(_ msg: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let ts = fmt.string(from: Date())
        DispatchQueue.main.async {
            self.recentLog = "[\(ts)] \(msg)\n" + self.recentLog
            if self.recentLog.count > 3000 {
                self.recentLog = String(self.recentLog.prefix(3000))
            }
        }
    }
}

// MARK: - WebSocket Delegate
extension WebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === self.webSocketTask else { return }
        isConnected = true
        isConnecting = false
        statusMessage = "已连接 ✓"
        addLog("✅ WebSocket 已连接")
        // 注册设备信息
        let hello: [String: Any] = ["type": "hello", "name": "iPhone播放端", "device_id": deviceId]
        if let d = try? JSONSerialization.data(withJSONObject: hello),
           let s = String(data: d, encoding: .utf8) {
            webSocketTask.send(.string(s)) { _ in }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 只有当前任务才算数，手动断开不重连
        guard let wsTask = task as? URLSessionWebSocketTask,
              wsTask === self.webSocketTask else { return }
        isConnected = false
        isConnecting = false
        if let error = error {
            addLog("❌ 连接错误: \(error.localizedDescription)")
        }
        guard !manualDisconnect else { return }
        scheduleReconnect()
    }
}
