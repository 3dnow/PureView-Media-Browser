import AppKit

/// 网格里的一格，可能是「子目录」或「媒体文件」。
enum GridItem {
    case directory(url: URL, name: String)
    case media(MediaFile)
}

/// 缩略图网格里的单个格子：120pt 缩略图/文件夹图标 + 名称。
final class MediaCollectionItem: NSCollectionViewItem {
    private let thumb = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 130, height: 160))
        v.wantsLayer = true

        thumb.frame = NSRect(x: 5, y: 35, width: 120, height: 120)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true

        nameLabel.frame = NSRect(x: 0, y: 4, width: 130, height: 28)
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.textColor = .white
        nameLabel.isEditable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false

        v.addSubview(thumb)
        v.addSubview(nameLabel)
        self.view = v
    }

    func configure(image: NSImage?, name: String, type: MediaType) {
        if let image = image {
            thumb.image = image
        } else {
            let sym: String
            switch type {
            case .audio: sym = "music.note"
            case .video: sym = "film"
            default:     sym = "photo"
            }
            thumb.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        }
        nameLabel.stringValue = name
    }

    func configureFolder(name: String) {
        thumb.image = NSImage(named: NSImage.folderName)   // 系统标准彩色文件夹图标
        nameLabel.stringValue = name
    }
}

/// 主窗口：选择目录、异步扫描、缩略图网格、子目录导航。
/// 等价于原作 MainProc + AsyncScanDirectory，并新增子目录进入/返回上级。
final class BrowserWindowController: NSWindowController, NSCollectionViewDataSource {
    private let scanSession = AtomicInt()
    private var entries: [GridItem] = []
    private var thumbnails: [NSImage?] = []          // 与 entries 平行；目录项对应位置为 nil

    private var currentFolder: URL?
    private var navStack: [URL] = []                 // 进入子目录时压栈，返回时出栈

    private var collectionView: NSCollectionView!
    private var progressLabel: NSTextField!
    private var backButton: NSButton!
    private var viewer: ViewerWindowController?

    private let itemId = NSUserInterfaceItemIdentifier("MediaItem")

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "PureView 媒体浏览器 (macOS · 防抖缓存版)"
        win.center()
        win.setFrameAutosaveName("PureViewMainWindow")
        self.init(window: win)
        buildUI()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let topBar = NSView(frame: NSRect(x: 0, y: content.bounds.height - 42, width: content.bounds.width, height: 42))
        topBar.autoresizingMask = [.width, .minYMargin]

