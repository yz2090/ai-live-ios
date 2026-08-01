import SwiftUI

// MARK: - 主界面（iPhone 播放端）
struct ContentView: View {
    @EnvironmentObject var wsManager: WebSocketManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var webCapture: WebCaptureManager
    @State private var showMusicPicker = false

    var body: some View {
        NavigationView {
            List {
                // ── 连接状态 ──
                Section {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(wsManager.isConnected ? Color.green : Color.red)
                                .frame(width: 14, height: 14)
                            Text(wsManager.statusMessage)
                                .font(.headline)
                            Spacer()
                            Button(wsManager.isConnected ? "断开" : "连接") {
                                if wsManager.isConnected {
                                    wsManager.disconnect()
                                } else {
                                    wsManager.connect()
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(wsManager.isConnected ? .red : .blue)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            InfoRow(label: "服务器", value: "\(kServerHost):\(kServerPort)")
                            InfoRow(label: "播放状态", value: audioPlayer.isPlaying ? "播报中" : "待命")
                            if audioPlayer.isMusicPlaying {
                                InfoRow(label: "背景音乐", value: "播放中")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("连接状态", systemImage: "antenna.radiowaves.left.and.right")
                }

                // ── 设备ID ──
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(wsManager.deviceId)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text("把这个ID填到安卓采集端的「iPhone设备ID」里，音频就会推送到这台iPhone")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("设备ID（绑定用）", systemImage: "iphone")
                }

                // ── 目标手机PID（采集数据归属）──
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("填安卓手机PID，如 phone_e3ee96400caa1601", text: $wsManager.targetPid)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Text("采集的评论/订单/核心数据将归属到这台手机（用它的bark_key推送、用它的话术回复）。留空则用本机设备ID")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("目标手机PID", systemImage: "target")
                }

                // ── 声音控制 ──
                Section {
                    Toggle("静音", isOn: Binding(
                        get: { audioPlayer.isMuted },
                        set: { audioPlayer.setMuted($0) }
                    ))

                    VStack(spacing: 4) {
                        HStack {
                            Text("人声音量")
                            Spacer()
                            Text("\(Int(audioPlayer.ttsVolume * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { audioPlayer.ttsVolume },
                            set: { audioPlayer.setTtsVolume($0) }
                        ), in: 0...1)
                    }

                    VStack(spacing: 4) {
                        HStack {
                            Text("音乐音量")
                            Spacer()
                            Text("\(Int(audioPlayer.musicVolume * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $audioPlayer.musicVolume, in: 0...1)
                    }
                } header: {
                    Label("声音控制", systemImage: "speaker.wave.2")
                }

                // ── 背景音乐 ──
                Section {
                    Button {
                        showMusicPicker = true
                    } label: {
                        Label("从文件选择音乐", systemImage: "folder")
                    }
                    .fileImporter(
                        isPresented: $showMusicPicker,
                        allowedContentTypes: [.audio],
                        allowsMultipleSelection: true
                    ) { result in
                        if case .success(let urls) = result {
                            for url in urls {
                                audioPlayer.importMusic(from: url)
                            }
                        }
                    }

                    if audioPlayer.musicFiles.isEmpty {
                        Text("还没有音乐，点击上方按钮从文件App导入")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(audioPlayer.musicFiles.enumerated()), id: \.offset) { index, url in
                            HStack {
                                Image(systemName: "music.note")
                                    .foregroundColor(.brown)
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                if audioPlayer.isMusicPlaying && index == audioPlayer.currentMusicIndex {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundColor(.green)
                                }
                                Button {
                                    audioPlayer.removeMusic(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                            }
                        }

                        HStack {
                            Button(audioPlayer.isMusicPlaying ? "⏸ 暂停" : "▶ 播放") {
                                audioPlayer.toggleMusic()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.brown)

                            Button("⏭ 下一首") {
                                audioPlayer.nextMusic()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!audioPlayer.isMusicPlaying)
                        }
                    }
                    Text("音乐文件保存在App内，导入后离线可用；AI说话时音乐自动降低音量")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } header: {
                    Label("背景音乐", systemImage: "music.note")
                }

                // ── 网页采集（百应控制台）──
                Section {
                    Toggle("网页采集", isOn: Binding(
                        get: { webCapture.isRunning },
                        set: { newVal in
                            if newVal {
                                webCapture.start()
                            } else {
                                webCapture.stop()
                            }
                        }
                    ))
                    .tint(.green)

                    // 登录状态 + 登录按钮
                    HStack {
                        Label(
                            webCapture.isLoggedIn ? "已登录" : "未登录",
                            systemImage: webCapture.isLoggedIn ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                        )
                        .foregroundColor(webCapture.isLoggedIn ? .green : .orange)

                        Spacer()

                        Button(webCapture.isLoggedIn ? "重新登录" : "统一登录") {
                            webCapture.openLogin()
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }

                    InfoRow(label: "状态", value: webCapture.lastStatus)
                    InfoRow(label: "已抓评论", value: "\(webCapture.capturedCount) 条")
                    InfoRow(label: "已抓订单", value: "\(webCapture.orderCapturedCount) 单")
                    if !webCapture.orderLastInfo.isEmpty {
                        InfoRow(label: "最新订单", value: webCapture.orderLastInfo)
                    }

                    if !webCapture.recentLog.isEmpty {
                        // 限高 + 内部可滚动（信息多时框内上下滑动）
                        ScrollView {
                            Text(webCapture.recentLog)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 60, maxHeight: 200)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(8)
                    }
                    Text("启动后会在后台加载百应直播控制台抓评论 + 巨量百应大屏抓订单；首次使用点「统一登录」扫码一次（buyin 登录后自动跳 compass 补登），登录态自动保存")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } header: {
                    Label("🌐 网页采集", systemImage: "globe")
                }
                .sheet(isPresented: $webCapture.showLoginSheet) {
                    // 百应登录 WebView（buyin 或 compass）
                    LoginWebView(manager: webCapture, url: webCapture.loginURL)
                        .ignoresSafeArea()
                        .overlay(alignment: .top) {
                            HStack {
                                Spacer()
                                Button {
                                    webCapture.closeLogin()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(Color.black.opacity(0.5))
                                        .clipShape(Circle())
                                }
                                .padding(.top, 8)
                                .padding(.trailing, 8)
                            }
                        }
                }

                // ── 播报历史 ──
                Section {
                    if wsManager.broadcastHistory.isEmpty {
                        Text("暂无播报记录")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        // 限高 + 内部可滚动
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(wsManager.broadcastHistory) { entry in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(entry.typeLabel)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color(hex: entry.typeColor).opacity(0.15))
                                                .cornerRadius(4)
                                            Spacer()
                                            Text(entry.time)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Text(entry.text)
                                            .font(.subheadline)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(4)
                        }
                        .frame(minHeight: 100, maxHeight: 280)
                    }
                } header: {
                    HStack {
                        Label("播报历史", systemImage: "text.bubble")
                        Spacer()
                        if !wsManager.broadcastHistory.isEmpty {
                            Button("清空") {
                                wsManager.broadcastHistory.removeAll()
                            }
                            .font(.caption)
                        }
                    }
                }

                // ── 日志 ──
                Section {
                    ScrollViewReader { _ in
                        ScrollView {
                            Text(wsManager.recentLog.isEmpty ? "暂无日志" : wsManager.recentLog)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 120, maxHeight: 200)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(8)
                    }
                } header: {
                    HStack {
                        Label("运行日志", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Button("清空") {
                            wsManager.recentLog = ""
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("AI直播助手 · 播放端")
        }
        .onAppear {
            // 连接由 App 入口统一管理（AiLiveApp.swift），这里不再重复调用
        }
    }
}

// MARK: - 辅助组件
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Color hex 扩展
extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}
