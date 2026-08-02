import SwiftUI
import AVFAudio

@main
struct AiLiveLiteApp: App {
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
            print("[AiLiveLite] 后台音频会话配置失败: \(error)")
        }
        return true
    }

    // 后台时保持连接：播放静音音频防止iOS挂起
    func applicationDidEnterBackground(_ application: UIApplication) {
        AudioPlayerService.shared.startBackgroundKeepAlive()
    }

    // 回前台：停止静音保活
    func applicationWillEnterForeground(_ application: UIApplication) {
        AudioPlayerService.shared.stopBackgroundKeepAlive()
        // 如果断线了立即重连
        if !WebSocketManager.shared.isConnected {
            WebSocketManager.shared.connect()
        }
    }
}
