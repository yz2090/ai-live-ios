import Foundation
import AVFAudio
import Combine

// MARK: - 音频播放服务（精简播放端：只播 TTS 语音队列 + 后台保活）
class AudioPlayerService: NSObject, ObservableObject {
    static let shared = AudioPlayerService()

    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var ttsVolume: Float {
        didSet { UserDefaults.standard.set(ttsVolume, forKey: "ailive_lite_tts_volume") }
    }

    private var player: AVAudioPlayer?          // TTS 播放器
    private var keepAlivePlayer: AVAudioPlayer? // 后台静音保活播放器（防止iOS挂起）
    private var audioQueue: [Data] = []          // TTS 音频队列
    private var isPlayingQueue = false

    override private init() {
        let savedTts = UserDefaults.standard.object(forKey: "ailive_lite_tts_volume") as? Float ?? 1.0
        ttsVolume = savedTts
        super.init()
        setupAudioSession()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AiLiveLite] 音频会话初始化失败: \(error)")
        }
    }

    // ── TTS 播放队列 ──
    func enqueueAudio(_ data: Data) {
        guard data.count > 100 else { return }
        audioQueue.append(data)
        if !isPlayingQueue { playNext() }
    }

    private func playNext() {
        guard !audioQueue.isEmpty else {
            isPlayingQueue = false
            isPlaying = false
            return
        }
        let data = audioQueue.removeFirst()
        isPlayingQueue = true
        isPlaying = true

        do {
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.volume = isMuted ? 0 : ttsVolume
            player?.prepareToPlay()
            player?.play()
            print("[AiLiveLite] ▶ TTS播放 (\(data.count) 字节)")
        } catch {
            print("[AiLiveLite] TTS播放失败: \(error)")
            playNext()
        }
    }

    func clearQueue() {
        audioQueue.removeAll()
        player?.stop()
        player = nil
        isPlaying = false
        isPlayingQueue = false
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.volume = muted ? 0 : ttsVolume
    }

    func setTtsVolume(_ vol: Float) {
        ttsVolume = vol
        if !isMuted { player?.volume = vol }
    }

    // MARK: - 后台保活（静音音频循环，防止iOS挂起）
    /// APP进后台时调用：播放静音保持音频会话活跃，WebSocket不断线
    func startBackgroundKeepAlive() {
        guard keepAlivePlayer == nil else { return }
        do {
            // 生成 0.5 秒静音 WAV（AVAudioPlayer 需要标准WAV头，裸PCM播不了）
            let duration: Double = 0.5
            let sampleRate: Int = 8000
            let frameCount = Int(duration * Double(sampleRate))
            var wav = Data()
            // RIFF 头
            wav.append(contentsOf: Array("RIFF".utf8))
            let dataSize = frameCount * 2  // 16bit 单声道
            let riffSize = 36 + dataSize
            wav.append(contentsOf: littleEndianUInt32(UInt32(riffSize)))
            wav.append(contentsOf: Array("WAVE".utf8))
            // fmt 块
            wav.append(contentsOf: Array("fmt ".utf8))
            wav.append(contentsOf: littleEndianUInt32(16))          // fmt 块大小
            wav.append(contentsOf: littleEndianUInt16(1))           // PCM
            wav.append(contentsOf: littleEndianUInt16(1))           // 单声道
            wav.append(contentsOf: littleEndianUInt32(UInt32(sampleRate)))
            wav.append(contentsOf: littleEndianUInt32(UInt32(sampleRate * 2))) // 字节率
            wav.append(contentsOf: littleEndianUInt16(2))           // 块对齐
            wav.append(contentsOf: littleEndianUInt16(16))          // 位深
            // data 块
            wav.append(contentsOf: Array("data".utf8))
            wav.append(contentsOf: littleEndianUInt32(UInt32(dataSize)))
            for _ in 0..<frameCount {
                wav.append(0)  // 静音采样
                wav.append(0)
            }
            let player = try AVAudioPlayer(data: wav)
            player.volume = 0
            player.numberOfLoops = -1  // 无限循环
            player.prepareToPlay()
            player.play()
            keepAlivePlayer = player
            print("[AiLiveLite] 后台保活WAV启动 (\(dataSize) 字节)")
        } catch {
            print("[AiLiveLite] 后台保活音频启动失败: \(error)")
        }
    }

    /// 生成 WAV 小端字节
    private func littleEndianUInt16(_ v: UInt16) -> [UInt8] {
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    private func littleEndianUInt32(_ v: UInt32) -> [UInt8] {
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// APP回前台时调用：停止静音保活
    func stopBackgroundKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioPlayerService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player !== keepAlivePlayer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.playNext()
            }
        }
    }
}