        let btn = NSButton(title: "选择目录...", target: self, action: #selector(chooseDirectory))
        btn.frame = NSRect(x: 12, y: 6, width: 120, height: 28)
        btn.bezelStyle = .rounded
        btn.refusesFirstResponder = true
        topBar.addSubview(btn)

        backButton = NSButton(title: "← 上级目录", target: self, action: #selector(goBack))
        backButton.frame = NSRect(x: 140, y: 6, width: 110, height: 28)
        backButton.bezelStyle = .rounded
        backButton.refusesFirstResponder = true
        backButton.isHidden = true
        topBar.addSubview(backButton)

        progressLabel = NSTextField(labelWithString: "准备就绪")
        progressLabel.frame = NSRect(x: 262, y: 10, width: content.bounds.width - 274, height: 22)
        progressLabel.autoresizingMask = [.width]
        progressLabel.lineBreakMode = .byTruncatingMiddle
        topBar.addSubview(progressLabel)
        content.addSubview(topBar)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - 42))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 130, height: 160)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [NSColor(calibratedWhite: 0.14, alpha: 1)]
        collectionView.register(MediaCollectionItem.self, forItemWithIdentifier: itemId)

        scroll.documentView = collectionView
        content.addSubview(scroll)

        let dbl = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(dbl)
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: itemId, for: indexPath) as! MediaCollectionItem
        let idx = indexPath.item
        guard idx < entries.count else { item.configure(image: nil, name: "", type: .unknown); return item }
        switch entries[idx] {
        case .directory(_, let name):
            item.configureFolder(name: name)
        case .media(let mf):
            let img = idx < thumbnails.count ? thumbnails[idx] : nil
            item.configure(image: img, name: mf.name, type: mf.type)
        }
        return item
    }

    // MARK: - 交互

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "扫描此目录"
        panel.begin { [weak self] resp in
            if resp == .OK, let url = panel.url {
                self?.navStack.removeAll()          // 新选根目录，清空导航栈
                self?.startScan(folder: url)
            }
        }
    }

    @objc private func handleDoubleClick(_ g: NSClickGestureRecognizer) {
        let p = g.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: p), ip.item < entries.count else { return }
        switch entries[ip.item] {
        case .directory(let url, _):
            enterDirectory(url)
        case .media:
            openViewerForMedia(atEntryIndex: ip.item)
        }
    }

    private func enterDirectory(_ url: URL) {
        if let cur = currentFolder { navStack.append(cur) }
        startScan(folder: url)
    }

    @objc private func goBack() {
        guard let parent = navStack.popLast() else { return }
        startScan(folder: parent)
    }

    /// 双击媒体项：把当前目录的媒体（不含子目录）传给查看器，并定位到点击的那一个。
    private func openViewerForMedia(atEntryIndex idx: Int) {
        var medias: [MediaFile] = []
        var pos = 0
        for (i, e) in entries.enumerated() {
            if case .media(let m) = e {
                if i == idx { pos = medias.count }
                medias.append(m)
            }
        }
        guard !medias.isEmpty else { return }
        if viewer == nil { viewer = ViewerWindowController() }
        viewer?.present(mediaFiles: medias, index: pos)
    }

    private func updateChrome(for folder: URL) {
        backButton.isHidden = navStack.isEmpty
        window?.title = "PureView 媒体浏览器 — " + folder.lastPathComponent
    }

    // MARK: - 异步扫描（等价 AsyncScanDirectory + 子目录）

    private func startScan(folder: URL) {
        let session = scanSession.increment()
        currentFolder = folder
        updateChrome(for: folder)

        entries.removeAll()
        thumbnails.removeAll()
        collectionView.reloadData()
        progressLabel.stringValue = "正在扫描: \(folder.lastPathComponent) ..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 第一阶段：列目录，分出子目录 + 媒体（中途可取消）
            let result = DirectoryScanner.scan(folder, isCancelled: { self.scanSession.current != session })
            let dirCount = result.dirs.count

            let total = result.medias.count

            DispatchQueue.main.async {
                guard self.scanSession.current == session else { return }
                self.entries = result.dirs.map { GridItem.directory(url: $0.url, name: $0.name) }
                             + result.medias.map { GridItem.media($0) }
                // 预填缓存命中的缩略图 → 返回/重进目录时已生成过的立即全部显示，零延迟零闪烁
                var pre = [NSImage?](repeating: nil, count: self.entries.count)
                var hit = 0
                for (mi, mf) in result.medias.enumerated() {
                    if let img = ThumbnailCache.shared.image(for: mf.url) { pre[dirCount + mi] = img; hit += 1 }
                }
                self.thumbnails = pre
                self.collectionView.reloadData()
                let pending = total - hit
                if self.entries.isEmpty {
                    self.progressLabel.stringValue = "该目录为空 / 无可识别的媒体或子目录"
                } else if pending == 0 {
                    self.progressLabel.stringValue = "完成：\(dirCount) 个子目录，\(total) 个媒体文件（缓存命中）"
                } else {
                    self.progressLabel.stringValue = "子目录 \(dirCount) 个，媒体 \(total) 个（缓存命中 \(hit)，待生成 \(pending)）..."
                }
            }

            // 第二阶段：仅为「未缓存」的媒体项后台生成缩略图，生成后存入缓存并回填
            var generated = 0
            for (mi, mf) in result.medias.enumerated() {
                if self.scanSession.current != session { return }
                if ThumbnailCache.shared.image(for: mf.url) != nil { continue }   // 已命中，跳过生成
                let img = ThumbnailProvider.makeThumbnail(url: mf.url, type: mf.type)
                if let img = img { ThumbnailCache.shared.set(img, for: mf.url) }
                let entryIndex = dirCount + mi     // entries = 目录在前 + 媒体在后
                generated += 1
                let done = generated
                DispatchQueue.main.async {
                    guard self.scanSession.current == session else { return }
                    if entryIndex < self.thumbnails.count { self.thumbnails[entryIndex] = img }
                    self.collectionView.reloadItems(at: [IndexPath(item: entryIndex, section: 0)])
                    self.progressLabel.stringValue = "生成缩略图: \(done) 张（子目录 \(dirCount) 个，媒体 \(total) 个）"
                }
            }

            DispatchQueue.main.async {
                guard self.scanSession.current == session else { return }
                if total > 0 {
                    self.progressLabel.stringValue = "完成：\(dirCount) 个子目录，\(total) 个媒体文件"
                }
            }
        }
    }
}
