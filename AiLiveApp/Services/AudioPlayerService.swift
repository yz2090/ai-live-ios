import Foundation
import AVFAudio
import Combine

// MARK: - 音频播放服务（TTS队列 + 背景音乐循环 + 双音量 + 静音）
class AudioPlayerService: NSObject, ObservableObject {
    static let shared = AudioPlayerService()

    @Published var isPlaying = false
    @Published var isMusicPlaying = false
    @Published var currentMusicIndex = 0      // 当前播放的音乐序号
    @Published var musicFiles: [URL] = []      // 背景音乐列表（来自App沙盒Music目录）
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

    private var musicDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Music", isDirectory: true)
    }

    override private init() {
        let savedTts = UserDefaults.standard.object(forKey: "ailive_tts_volume") as? Float ?? 1.0
        let savedMusic = UserDefaults.standard.object(forKey: "ailive_music_volume") as? Float ?? 0.7
        ttsVolume = savedTts
        musicVolume = savedMusic
        super.init()
        setupAudioSession()
        loadMusicFromDocuments()
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

    // ── 背景音乐：从 App 沙盒 Music 目录扫描（用户通过文件App导入）──
    private func loadMusicFromDocuments() {
        let fm = FileManager.default
        try? fm.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        guard let files = try? fm.contentsOfDirectory(at: musicDirectory, includingPropertiesForKeys: nil) else {
            musicFiles = []
            return
        }
        let audioExts = ["mp3", "m4a", "wav", "aac", "flac", "caf"]
        musicFiles = files
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        print("[AiLive] 背景音乐 \(musicFiles.count) 首: \(musicFiles.map { $0.lastPathComponent })")
    }

    /// 从文件App导入音乐（复制到沙盒Music目录，持久保存）
    func importMusic(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try? fm.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        let dest = musicDirectory.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)  // 重名覆盖
        do {
            try fm.copyItem(at: url, to: dest)
            loadMusicFromDocuments()
            print("[AiLive] 🎵 已导入音乐: \(url.lastPathComponent)")
        } catch {
            print("[AiLive] 导入音乐失败: \(error)")
        }
    }

    /// 删除一首音乐（正在播放则停止）
    func removeMusic(at index: Int) {
        guard index < musicFiles.count else { return }
        let url = musicFiles[index]
        if bgmPlayer?.url?.standardizedFileURL == url.standardizedFileURL {
            stopMusic()
        }
        try? FileManager.default.removeItem(at: url)
        loadMusicFromDocuments()
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
        currentMusicIndex = musicIndex
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
            unduckMusic()
            return
        }
        let data = audioQueue.removeFirst()
        isPlayingQueue = true
        isPlaying = true
        duckMusic()

        do {
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.volume = isMuted ? 0 : ttsVolume
            player?.prepareToPlay()
            player?.play()
            print("[AiLive] ▶ TTS播放 (\(data.count) 字节)")
        } catch {
            print("[AiLive] TTS播放失败: \(error)")
            unduckMusic()
            playNext()
        }
    }

    // ── TTS 播报时背景音乐自动降低音量（duck 效果）──
    private func duckMusic() {
        guard bgmPlayer?.isPlaying == true else { return }
        bgmPlayer?.setVolume(musicVolume * 0.2, fadeDuration: 0.3)
        print("[AiLive] 🎚 背景音乐降低音量 (TTS播报)")
    }

    private func unduckMusic() {
        guard bgmPlayer != nil else { return }
        bgmPlayer?.setVolume(isMuted ? 0 : musicVolume, fadeDuration: 0.5)
        print("[AiLive] 🎚 背景音乐恢复音量")
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
            if audioQueue.isEmpty {
                unduckMusic()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.playNext()
            }
        }
    }
}
