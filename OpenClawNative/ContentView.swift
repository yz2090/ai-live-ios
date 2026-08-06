import SwiftUI
import UniformTypeIdentifiers
import Speech

@main
struct OpenClawNativeApp: App {
    @StateObject private var vm = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
    }
}

// MARK: - 主界面
struct ContentView: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var showSettings = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var isRecording = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 状态栏
                statusBar
                // 消息列表
                messageList
                // 输入栏
                inputBar
            }
            .navigationTitle("OpenClaw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        vm.resetSession()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            // 相册（用 UIImagePickerController 兼容 iOS 15）
            .fullScreenCover(isPresented: $showPhotoPicker) {
                ImagePicker(sourceType: .photoLibrary) { image in
                    if let data = image.jpegData(compressionQuality: 0.8) {
                        let b64 = data.base64EncodedString()
                        let att = ChatAttachment(
                            fileName: "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                            mimeType: "image/jpeg",
                            dataURL: "data:image/jpeg;base64,\(b64)",
                            sizeBytes: data.count,
                            thumbnail: image
                        )
                        vm.sendWithAttachment(att, text: "")
                    }
                }
            }
            // 相机
            .fullScreenCover(isPresented: $showCamera) {
                ImagePicker(sourceType: .camera) { image in
                    if let data = image.jpegData(compressionQuality: 0.8) {
                        let b64 = data.base64EncodedString()
                        let att = ChatAttachment(
                            fileName: "camera-\(Int(Date().timeIntervalSince1970)).jpg",
                            mimeType: "image/jpeg",
                            dataURL: "data:image/jpeg;base64,\(b64)",
                            sizeBytes: data.count,
                            thumbnail: image
                        )
                        vm.sendWithAttachment(att, text: "")
                    }
                }
            }
            // 文件
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        handleFile(url)
                    }
                }
            }
            .onAppear {
                if vm.connectionState == .disconnected && !vm.token.isEmpty {
                    vm.connect()
                }
            }
        }
    }

    // MARK: 状态栏
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if vm.connectionState == .disconnected || vm.connectionState == .connecting {
                Button("连接") { vm.connect() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            } else {
                Button("断开") { vm.disconnect() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    private var statusColor: Color {
        switch vm.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch vm.connectionState {
        case .connected: return "已连接"
        case .connecting: return "连接中..."
        case .error(let e): return "错误: \(e)"
        case .disconnected: return "未连接"
        }
    }

    // MARK: 消息列表
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(msg: msg)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: vm.messages.count) { _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: 输入栏
    private var inputBar: some View {
        VStack(spacing: 8) {
            // 附件按钮行
            HStack(spacing: 20) {
                Button { showPhotoPicker = true } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20))
                        Text("相册").font(.caption2)
                    }
                }
                Button { showCamera = true } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "camera")
                            .font(.system(size: 20))
                        Text("拍照").font(.caption2)
                    }
                }
                Button { showFilePicker = true } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.system(size: 20))
                        Text("文件").font(.caption2)
                    }
                }
                Button { toggleRecording() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 20))
                            .foregroundColor(isRecording ? .red : .primary)
                        Text(isRecording ? "录音中" : "语音").font(.caption2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .foregroundColor(.primary)

            // 文本输入行
            HStack(spacing: 8) {
                TextField("输入消息...", text: $vm.inputText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    vm.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(vm.inputText.isEmpty ? .gray : .blue)
                }
                .disabled(vm.inputText.isEmpty || vm.isSending)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    // MARK: 文件处理
    private func handleFile(_ url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        var mime = "application/octet-stream"
        if ext == "pdf" { mime = "application/pdf" }
        else if ["png"].contains(ext) { mime = "image/png" }
        else if ["jpg","jpeg"].contains(ext) { mime = "image/jpeg" }
        else if ["txt","md"].contains(ext) { mime = "text/plain" }
        else if ["mp3","m4a","wav"].contains(ext) { mime = "audio/\(ext)" }
        else if ["mp4","mov"].contains(ext) { mime = "video/\(ext)" }

        let b64 = data.base64EncodedString()
        let att = ChatAttachment(
            fileName: url.lastPathComponent,
            mimeType: mime,
            dataURL: "data:\(mime);base64,\(b64)",
            sizeBytes: data.count,
            thumbnail: nil
        )
        vm.sendWithAttachment(att, text: "")
    }

    // MARK: 语音（本地识别 → 文本）
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    vm.lastError = "语音权限未开启"
                    return
                }
                isRecording = true
                SpeechRecognizer.shared.start { text in
                    DispatchQueue.main.async {
                        isRecording = false
                        if !text.isEmpty {
                            vm.inputText = text
                        }
                    }
                }
            }
        }
    }

    private func stopRecording() {
        SpeechRecognizer.shared.stop()
        isRecording = false
    }
}

// MARK: - 消息气泡
struct MessageBubble: View {
    let msg: ChatMessage

    var body: some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 60) }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                // 附件缩略图
                if !msg.attachments.isEmpty {
                    ForEach(msg.attachments) { att in
                        if let img = att.thumbnail {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 180, maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            HStack {
                                Image(systemName: "doc.fill")
                                Text(att.fileName).font(.caption)
                            }
                            .padding(6)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                // 文本
                Text(msg.text.isEmpty ? "…" : msg.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(msg.role == .user ? Color.blue : Color(.systemGray5))
                    .foregroundColor(msg.role == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if msg.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

// MARK: - 设置页
struct SettingsView: View {
    @EnvironmentObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("gw_server") private var server = ""
    @AppStorage("gw_token") private var token = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务器")) {
                    TextField("ws://地址", text: $server)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
                Section(header: Text("Token"), footer: Text("OpenClaw 网关令牌，在 ~/.openclaw/openclaw.json 的 gateway.auth.token")) {
                    SecureField("token", text: $token)
                        .autocapitalization(.none)
                }
                Section {
                    Button("保存并连接") {
                        vm.serverURL = server
                        vm.token = token
                        vm.connect()
                        dismiss()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                server = vm.serverURL.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "ServerURL") as? String ?? "") : vm.serverURL
                token = vm.token
            }
        }
    }
}

// MARK: - 通用图片选择器（相机/相册，兼容 iOS 15）
struct ImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType = .photoLibrary
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onCapture(img)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - 简易语音识别
class SpeechRecognizer: NSObject, SFSpeechRecognizerDelegate {
    static let shared = SpeechRecognizer()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(completion: @escaping (String) -> Void) {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            completion("")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        self.request = request
        request.shouldReportPartialResults = false

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try? audioEngine.start()

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result = result, result.isFinal {
                completion(result.bestTranscription.formattedString)
                self.stop()
            } else if error != nil {
                completion("")
                self.stop()
            }
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
