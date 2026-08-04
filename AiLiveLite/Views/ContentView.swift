import SwiftUI

// MARK: - 主界面（精简播放端：只接收安卓采集端推来的语音并播放）
struct ContentView: View {
    @EnvironmentObject var wsManager: WebSocketManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var pipManager: PiPOverlayManager

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
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("连接状态", systemImage: "antenna.radiowaves.left.and.right")
                }

                // ── 画中画悬浮窗（PiP）──
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("后台自动开启悬浮窗", isOn: Binding(
                            get: { pipManager.autoStartEnabled },
                            set: { pipManager.setAutoStart($0) }
                        ))

                        HStack {
                            if !pipManager.isPiPAvailable {
                                Text("此设备不支持画中画")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            } else if pipManager.isPiPActive {
                                Text("悬浮窗显示中")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else if !pipManager.canStartNow {
                                Text("暂不可开启（等待服务器连接/系统准备）")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            } else {
                                Text("可开启悬浮窗")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(pipManager.isPiPActive ? "关闭悬浮窗" : "开启悬浮窗") {
                                if pipManager.isPiPActive {
                                    pipManager.stopPiP()
                                } else {
                                    pipManager.startPiP()
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                            .disabled(!pipManager.isPiPAvailable || (!pipManager.isPiPActive && !pipManager.canStartNow))
                        }

                        Text("开启后，切到其它App时播报内容会显示在系统悬浮窗里（可拖到屏幕四角吸附）。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("画中画悬浮窗", systemImage: "pip")
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

                // ── 最近播报 ──
                Section {
                    if wsManager.lastMetaText.isEmpty {
                        Text("暂无播报")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(metaTypeLabel(wsManager.lastMetaType))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15))
                                    .cornerRadius(4)
                                Spacer()
                                Text(timeNow())
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(wsManager.lastMetaText)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label("最近播报", systemImage: "text.bubble")
                }

                // ── 声音控制 ──
                Section {
                    Toggle("静音", isOn: Binding(
                        get: { audioPlayer.isMuted },
                        set: { audioPlayer.setMuted($0) }
                    ))

                    VStack(spacing: 4) {
                        HStack {
                            Text("播报音量")
                            Spacer()
                            Text("\(Int(audioPlayer.ttsVolume * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { audioPlayer.ttsVolume },
                            set: { audioPlayer.setTtsVolume($0) }
                        ), in: 0...1)
                    }
                } header: {
                    Label("声音控制", systemImage: "speaker.wave.2")
                }

                // ── 背景音乐（后台保活 + 直播背景音乐）──
                Section {
                    // 从「文件」App 选择音乐（支持多选）
                    Button {
                        // iOS15 SwiftUI fileImporter 有 bug 不弹窗，改用 UIKit 原生选择器
                        MusicDocumentPicker.shared.present(
                            from: UIApplication.topViewController(),
                            allowedTypes: [.audio]
                        ) { urls in
                            var imported = 0
                            for url in urls {
                                let ext = url.pathExtension.lowercased()
                                guard ["mp3", "m4a", "wav", "aac", "flac", "caf"].contains(ext) else {
                                    continue
                                }
                                audioPlayer.importMusic(from: url)
                                imported += 1
                            }
                            if imported == 0 {
                                audioPlayer.lastImportError = "未找到支持的音频文件（mp3/m4a/wav）"
                            }
                        }
                    } label: {
                        Label("从文件选择音乐", systemImage: "folder")
                    }

                    if let errMsg = audioPlayer.lastImportError {
                        Text(errMsg)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    // 音乐列表
                    if audioPlayer.musicFiles.isEmpty {
                        Text("还没有音乐，点击上方按钮从「文件」App 选择（可多选）")
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
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    // 开关 + 播放控制
                    Toggle("背景音乐", isOn: Binding(
                        get: { audioPlayer.isMusicPlaying },
                        set: { _ in audioPlayer.toggleMusic() }
                    ))
                    .disabled(audioPlayer.musicFileCount == 0)

                    if audioPlayer.musicFileCount > 0 {
                        HStack {
                            Text("当前")
                            Spacer()
                            Text(audioPlayer.currentMusicName)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Button {
                                audioPlayer.nextMusic()
                            } label: {
                                Image(systemName: "forward.end.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!audioPlayer.isMusicPlaying)
                        }

                        VStack(spacing: 4) {
                            HStack {
                                Text("音乐音量")
                                Spacer()
                                Text("\(Int(audioPlayer.musicVolume * 100))%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(
                                get: { audioPlayer.musicVolume },
                                set: { audioPlayer.setMusicVolume($0) }
                            ), in: 0...1)
                        }
                    }
                } header: {
                    Label("背景音乐（后台保活）", systemImage: "music.note")
                }

                // ── 日志 ──
                Section {
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
            .navigationTitle("AI播放端")
        }
    }

    private func metaTypeLabel(_ type: String) -> String {
        switch type {
        case "danmaku": return "💬 弹幕"
        case "warmup": return "📢 暖场"
        case "time": return "🕐 报时"
        case "order": return "💰 下单"
        case "follow": return "❤️ 关注"
        case "gift": return "🎁 礼物"
        default: return type.isEmpty ? "📢 播报" : type
        }
    }

    private func timeNow() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date())
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
