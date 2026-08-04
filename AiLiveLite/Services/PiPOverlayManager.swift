import UIKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import Combine

// MARK: - 画中画（PiP）悬浮窗管理器
/// 通过 AVPictureInPictureController + AVSampleBufferDisplayLayer
/// 把「最近播报文字」渲染成系统级悬浮窗，可吸附屏幕四角，悬浮在其它App上层。
/// iOS 15+ 通用方案（App Store 合规，无需审核特批）。
final class PiPOverlayManager: NSObject, ObservableObject {
    static let shared = PiPOverlayManager()

    @Published var isPiPActive = false       // 当前 PiP 是否在显示
    @Published var isPiPAvailable = false    // 当前设备是否支持 PiP（模拟器不支持）
    @Published var autoStartEnabled = true   // 后台自动开启 PiP
    @Published var canStartNow = false       // 当前是否可启动（诊断+UI）
    @Published var lastPiPError: String? = nil  // 最近一次 PiP 错误（显示到UI）

    private var pipController: AVPictureInPictureController?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipContainerView: UIView?    // 隐藏容器：承载 displayLayer（PiP 必需挂在视图树）
    private var renderTimer: CADisplayLink?
    private var statusTimer: Timer?          // 每秒刷新可启动状态
    private var hasRenderedFirstFrame = false
    private var lastText = ""
    private var lastType = ""
    private var lastRenderedHash = 0
    private var cachedCGImage: CGImage?
    private var cachedPixelBuffer: CVPixelBuffer?
    private var observers: [NSObjectProtocol] = []

    // 渲染尺寸（16:9 画中画窗口宽高比），pt 单位
    private let renderWidth: CGFloat = 360
    private let renderHeight: CGFloat = 202

    // 订阅 WS 的播报文字变化
    private var wsCancellable: AnyCancellable?

    private override init() {
        super.init()
        autoStartEnabled = UserDefaults.standard.object(forKey: "ailive_lite_pip_auto") as? Bool ?? true
    }

    deinit {
        statusTimer?.invalidate()
        renderTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 生命周期：App 启动后调用一次
    func setup() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("[PiP] 设备不支持画中画")
            return
        }
        guard pipController == nil else { return }

