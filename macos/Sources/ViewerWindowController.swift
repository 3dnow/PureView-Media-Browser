import AppKit
import AVFoundation
import AVKit
import CoreMedia

/// 图片显示视图：深灰背景上等比居中绘制大图（AppKit 视图天然双缓冲，切图无闪烁）。
/// 音频模式下改画 "🎧 音频文件" + 文件信息。等价于原作 ImageHostProc。
final class ImageDisplayView: NSView {
    enum Mode { case image, audioText }
    var mode: Mode = .image { didSet { needsDisplay = true } }
    var image: NSImage? { didSet { needsDisplay = true } }
    var audioInfo: String = "" { didSet { needsDisplay = true } }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 25 / 255, alpha: 1).setFill()
        bounds.fill()

        switch mode {
        case .audioText:
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 24),
                .foregroundColor: NSColor(calibratedWhite: 220 / 255, alpha: 1)]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(calibratedWhite: 200 / 255, alpha: 1)]
            let title = "🎧 音频文件"
            let ts = title.size(withAttributes: titleAttrs)
            title.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY + 30), withAttributes: titleAttrs)
            let infoRect = NSRect(x: bounds.midX - 150, y: bounds.midY - 130, width: 300, height: 150)
            audioInfo.draw(in: infoRect, withAttributes: subAttrs)

        case .image:
            guard let image = image else { return }
            let iw = image.size.width, ih = image.size.height
            guard iw > 0, ih > 0 else { return }
            let ratio = min(bounds.width / iw, bounds.height / ih)
            let w = iw * ratio, h = ih * ratio
            let rect = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
}

/// 进度条：让父级得知拖拽的开始/结束，避免与周期性时间刷新互相打架。
final class SeekSlider: NSSlider {
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onStart?()
        super.mouseDown(with: event)   // NSSlider 内部跟踪循环直到松开
        onEnd?()
    }
}

/// 查看器窗口：图片 / 视频 / 音频播放 + 手搓播放控制器 + 信息面板 + GPS 反查 + 快捷键。
/// 等价于原作 ViewerProc + LoadMedia + LayoutViewer + 主消息循环里的键盘 hack。
final class ViewerWindowController: NSWindowController, NSWindowDelegate {

    private var mediaFiles: [MediaFile] = []
    private var currentIndex = -1
    private var currentType: MediaType = .unknown
    private var currentMediaInfo = ""

    // 媒体宿主
    private var imageHostView: ImageDisplayView!
    private var playerView: AVPlayerView!
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var isPlaying = false
    private var isSeeking = false

    // 信息面板
    private var infoPanel: NSView!
    private var infoTextField: NSTextField!
    private var gpsLabel: NSTextField!
    private var infoVisible = true

    // 播放控制
    private var playPauseButton: NSButton!
    private var seekSlider: SeekSlider!
    private var volumeSlider: NSSlider!
    private var timeLabel: NSTextField!
    private var volumeLabel: NSTextField!
    private var toggleInfoButton: NSButton!

    // GPS
    private var hasGPS = false
    private var curLat = 0.0, curLon = 0.0
    private var gpsFetched = false

    // 会话号（取消过期后台任务）
    private let imageLoadSession = AtomicInt()
    private let metaSession = AtomicInt()
    private let gpsSession = AtomicInt()
    private var debounceWork: DispatchWorkItem?
    private var keyMonitor: Any?

