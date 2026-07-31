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
    @Published var deviceId: String {
        didSet {
            UserDefaults.standard.set(deviceId, forKey: kDeviceIdKey)
        }
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectDelay: TimeInterval = 3
    private var manualDisconnect = false

    override private init() {
        // 先计算设备ID（局部变量，避免 super.init 前访问属性）
        let savedId: String
        if let saved = UserDefaults.standard.string(forKey: kDeviceIdKey), !saved.isEmpty {
            savedId = saved
        } else {
            savedId = "iphone_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(14).lowercased()
            UserDefaults.standard.set(savedId, forKey: kDeviceIdKey)
        }
        super.init()
        deviceId = savedId
    }

    func connect() {
        disconnect()
        manualDisconnect = false

        let urlStr = "ws://\(kServerHost):\(kServerPort)/ws_iphone/\(deviceId)"
        guard let url = URL(string: urlStr) else {
            statusMessage = "URL错误"
            return
        }

        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()

        statusMessage = "连接中..."
        addLog("连接服务器: \(urlStr)")

        // 心跳
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self = self, !self.manualDisconnect else { return }
            self.webSocketTask?.sendPing { error in
                if let error = error {
                    print("[AiLive] Ping失败: \(error)")
                }
            }
        }
    }

    func disconnect() {
        manualDisconnect = true
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        statusMessage = "已断开"
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    // 音频数据 → 入队播放
                    AudioPlayerService.shared.enqueueAudio(data)
                    self.addLog("▶ 音频 (\(data.count) 字节)")
                case .string(let text):
                    self.handleText(text)
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure(let error):
                print("[AiLive] 接收失败: \(error)")
                self.isConnected = false
                self.statusMessage = "断线，\(Int(self.reconnectDelay))秒后重连"
                DispatchQueue.main.asyncAfter(deadline: .now() + self.reconnectDelay) {
                    if !self.manualDisconnect { self.connect() }
                }
            }
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
            addLog("🔗 已绑定安卓手机: \(json["pid"] as? String ?? "")")
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
        isConnected = true
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
        isConnected = false
        statusMessage = error != nil ? "连接断开" : "正常断开"
        addLog("❌ 连接断开")
        guard !manualDisconnect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            self?.connect()
        }
    }
}