        // 渲染层：必须挂到视图层级（隐藏容器），PiP 系统才能消费帧
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = UIColor.black.cgColor
        layer.frame = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight))
        container.isHidden = true
        container.layer.addSublayer(layer)
        // 挂到当前 keyWindow（隐藏容器，用户看不到）
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(container)
        }
        pipContainerView = container
        displayLayer = layer
        print("[PiP] 渲染层已挂载到窗口层级")

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        pipController = controller
        isPiPAvailable = true

        // 订阅播报文字
        wsCancellable = WebSocketManager.shared.$lastMetaText
            .combineLatest(WebSocketManager.shared.$lastMetaType)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text, type in
                self?.updateContent(text: text, type: type)
            }

        addObservers()

        // 持续渲染（2-5fps）：PiP 启动前后都需要有视频流
        lastText = "AI播放端 · 待命中"
        startRenderTimer()
        renderFrame()

        refreshCanStart()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshCanStart()
        }

        print("[PiP] 初始化完成，自动开启: \(autoStartEnabled)")
    }

    /// 刷新当前是否可启动（供 UI 显示 + 诊断）
    private func refreshCanStart() {
        let can = pipController?.isPictureInPicturePossible ?? false
        if canStartNow != can {
            canStartNow = can
            print("[PiP] 可启动状态: \(can) (active=\(pipController?.isPictureInPictureActive ?? false))")
        }
    }

    // MARK: - 持续渲染
    private func startRenderTimer() {
        guard renderTimer == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 5)
        }
        link.add(to: .main, forMode: .common)
        renderTimer = link
        print("[PiP] 持续渲染定时器已启动 (2-5fps)")
    }

    @objc private func tick() {
        renderFrame()
    }

    // MARK: - 公开控制
    func startPiP() {
        guard let pip = pipController else {
            lastPiPError = "未初始化"
            print("[PiP] 未初始化，无法启动")
            return
        }
        print("[PiP] startPiP: possible=\(pip.isPictureInPicturePossible) active=\(pip.isPictureInPictureActive) 首帧=\(hasRenderedFirstFrame)")

        // PiP 启动前：确保音频会话处于正确状态（.playback + .mixWithOthers，保持与抖音共存）
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            print("[PiP] 音频会话已重置: category=\(session.category.rawValue) options=\(session.categoryOptions.rawValue)")
        } catch {
            print("[PiP] 音频会话设置失败: \(error)")
        }

        // 启动前强制渲染一帧，确保 layer 有数据
        renderFrame()

        guard pip.isPictureInPicturePossible else {
            lastPiPError = hasRenderedFirstFrame ? "系统暂不允许（音频/前台状态问题）" : "渲染层还没有画面"
            print("[PiP] 暂不可启动")
            return
        }
        if !pip.isPictureInPictureActive {
            lastPiPError = nil
            pip.startPictureInPicture()
            print("[PiP] 已请求启动画中画")
        }
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    // 自动开启开关
    func setAutoStart(_ on: Bool) {
        autoStartEnabled = on
        UserDefaults.standard.set(on, forKey: "ailive_lite_pip_auto")
    }

    // MARK: - 内容更新（播报文字变化时重绘）
    private func updateContent(text: String, type: String) {
        lastText = text
        lastType = type
        renderFrame()   // 立即重绘，不等下一 tick
    }

    // MARK: - 渲染
    private func renderFrame() {
        guard let layer = displayLayer else { return }

        // 内容变了 → 重新绘制图片
        let hash = "\(lastType)|\(lastText)".hashValue
        if hash != lastRenderedHash {
            let image = drawTextImage(text: lastText, type: lastType)
            if let cg = image.cgImage {
                cachedCGImage = cg
                cachedPixelBuffer = nil   // 内容变了，缓冲作废，下次重建
            }
            lastRenderedHash = hash
        }

        guard let cgImage = cachedCGImage else {
            print("[PiP] 渲染失败: 无图片数据")
            return
        }

        // 复用或创建 pixelBuffer
        if cachedPixelBuffer == nil {
            cachedPixelBuffer = makePixelBuffer(from: cgImage)
        }
        guard let pb = cachedPixelBuffer else {
            print("[PiP] 渲染失败: CVPixelBufferCreate 返回 nil")
            return
        }

        // 每帧新建 sampleBuffer（PTS 单调递增），入队给 PiP
        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        timing.duration = CMTime(value: 1, timescale: 60)
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pb,
                                                     formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else {
            print("[PiP] 渲染失败: 格式描述创建失败")
            return
        }
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pb,
                                                 formatDescription: fd,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        if let sb = sampleBuffer {
            layer.enqueue(sb)
            if !hasRenderedFirstFrame {
                hasRenderedFirstFrame = true
                print("[PiP] ✅ 首帧已入队，PiP 应可启动")
            }
        } else {
            print("[PiP] 渲染失败: sampleBuffer 创建失败")
        }
    }

    /// 创建 IOSurface-backed 的 CVPixelBuffer（真机 PiP 必需）
    private func makePixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(renderWidth * 2),
            kCVPixelBufferHeightKey as String: Int(renderHeight * 2),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as [String: Any]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                            Int(renderWidth * 2), Int(renderHeight * 2),
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary,
                            &pixelBuffer)
        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                               width: Int(renderWidth * 2),
                               height: Int(renderHeight * 2),
                               bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: renderWidth * 2, height: renderHeight * 2))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    // 把文字画成 UIImage（黑色半透明底 + 大字）
    private func drawTextImage(text: String, type: String) -> UIImage {
        let w = renderWidth
        let h = renderHeight
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)

        return renderer.image { ctx in
            // 背景
            UIColor(white: 0, alpha: 0.75).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

            // 顶部类型标签 + 时间
            let typeStr = type.isEmpty ? "AI播放端" : typeLabel(type)
            let timeStr = timeNow()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 14),
                .foregroundColor: UIColor.systemYellow
            ]
            typeStr.draw(at: CGPoint(x: 16, y: 12), withAttributes: attrs)

            let timeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.systemGray2
            ]
            let timeSize = (timeStr as NSString).size(withAttributes: timeAttrs)
            timeStr.draw(at: CGPoint(x: w - timeSize.width - 16, y: 14), withAttributes: timeAttrs)

            // 中间大字：播报文字（自动换行，最多3行）
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22),
                .foregroundColor: UIColor.white
            ]
            let textRect = CGRect(x: 16, y: 46, width: w - 32, height: h - 60)
            (text as NSString).draw(with: textRect,
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: textAttrs,
                                    context: nil)
        }
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "danmaku": return "💬 弹幕"
        case "warmup": return "📢 暖场"
        case "time": return "🕐 报时"
        case "order": return "💰 下单"
        case "follow": return "❤️ 关注"
        case "gift": return "🎁 礼物"
        default: return "📢 播报"
        }
    }

    private func timeNow() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date())
    }

    // MARK: - 系统状态观察（前后台切换）
    private func addObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            // 进后台：如果开启了自动 PiP 且还没启动，就启动（延迟一下更稳，避免被系统忽略）
            if self.autoStartEnabled && self.pipController?.isPictureInPictureActive == false {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard self.autoStartEnabled, self.pipController?.isPictureInPictureActive == false else { return }
                    print("[PiP] 后台自动启动请求: possible=\(self.pipController?.isPictureInPicturePossible ?? false)")
                    self.startPiP()
                }
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            // 回前台：不强制关，让用户自己决定（PiP 可以继续悬浮）
        })
    }
}

// MARK: - PiP 控制器代理
extension PiPOverlayManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
        lastPiPError = nil
        print("[PiP] 已启动")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
        print("[PiP] 已停止")
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        lastPiPError = "启动失败: \(error.localizedDescription)"
        print("[PiP] 启动失败: \(error)")
    }
}

// MARK: - 播放代理（渲染帧源）
extension PiPOverlayManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 60))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