    // 全图缓存 + 相邻预取：←/→ 来回浏览不再重复解码。
    // NSCache 按像素字节计成本，内存压力自动驱逐；in-flight 集合避免预取与前台重复解码同一文件。
    private let fullImageCache = NSCache<NSString, NSImage>()
    private var decodeInFlight = Set<String>()
    private let decodeLock = NSLock()

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "查看器"
        win.center()
        self.init(window: win)
        window?.delegate = self
        window?.isReleasedWhenClosed = false
        buildUI()
        fullImageCache.countLimit = 6
        fullImageCache.totalCostLimit = 512 * 1024 * 1024
        _ = ThumbnailProvider.fullDecodeCap   // 在主线程触发 NSScreen 访问，之后后台线程只读常量
    }

    // MARK: - 打开

    func present(mediaFiles: [MediaFile], index: Int) {
        self.mediaFiles = mediaFiles
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
        loadMedia(index: index)
    }

    // MARK: - UI 构建

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        imageHostView = ImageDisplayView(frame: .zero)
        content.addSubview(imageHostView)

        playerView = AVPlayerView(frame: .zero)
        playerView.controlsStyle = .none   // 隐藏内置控件，用我们手搓的
        playerView.videoGravity = .resizeAspect
        playerView.isHidden = true
        content.addSubview(playerView)

        // 信息面板
        infoPanel = NSView(frame: .zero)
        infoPanel.wantsLayer = true
        infoPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        content.addSubview(infoPanel)

        infoTextField = makeLabel(size: 13, color: NSColor(calibratedWhite: 0.92, alpha: 1))
        infoPanel.addSubview(infoTextField)

        gpsLabel = makeLabel(size: 13, color: NSColor(calibratedWhite: 0.92, alpha: 1))
        gpsLabel.isSelectable = false
        infoPanel.addSubview(gpsLabel)
        let gpsClick = NSClickGestureRecognizer(target: self, action: #selector(openMap))
        gpsClick.numberOfClicksRequired = 2
        gpsLabel.addGestureRecognizer(gpsClick)

        // 顶部：信息栏开关
        toggleInfoButton = NSButton(title: "隐藏信息栏", target: self, action: #selector(toggleInfo))
        toggleInfoButton.bezelStyle = .rounded
        toggleInfoButton.refusesFirstResponder = true
        content.addSubview(toggleInfoButton)

        // 底部：播放控制
        playPauseButton = NSButton(title: "暂停", target: self, action: #selector(togglePlayPauseAction))
        playPauseButton.bezelStyle = .rounded
        playPauseButton.refusesFirstResponder = true
        content.addSubview(playPauseButton)

        seekSlider = SeekSlider()
        seekSlider.minValue = 0
        seekSlider.maxValue = 1
        seekSlider.doubleValue = 0
        seekSlider.isContinuous = true
        seekSlider.target = self
        seekSlider.action = #selector(seekChanged)
        seekSlider.onStart = { [weak self] in self?.isSeeking = true }
        seekSlider.onEnd = { [weak self] in
            self?.isSeeking = false
            self?.seekPrecise()   // 松手后做一次零容差精确定位
        }
        content.addSubview(seekSlider)

        timeLabel = makeLabel(size: 12, color: NSColor(calibratedWhite: 0.92, alpha: 1))
        timeLabel.stringValue = "00:00 / 00:00"
        content.addSubview(timeLabel)

        volumeSlider = NSSlider()
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = 100
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        content.addSubview(volumeSlider)

        volumeLabel = makeLabel(size: 12, color: NSColor(calibratedWhite: 0.92, alpha: 1))
        volumeLabel.stringValue = "🔊 100%"
        content.addSubview(volumeLabel)
    }

    private func makeLabel(size: CGFloat, color: NSColor) -> NSTextField {
        let tf = NSTextField(labelWithString: "")
        tf.font = NSFont.systemFont(ofSize: size)
        tf.textColor = color
        tf.maximumNumberOfLines = 0
        tf.lineBreakMode = .byWordWrapping
        tf.isEditable = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        return tf
    }

    // MARK: - 布局（等价 LayoutViewer）

    private func layoutViewer() {
        guard let content = window?.contentView else { return }
        let rc = content.bounds
        let infoWidth: CGFloat = infoVisible ? 300 : 0
        let ctrlHeight: CGFloat = (currentType == .image) ? 0 : 50

        let mediaRect = NSRect(x: 0, y: ctrlHeight, width: rc.width - infoWidth, height: rc.height - ctrlHeight)
        imageHostView.frame = mediaRect
        playerView.frame = mediaRect

        if infoVisible {
            infoPanel.isHidden = false
            infoPanel.frame = NSRect(x: rc.width - 300, y: 0, width: 300, height: rc.height)
            infoTextField.frame = NSRect(x: 12, y: max(0, rc.height - 160), width: 276, height: 140)
            gpsLabel.frame = NSRect(x: 12, y: 12, width: 276, height: max(0, rc.height - 180))   // 极小窗口下不产生负高度
        } else {
            infoPanel.isHidden = true
        }

        let showCtrl = (currentType != .image)
        playPauseButton.isHidden = !showCtrl
        seekSlider.isHidden = !showCtrl
        volumeSlider.isHidden = !showCtrl
        timeLabel.isHidden = !showCtrl
        volumeLabel.isHidden = !showCtrl

        // AppKit 原点在左下，控制条放窗口底部（y 小）
        playPauseButton.frame = NSRect(x: 10, y: 8, width: 64, height: 32)
        let seekWidth = max(60, rc.width - infoWidth - 400)
        seekSlider.frame = NSRect(x: 84, y: 12, width: seekWidth, height: 24)
        timeLabel.frame = NSRect(x: rc.width - infoWidth - 310, y: 14, width: 110, height: 20)
        volumeSlider.frame = NSRect(x: rc.width - infoWidth - 190, y: 12, width: 120, height: 24)
        volumeLabel.frame = NSRect(x: rc.width - infoWidth - 64, y: 14, width: 60, height: 20)

        toggleInfoButton.frame = NSRect(x: rc.width - infoWidth - 112, y: rc.height - 40, width: 104, height: 30)
        content.addSubview(toggleInfoButton, positioned: .above, relativeTo: nil)

        imageHostView.needsDisplay = true
    }

    func windowDidResize(_ notification: Notification) { layoutViewer() }

    // MARK: - 载入媒体（等价 LoadMedia）

    func loadMedia(index: Int) {
        guard index >= 0, index < mediaFiles.count else { return }
        currentIndex = index
        cancelDebounce()
        teardownPlayer()

        let file = mediaFiles[index]
        currentType = file.type
        window?.title = "媒体浏览器 - \(file.name)  (ESC 关闭 · ←/→ 切换 · 空格 播放/暂停)"

        // 元数据 + GPS：放后台线程，避免视频 4MB 扫描卡住 UI（原作是在 UI 线程做的，这里顺手改好）
        let ms = metaSession.increment()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let meta = MetadataReader.read(url: file.url, type: file.type)
            DispatchQueue.main.async {
                guard self.metaSession.current == ms else { return }
                self.currentMediaInfo = meta.infoText
                self.infoTextField.stringValue = meta.infoText
                self.imageHostView.audioInfo = meta.infoText
                self.hasGPS = meta.hasGPS
                self.curLat = meta.lat
                self.curLon = meta.lon
                self.gpsFetched = false
                self.triggerGpsFetch()
            }
        }

        switch file.type {
        case .image:
            imageHostView.mode = .image
            imageHostView.isHidden = false
            playerView.isHidden = true
            // 缓存命中也要自增会话号，作废在途的旧解码，防止旧图迟到覆盖
            let session = imageLoadSession.increment()
            if let cached = fullImageCache.object(forKey: file.url.path as NSString) {
                imageHostView.image = cached   // 命中：秒切，零解码
            } else {
                // 后台解码全图；旧图保留在屏直到新图就绪（零闪烁的关键，等价 WM_USER_IMAGE_LOADED）
                decodeFullImage(file.url) { [weak self] img in
                    guard let self = self, self.imageLoadSession.current == session else { return }
                    self.imageHostView.image = img
                }
            }
            prefetchNeighbors(around: index)   // 相邻预取：下一次 ←/→ 大概率秒开

        case .audio:
            imageHostView.mode = .audioText
            imageHostView.isHidden = false
            playerView.isHidden = true
            setupPlayer(url: file.url, type: .audio)

        case .video:
            imageHostView.isHidden = true
            playerView.isHidden = false
            setupPlayer(url: file.url, type: .video)

        case .unknown:
            break
        }

        layoutViewer()
    }

    // MARK: - 全图解码与预取

    /// 后台解码全图并写入缓存。带 completion 的是前台加载（userInitiated），
    /// 不带的是相邻预取（utility）；预取撞上 in-flight 任务时直接放弃，避免重复解码。
    private func decodeFullImage(_ url: URL, completion: ((NSImage?) -> Void)? = nil) {
        let path = url.path
        decodeLock.lock()
        let dup = decodeInFlight.contains(path)
        if !dup { decodeInFlight.insert(path) }
        decodeLock.unlock()
        if dup && completion == nil { return }

        DispatchQueue.global(qos: completion == nil ? .utility : .userInitiated).async { [weak self] in
            let img = ThumbnailProvider.fullImage(url: url)
            guard let self = self else { return }
            if let img = img {
                let cost = Int(img.size.width * img.size.height * 4)   // 像素字节
                self.fullImageCache.setObject(img, forKey: path as NSString, cost: cost)
            }
            self.decodeLock.lock(); self.decodeInFlight.remove(path); self.decodeLock.unlock()
            if let completion = completion { DispatchQueue.main.async { completion(img) } }
        }
    }

    /// 预取当前位置左右各一张图片（视频/音频不预取——它们的加载本来就是流式的）
    private func prefetchNeighbors(around index: Int) {
        for j in [index - 1, index + 1] where j >= 0 && j < mediaFiles.count {
            let f = mediaFiles[j]
            guard f.type == .image,
                  fullImageCache.object(forKey: f.url.path as NSString) == nil else { continue }
            decodeFullImage(f.url)
        }
    }

    // MARK: - 播放器

    private func setupPlayer(url: URL, type: MediaType) {
        // 用 AssetFactory 建带 MIME 提示的 asset，保证无扩展名/伪装视频也能播
        let asset = AssetFactory.make(url: url, type: type)
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        p.volume = 1.0
        player = p
        playerView.player = (type == .video) ? p : nil

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateTimeUI(time)
        }

        volumeSlider.doubleValue = 100
        volumeLabel.stringValue = "🔊 100%"
        seekSlider.doubleValue = 0
        timeLabel.stringValue = "00:00 / 00:00"

        p.play()
        isPlaying = true
        playPauseButton.title = "暂停"
    }

    private func teardownPlayer() {
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        player?.pause()
        playerView.player = nil
        player = nil
        isPlaying = false
    }

    private func updateTimeUI(_ time: CMTime) {
        guard let player = player, let item = player.currentItem else { return }
        let dur = item.duration
        guard dur.isNumeric, dur.seconds.isFinite, dur.seconds > 0 else { return }
        let total = dur.seconds
        let cur = time.seconds

        seekSlider.maxValue = total
        if !isSeeking { seekSlider.doubleValue = cur }
        timeLabel.stringValue = "\(fmt(cur)) / \(fmt(total))"

        // 播放到尾：暂停并归零（等价原作 curMs >= totalMs-200 的处理）
        if cur >= total - 0.2, isPlaying {
            player.pause()
            isPlaying = false
            playPauseButton.title = "播放"
            player.seek(to: .zero)
            seekSlider.doubleValue = 0
            timeLabel.stringValue = "00:00 / \(fmt(total))"
        }
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.rounded(.towardZero))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: - 控件动作

    @objc private func togglePlayPauseAction() {
        togglePlayPause()
        window?.makeFirstResponder(window?.contentView)
    }

    private func togglePlayPause() {
        guard let player = player, currentType != .image else { return }
        if isPlaying { player.pause(); playPauseButton.title = "播放" }
        else { player.play(); playPauseButton.title = "暂停" }
        isPlaying.toggle()
    }

    @objc private func seekChanged() {
        guard let player = player else { return }
        let t = CMTime(seconds: seekSlider.doubleValue, preferredTimescale: 600)
        if isSeeking {
            player.seek(to: t)   // 拖拽中：默认容差（就近关键帧），高码率视频不卡
        } else {
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)   // 单击定位：精确
        }
    }

    private func seekPrecise() {
        guard let player = player else { return }
        player.seek(to: CMTime(seconds: seekSlider.doubleValue, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func volumeChanged() {
        let v = volumeSlider.doubleValue
        player?.volume = Float(v / 100.0)
        volumeLabel.stringValue = "🔊 \(Int(v))%"
    }

    @objc private func toggleInfo() {
        infoVisible.toggle()
        toggleInfoButton.title = infoVisible ? "隐藏信息栏" : "显示信息栏"
        layoutViewer()
        if infoVisible { triggerGpsFetch() }
        window?.makeFirstResponder(window?.contentView)
    }

    @objc private func openMap() {
        guard hasGPS else { return }
        let urlStr = "https://www.google.com/maps/search/?api=1&query=\(curLat),\(curLon)"
        if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
    }

    // MARK: - GPS 懒加载 + 防抖 + 缓存（等价 TriggerGpsFetch / 定时器2）

    private func triggerGpsFetch() {
        guard infoVisible else { return }
        guard hasGPS else { gpsLabel.stringValue = "GPS: 无位置数据"; return }
        if gpsFetched { return }

        let key = Geocoder.cacheKey(lat: curLat, lon: curLon)
        if let cached = Geocoder.shared.cached(forKey: key) {
            gpsLabel.stringValue = "GPS: \(curLat), \(curLon)\n\(cached)\n\n[双击在地图中打开]"
            gpsFetched = true
        } else {
            gpsLabel.stringValue = "GPS: \(curLat), \(curLon)\n📍 正在获取地址数据..."
            scheduleDebounce()   // 800ms 防抖，快切绝不发请求
        }
    }

    private func scheduleDebounce() {
        cancelDebounce()
        let work = DispatchWorkItem { [weak self] in self?.fireGpsFetch() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func cancelDebounce() {
        debounceWork?.cancel()
        debounceWork = nil
    }

    private func fireGpsFetch() {
        guard hasGPS, infoVisible, !gpsFetched else { return }
        gpsFetched = true
        let session = gpsSession.increment()
        let lat = curLat, lon = curLon
        Geocoder.shared.fetch(lat: lat, lon: lon) { [weak self] finalDisplay in
            DispatchQueue.main.async {
                guard let self = self, self.gpsSession.current == session else { return }
                if let finalDisplay = finalDisplay {
                    self.gpsLabel.stringValue = "GPS: \(lat), \(lon)\n\(finalDisplay)\n\n[双击在地图中打开]"
                } else {
                    // 失败未入缓存；放开 gpsFetched，重新打开信息栏 / 回看这张即可重试
                    self.gpsFetched = false
                    self.gpsLabel.stringValue = "GPS: \(lat), \(lon)\n📍 地址获取失败（网络原因），重新打开信息栏可重试\n\n[双击在地图中打开]"
                }
            }
        }
    }

    // MARK: - 键盘（等价原作主消息循环里的键盘 hack）
    //  空格 = 全局播放/暂停；←/→ = 切换媒体（除非焦点在进度/音量条上，交给滑块调值）；ESC = 关闭

    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isKeyWindow == true else { return event }
            switch event.keyCode {
            case 53: // ESC
                self.window?.performClose(nil); return nil
            case 49: // 空格
                self.togglePlayPause(); return nil
            case 123: // ←
                let fr = self.window?.firstResponder
                if fr === self.seekSlider || fr === self.volumeSlider { return event }
                self.loadMedia(index: self.currentIndex - 1); return nil
            case 124: // →
                let fr = self.window?.firstResponder
                if fr === self.seekSlider || fr === self.volumeSlider { return event }
                self.loadMedia(index: self.currentIndex + 1); return nil
            default:
                return event
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        teardownPlayer()
        cancelDebounce()
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        // 让所有在途后台任务失效
        imageLoadSession.increment()
        metaSession.increment()
        gpsSession.increment()
        imageHostView.image = nil
    }
}
