import Foundation
import CryptoKit

// MARK: - OpenClaw 网关 WS 协议客户端（v4）
// 参考官方 gateway-client 实现

enum GWError: Error {
    case invalidURL
    case notConnected
    case handshakeFailed(String)
    case requestTimeout
    case serverError(String)
}

// 简化事件模型：直接透传 JSON 字典
struct GWEvent {
    let name: String
    let payload: [String: Any]
}

// MARK: - 设备身份（ed25519 密钥对）
struct DeviceIdentity {
    let deviceId: String
    let privateKey: Curve25519.Signing.PrivateKey

    static func loadOrCreate() -> DeviceIdentity {
        let key = "openclaw_device_identity_v1"
        if let data = UserDefaults.standard.data(forKey: key),
           let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            let pub = priv.publicKey.rawRepresentation
            let id = SHA256.hash(data: pub).map { String(format: "%02x", $0) }.joined()
            return DeviceIdentity(deviceId: id, privateKey: priv)
        }
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey.rawRepresentation
        let id = SHA256.hash(data: pub).map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(priv.rawRepresentation, forKey: key)
        return DeviceIdentity(deviceId: id, privateKey: priv)
    }

    func sign(_ payload: String) -> String {
        let sig = try! privateKey.signature(for: Data(payload.utf8))
        return sig.base64URLEncodedString()
    }

    var publicKeyBase64URL: String {
        privateKey.publicKey.rawRepresentation.base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - WebSocket 客户端
final class OpenClawClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var isConnected = false
    @Published var statusMessage = "未连接"
    @Published var lastError: String?

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession!
    private var pendingRequests: [String: (Result<[String: Any], GWError>) -> Void] = [:]
    private var eventHandlers: [(GWEvent) -> Void] = []
    private var seq = 0
    private let identity = DeviceIdentity.loadOrCreate()
    private var handshakeDone = false

    var serverURL: String
    var token: String

    init(serverURL: String, token: String) {
        self.serverURL = serverURL
        self.token = token
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: 连接
    func connect() {
        guard let url = URL(string: serverURL) else {
            statusMessage = "URL 无效"
            return
        }
        handshakeDone = false
        statusMessage = "连接中..."
        let req = URLRequest(url: url)
        socket = session.webSocketTask(with: req)
        socket?.resume()
        receiveLoop()
    }

    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
        statusMessage = "已断开"
    }

    // MARK: URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { self.statusMessage = "握手..." }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.statusMessage = "连接断开"
        }
    }

    // MARK: 接收循环
    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let str):
                    self.handleFrame(str)
                case .data(let data):
                    if let str = String(data: data, encoding: .utf8) {
                        self.handleFrame(str)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.statusMessage = "连接失败: \(error.localizedDescription)"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func handleFrame(_ str: String) {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        guard let type = obj["type"] as? String else { return }
        if type == "event" {
            let event = (obj["event"] as? String) ?? ""
            let payload = (obj["payload"] as? [String: Any]) ?? [:]
            if !handshakeDone && event == "connect.challenge" {
                if let nonce = payload["nonce"] as? String,
                   let ts = payload["ts"] as? Int {
                    doHandshake(nonce: nonce, ts: ts)
                }
            } else {
                DispatchQueue.main.async {
                    for h in self.eventHandlers { h(GWEvent(name: event, payload: payload)) }
                }
            }
        } else if type == "res" {
            if let id = obj["id"] as? String,
               let handler = pendingRequests.removeValue(forKey: id) {
                let ok = (obj["ok"] as? Bool) ?? false
                if ok {
                    handler(.success((obj["payload"] as? [String: Any]) ?? [:]))
                } else {
                    let err = (obj["error"] as? [String: Any]) ?? [:]
                    handler(.failure(.serverError("\((err["message"] as? String) ?? "unknown")")))
                }
            }
        }
    }

    // MARK: 握手
    private func doHandshake(nonce: String, ts: Int) {
        let scopes = ["operator.read", "operator.write"]
        let scopesStr = scopes.joined(separator: ",")
        let payloadV3 = [
            "v3", identity.deviceId, "openclaw-ios", "ui", "operator", scopesStr,
            String(ts), token, nonce, "ios", "iphone"
        ].joined(separator: "|")
        let signature = identity.sign(payloadV3)

        let params: [String: Any] = [
            "minProtocol": 4, "maxProtocol": 4,
            "client": ["id": "openclaw-ios", "version": "1.0.0", "platform": "ios", "mode": "ui", "deviceFamily": "iphone"],
            "role": "operator",
            "scopes": scopes,
            "caps": [], "commands": [], "permissions": [:],
            "auth": ["token": token],
            "locale": "zh-CN",
            "userAgent": "openclaw-ios/1.0.0",
            "device": [
                "id": identity.deviceId,
                "publicKey": identity.publicKeyBase64URL,
                "signature": signature,
                "signedAt": ts,
                "nonce": nonce
            ]
        ]
        send(method: "connect", params: params) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    self.handshakeDone = true
                    self.isConnected = true
                    self.statusMessage = "已连接"
                case .failure(let e):
                    self.statusMessage = "握手失败"
                    self.lastError = "\(e)"
                }
            }
        }
    }

    // MARK: 发送请求
    func send(method: String, params: [String: Any], completion: @escaping (Result<[String: Any], GWError>) -> Void) {
        guard let socket = socket else {
            completion(.failure(.notConnected))
            return
        }
        seq += 1
        let id = "\(method)-\(seq)-\(UUID().uuidString.prefix(8))"
        pendingRequests[id] = completion
        var frame: [String: Any] = ["type": "req", "id": id, "method": method]
        if !params.isEmpty { frame["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let str = String(data: data, encoding: .utf8) else {
            pendingRequests.removeValue(forKey: id)
            completion(.failure(.serverError("序列化失败")))
            return
        }
        socket.send(.string(str)) { [weak self] err in
            if let err = err {
                self?.pendingRequests.removeValue(forKey: id)
                completion(.failure(.serverError(err.localizedDescription)))
            }
        }
    }

    // MARK: 事件订阅
    func onEvent(_ handler: @escaping (GWEvent) -> Void) {
        eventHandlers.append(handler)
    }
}
