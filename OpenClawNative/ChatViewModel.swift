import Foundation
import SwiftUI

// MARK: - 聊天消息模型
struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user, assistant, system
    }
    let id = UUID()
    var role: Role
    var text: String
    var isStreaming = false
    var attachments: [ChatAttachment] = []
    var timestamp = Date()
}

struct ChatAttachment: Identifiable, Equatable {
    let id = UUID()
    var fileName: String
    var mimeType: String
    var dataURL: String  // data:image/png;base64,...
    var sizeBytes: Int
    var thumbnail: UIImage?
}

// MARK: - 会话状态
enum ChatConnectionState: Equatable {
    case disconnected, connecting, connected, error(String)
}

// MARK: - 聊天 ViewModel
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var connectionState: ChatConnectionState = .disconnected
    @Published var inputText = ""
    @Published var isSending = false
    @Published var lastError: String?

    private var client: OpenClawClient?
    private var sessionKey: String?
    private var activeRunId: String?

    // 配置（可在设置页改，默认公网）
    var serverURL = "ws://59.110.152.66:18899"
    var token = ""  // 首次使用填 token

    // MARK: 连接
    func connect() {
        guard !serverURL.isEmpty else {
            connectionState = .error("服务器地址为空")
            return
        }
        connectionState = .connecting
        let client = OpenClawClient(serverURL: serverURL, token: token)
        self.client = client

        // 订阅 agent 事件（流式回复）
        client.onEvent { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }

        // 连接状态轮询
        client.connect()
        // 等 hello-ok 后建会话
        Task {
            // 简单轮询等连接（最多10秒）
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if client.isConnected {
                    self.connectionState = .connected
                    self.ensureSession()
                    return
                }
                if let err = client.lastError {
                    self.connectionState = .error(err)
                    return
                }
            }
            self.connectionState = .error("连接超时")
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        connectionState = .disconnected
    }

    // MARK: 会话
    private func ensureSession() {
        guard let client = client else { return }
        if let key = sessionKey { return }
        let key = "native-\(UUID().uuidString.prefix(8))"
        client.send(method: "sessions.create", params: ["key": key]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let payload):
                    self.sessionKey = (payload["key"] as? String) ?? (payload["sessionKey"] as? String) ?? key
                    // 拉取历史
                    self.loadHistory()
                case .failure(let e):
                    self.connectionState = .error("建会话失败: \(e)")
                }
            }
        }
    }

    private func loadHistory() {
        guard let client = client, let sessionKey = sessionKey else { return }
        client.send(method: "chat.history", params: ["sessionKey": sessionKey]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .success(let payload) = result,
                   let rows = payload["rows"] as? [[String: Any]] {
                    // 解析历史（简单处理：只取 user/assistant 文本）
                    var msgs: [ChatMessage] = []
                    for row in rows {
                        if let role = row["role"] as? String,
                           let text = row["text"] as? String, !text.isEmpty {
                            let r: ChatMessage.Role = role == "user" ? .user : .assistant
                            msgs.append(ChatMessage(role: r, text: text))
                        }
                    }
                    if !msgs.isEmpty {
                        self.messages = msgs
                    }
                }
            }
        }
    }

    // MARK: 发送
    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = client, client.isConnected else {
            if text.isEmpty { return }
            connectionState = .error("未连接")
            return
        }
        inputText = ""
        sendMessage(text: text, attachments: [])
    }

    func sendWithAttachment(_ attachment: ChatAttachment, text: String = "") {
        guard let client = client, client.isConnected else {
            connectionState = .error("未连接")
            return
        }
        // 加入用户消息气泡
        let msg = ChatMessage(role: .user, text: text.isEmpty ? "[附件] \(attachment.fileName)" : text, attachments: [attachment])
        messages.append(msg)
        sendMessage(text: text, attachments: [attachment])
    }

    private func sendMessage(text: String, attachments: [ChatAttachment]) {
        guard let client = client, let sessionKey = sessionKey else {
            // 没会话先建
            ensureSession()
            return
        }
        isSending = true
        let idempotencyKey = UUID().uuidString
        var params: [String: Any] = [
            "sessionKey": sessionKey,
            "message": text,
            "idempotencyKey": idempotencyKey
        ]
        if !attachments.isEmpty {
            params["attachments"] = attachments.map { att in
                [
                    "id": att.id.uuidString,
                    "mimeType": att.mimeType,
                    "fileName": att.fileName,
                    "sizeBytes": att.sizeBytes,
                    "dataUrl": att.dataURL
                ]
            }
        }
        // 加 assistant 占位气泡（流式填充）
        let placeholder = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(placeholder)

        client.send(method: "chat.send", params: params) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let payload):
                    self.activeRunId = payload["runId"] as? String
                case .failure(let e):
                    self.isSending = false
                    if let idx = self.messages.lastIndex(where: { $0.id == placeholder.id }) {
                        self.messages[idx].text = "⚠️ 发送失败: \(e)"
                        self.messages[idx].isStreaming = false
                    }
                }
            }
        }
    }

    // MARK: 事件处理（agent 流式回复）
    private func handleEvent(_ event: GWEvent) {
        switch event.name {
        case "agent":
            let p = event.payload
            // 流式文本
            if let delta = p["deltaText"] as? String, !delta.isEmpty {
                if let idx = messages.indices.last, messages[idx].isStreaming {
                    messages[idx].text += delta
                } else {
                    // 没有占位气泡则新建
                    messages.append(ChatMessage(role: .assistant, text: delta, isStreaming: true))
                }
            }
            // 完成
            if let done = p["done"] as? Bool, done == true,
               let idx = messages.indices.last, messages[idx].isStreaming {
                messages[idx].isStreaming = false
                isSending = false
                activeRunId = nil
            }
        case "session.message":
            // 终态消息（含完整文本）
            let p = event.payload
            if let text = p["text"] as? String, !text.isEmpty {
                if let idx = messages.indices.last, messages[idx].isStreaming {
                    messages[idx].text = text
                    messages[idx].isStreaming = false
                }
                isSending = false
            }
        default:
            break
        }
    }

    // MARK: 会话重置
    func resetSession() {
        messages = []
        sessionKey = nil
        if let client = client, client.isConnected {
            ensureSession()
        }
    }
}
