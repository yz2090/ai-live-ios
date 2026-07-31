import Foundation
import AVFAudio
import Combine

// MARK: - 音频播放服务（TTS队列 + 背景音乐循环 + 双音量 + 静音）
class AudioPlayerService: NSObject, ObservableObject {
    static let shared = AudioPlayerService()

    @Published var isPlaying = false
    @Published var isMusicPlaying = false
    @Published var ttsVolume: Float {
        didSet { UserDefaults.standard.set(ttsVolume, forKey: "ailive_tts_volume") }
    }
    @Published var musicVolume: Float {
        didSet {
            UserDefaults.standard.set(musicVolume, forKey: "ailive_music_volume")
            bgmPlayer?.volume = musicVolume
        }
    }
    @Published var isMuted = false

    private var player: AVAudioPlayer?          // TTS 播放器
    private var bgmPlayer: AVAudioPlayer?       // 背景音乐播放器
    private var audioQueue: [Data] = []          // TTS 音频队列
    private var isPlayingQueue = false
    private var musicIndex = 0
    private var musicFiles: [URL] = []

    override private init() {
        let savedTts = UserDefaults.standard.object(forKey: "ailive_tts_volume") as? Float ?? 1.0
        let savedMusic = UserDefaults.standard.object(forKey: "ailive_music_volume") as? Float ?? 0.7
        ttsVolume = savedTts
        musicVolume = savedMusic
        super.init()
        setupAudioSession()
        loadBundledMusic()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AiLive] 音频会话初始化失败: \(error)")
        }
    }

    // ── 背景音乐：从 App Bundle 加载内置音乐 ──
    private func loadBundledMusic() {
        musicFiles = []
        if let urls = Bundle.main.urls(forResourcesWithExtension: "mp3", subdirectory: nil) {
            musicFiles = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        if let urls = Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) {
            musicFiles += urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        print("[AiLive] 内置音乐 \(musicFiles.count) 首: \(musicFiles.map { $0.lastPathComponent })")
    }

    func startMusic() {
        guard !musicFiles.isEmpty else { return }
        stopMusic()
        musicIndex = 0
        playMusic()
    }

    private func playMusic() {
        guard !musicFiles.isEmpty else { return }
        if musicIndex >= musicFiles.count { musicIndex = 0 }
        let url = musicFiles[musicIndex]
        do {
            bgmPlayer = try AVAudioPlayer(contentsOf: url)
            bgmPlayer?.delegate = self
            bgmPlayer?.numberOfLoops = 0
            bgmPlayer?.volume = isMuted ? 0 : musicVolume
            bgmPlayer?.prepareToPlay()
            bgmPlayer?.play()
            isMusicPlaying = true
            print("[AiLive] 🎵 背景音乐: \(url.lastPathComponent)")
        } catch {
            print("[AiLive] 背景音乐失败: \(error)")
            musicIndex += 1
            playMusic()
        }
    }

    func stopMusic() {
        bgmPlayer?.stop()
        bgmPlayer = nil
        isMusicPlaying = false
    }

    func toggleMusic() {
        if isMusicPlaying {
            stopMusic()
        } else {
            startMusic()
        }
    }

    func nextMusic() {
        musicIndex += 1
        playMusic()
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
            print("[AiLive] ▶ TTS播放 (\(data.count) 字节)")
        } catch {
            print("[AiLive] TTS播放失败: \(error)")
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
        bgmPlayer?.volume = muted ? 0 : musicVolume
    }

    func setTtsVolume(_ vol: Float) {
        ttsVolume = vol
        if !isMuted { player?.volume = vol }
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioPlayerService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === bgmPlayer {
            // 背景音乐播完，切下一首循环
            musicIndex += 1
            playMusic()
        } else {
            // TTS 播完，播下一条
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.playNext()
            }
        }
    }
}
