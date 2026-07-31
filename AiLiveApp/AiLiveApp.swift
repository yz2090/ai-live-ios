import SwiftUI
import AVFAudio

@main
struct AiLiveApp: App {
    @StateObject private var wsManager = WebSocketManager.shared
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(wsManager)
                .environmentObject(audioPlayer)
                .onAppear {
                    // 启动时自动连接
                    wsManager.connect()
                }
        }
    }
}

// MARK: - AppDelegate：后台音频持续播放
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 配置后台音频会话
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AiLive] 后台音频会话配置失败: \(error)")
        }
        return true
    }

    // 后台时保持连接
    func applicationDidEnterBackground(_ application: UIApplication) {
        // 音频会话已配置为 playback，App 会持续在后台运行
    }
}
