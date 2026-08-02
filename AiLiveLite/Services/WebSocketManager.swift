import Foundation
import Combine

// MARK: - 服务器配置（2号测试服务器，与安卓采集端一致）
let kServerHost = "59.110.152.66"
let kServerPort = 18766
let kDeviceIdKey = "ailive_lite_iphone_device_id"

// MARK: - WebSocket 连接管理器（精简播放端：只收音频 + meta 文本）
class WebSocketManager: NSObject, ObservableObject {
    static let shared = WebSocketManager()

    @Published var isConnected = false
    @Published var statusMessage = "未连接"
    @Published var recentLog: String = ""
    @Published var lastMetaText: String = ""      // 最近一条播报文字（meta 文本）
    @Published var lastMetaType: String = ""      // 最近一条播报类型

    // 设备ID：首次启动自动生成，用户可查看并填到安卓端
    @Published var deviceId: String = "" {
        didSet {
            UserDefaults.standard.set(deviceId, forKey: kDeviceIdKey)
        }
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
            deviceId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased())
            UserDefaults.standard.set(deviceId, forKey: kDeviceIdKey)
        }
    }

    // MARK: - 连接管理（单飞，防重复）
    func connect() {
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
                print("[AiLiveLite] 接收失败: \(error)")
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
            DispatchQueue.main.async {
                self.lastMetaType = msgType
                self.lastMetaText = msgText
            }
            addLog("📢 [\(msgType)] \(msgText)")
        case "welcome":
            addLog("👋 服务器欢迎，设备ID: \(deviceId)")
        case "bound":
            let pid = json["pid"] as? String ?? ""
            addLog("🔗 服务器绑定: \(pid)")
        case "pong":
            break
        default:
            addLog("📩 \(text)")
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
        let hello: [String: Any] = ["type": "hello", "name": "iPhone播放端精简版", "device_id": deviceId]
        if let d = try? JSONSerialization.data(withJSONObject: hello),
           let s = String(data: d, encoding: .utf8) {
            webSocketTask.send(.string(s)) { _ in }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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
