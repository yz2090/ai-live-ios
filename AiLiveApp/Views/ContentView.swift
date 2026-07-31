import SwiftUI

// MARK: - 主界面（iPhone 播放端）
struct ContentView: View {
    @EnvironmentObject var wsManager: WebSocketManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var webCapture: WebCaptureManager

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
                    HStack {
                        Button(audioPlayer.isMusicPlaying ? "⏸ 暂停音乐" : "▶ 播放音乐") {
                            audioPlayer.toggleMusic()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brown)

                        Button("⏭ 切歌") {
                            audioPlayer.nextMusic()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!audioPlayer.isMusicPlaying)
                    }
                    Text("音乐文件内置在App中，长按App图标可查看文件列表")
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

                    InfoRow(label: "状态", value: webCapture.lastStatus)
                    InfoRow(label: "已抓评论", value: "\(webCapture.capturedCount) 条")

                    if !webCapture.recentLog.isEmpty {
                        Text(webCapture.recentLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.black.opacity(0.85))
                            .cornerRadius(8)
                    }
                    Text("启动后会在后台加载百应直播控制台，登录一次直播账号（Cookie自动保存），之后自动抓公屏评论并发送到服务器")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } header: {
                    Label("🌐 网页采集", systemImage: "globe")
                }

                // ── 播报历史 ──
                Section {
                    if wsManager.broadcastHistory.isEmpty {
                        Text("暂无播报记录")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
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
