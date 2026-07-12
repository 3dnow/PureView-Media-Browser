# PureView Media Browser · macOS 移植版

把原 Windows 版（纯 Win32 + GDI+ + Media Foundation 的单文件 C++ 应用）1:1 移植为 **macOS 原生应用**，
技术栈 **Swift + AppKit + AVFoundation + ImageIO**，同样坚持「零第三方依赖」——只用苹果自带框架，没有 Qt / 没有 FFmpeg。

原作理念「直击本源，无视后缀」完整保留：靠二进制魔数识别文件真实格式，即便文件没有扩展名或被伪装成 `.bak/.dat/.1` 也能正确解码。

---

## 功能对照（与原 Windows 版逐条对齐）

| 功能 | Windows 原作 | macOS 移植版 | 状态 |
|---|---|---|---|
| 魔数嗅探（JPEG/PNG/HEIC/MP4/MOV/M4A） | 读前 16 字节判文件头 | 同左 | ✅ 一致 |
| 缩略图网格 + 异步扫描 | ListView + 后台线程 | NSCollectionView + GCD | ✅ 一致 |
| 会话号取消过期任务 | `std::atomic<int>` | `AtomicInt`（NSLock） | ✅ 一致 |
| 图片解码 + EXIF 方向翻正 | WIC | ImageIO（`kCGImageSourceCreateThumbnailWithTransform`） | ✅ 一致 |
| 视频缩略图（抽第 1 秒帧） | IMFSourceReader | AVAssetImageGenerator | ✅ 一致 |
| 硬件解码播放 4K 视频 | MFPlay / IMFPMediaPlayer | AVPlayer | ✅ 一致 |
| 手搓播放控制器（进度/音量/时钟） | TRACKBAR_CLASS | 自定义 NSSlider + NSButton | ✅ 一致 |
| 双缓冲无闪切图（旧图留屏到新图就绪） | 手写 GDI+ 双缓冲 | AppKit 视图天然双缓冲 + 会话号原子换图 | ✅ 一致 |
| 图片 EXIF 拍摄时间 + GPS | WIC 元数据节点 | ImageIO GPS 字典（已解析为十进制度） | ✅ 一致 |
| 视频 GPS：ISO-6709 字节暴力扫描 | 头 2MB + 尾 2MB 扫描 | 同左（有界安全实现） | ✅ 一致，且修掉越界 |
| Nominatim 反查 + 中文地址清洗 | WinINet + 手工字符串截取 | URLSession + JSONSerialization | ✅ 一致 |
| 懒加载 + 800ms 防抖 + ~100m 网格缓存 | SetTimer + unordered_map | DispatchWorkItem + 带锁字典 | ✅ 一致 |
| 双击 GPS 在地图中打开 | Google Maps | Google Maps（NSWorkspace 打开） | ✅ 一致 |
| 快捷键 ←/→ 切换、空格 播放/暂停、ESC 关闭 | 主消息循环键盘 hack | 本地事件监视器（滑块聚焦时 ←/→ 交给滑块） | ✅ 一致 |
| HEIC 显示 | 需装商店 HEVC 扩展 | **系统原生支持，无需任何扩展** | ⬆️ 更好 |

## 顺手修掉的隐患（相对原作）

1. **视频 GPS 扫描越界读崩溃（严重）**：原作 `for (i=0; i<len-20; ...)` 在 `len<20`（截断/迷你视频）时无符号回绕成天文数字 → 越界读崩溃；且 `std::string s(buf+i, 60)` 会越过缓冲区尾。移植版用有界切片，`Verify/LogicTests.swift` 里 14 字节 / 0 字节文件的回归用例证明不再崩溃。
2. **退出竞态**：原作 detach 线程可能在 GDI+ 关闭后仍在跑。移植版用会话号 + `[weak self]` + ARC，窗口关闭时使所有在途后台任务失效。
3. **视频 GPS 扫描阻塞 UI**：原作在 UI 线程做 4MB 扫描。移植版挪到后台队列，主 UI 更不易卡。
4. **地址清洗的 CJK 数字陷阱（移植中发现并修复）**：Swift `Character.isNumber` 对「京/万/千/亿」等返回 `true`（它们有 Unicode 数字属性），照搬会把「北京市/南京」当短邮编误删。已限定为 ASCII 数字，与原作 `isdigit` 语义对齐。

## macOS 专属问题修复（v1.1）

移植后实测发现两个 macOS 专属问题，已定位根因并修复：

**1. 无扩展名/伪装视频无法预览、播放（严重）**
根因：AVFoundation 的 `AVURLAsset` 靠 URL 扩展名/UTI 推断容器格式来选 demuxer——文件没扩展名或被伪装成 `.bak/.dat` 时会解析出 **0 条轨道**，缩略图和播放全废。这恰好撞上原作「无视后缀」的卖点（图片没事是因为 ImageIO 靠内容嗅探）。
修复：新增 `AssetFactory`，用魔数已识别的类型给 AVFoundation 喂 `AVURLAssetOutOfBandMIMETypeKey` 的 MIME 提示，绕过扩展名判断。实测同一视频去掉扩展名后，video 轨从 0 → 1，缩略图从 nil → 正常。视频抽帧另加了「第 1 秒无帧则退回第 0 秒」的兜底。

**2. 视频 GPS 读不到**
排查结论：图片 GPS 一直正常；视频 GPS 的字节扫描器逻辑也正常（对真实 iPhone/相机的 `©xyz` ISO-6709 明文原子有效）。加固两点：① 尾扫门槛从 >4MB 放宽到 >2MB（覆盖 moov 在尾部的中短视频）；② 增加 AVFoundation `commonKeyLocation` 兜底。
> 说明：ffmpeg 默认写入 mp4 的 `loci`（二进制定点数）格式不支持——该格式连 AVFoundation 都不暴露为 location，原作亦不支持，真实拍摄设备罕见。真实手机/相机视频用的 `©xyz` ISO-6709 明文可正常读取。

## 目录导航（macOS 增强，原作没有）

- 扫描目录时，**子目录也会以文件夹图标显示在网格里**（排在媒体文件之前，按名字自然排序）。
- **双击子目录** → 重新扫描进入该子目录（媒体项仍是双击打开查看器，与 Finder 图标视图一致）。
- 进入子目录后，顶栏出现 **「← 上级目录」按钮**，点击返回进入前的那一级；回到最初选定的目录后按钮自动隐藏。
- 导航用一个栈实现，「上级」严格是「进入当前目录前所在的目录」，不会越过你最初选定的根目录。窗口标题实时显示当前目录名。
- 查看器里的 ←/→ 只在当前目录的媒体之间切换（不含子目录）。
- **本次运行的全局缩略图缓存**（`ThumbnailCache`，按文件路径）：进子目录再返回、来回切换时，已生成过的缩略图**直接命中、立即全部显示**，不再重复解码/抽帧。缓存跨目录共享、进程内有效，用 NSCache 实现（内存压力下自动驱逐，被驱逐也只是下次重建，不影响正确性）。

## 性能与体验优化（v1.2）

一轮系统性评审后落地（细节与基准数据见 [docs/OPTIMIZATION-REVIEW.md](docs/OPTIMIZATION-REVIEW.md)）：

- **缩略图并行生成**：有界并发替代串行，实测 **7.4×**；损坏文件负缓存，不再反复重试解码
- **查看器大图按屏幕上限封顶解码**：屏幕显示零画质损失，内存 **3.8×**（8000×6000 从 183MB → 48MB）
- **全图缓存 + 相邻预取**：←/→ 来回切图零解码、秒开
- **修复**：地理编码失败不再污染缓存且可重试；拖进度条改容差寻址不再卡顿；隐藏目录不再显示；
  网格选中态可视化；占位图标浅色外观可见；verify.sh 兼容 Intel
- **格式扩展**：魔数嗅探新增 GIF / TIFF / WebP / BMP / AVIF（ImageIO 原生解码）
- **键盘导航**：回车打开选中项、Cmd+↑ 返回上级（Finder 习惯）

## 构建与运行

### 方式一：Xcode（推荐）
```bash
open PureViewMedia.xcodeproj   # 需要完整版 Xcode
# 然后按 Cmd+R
```
> 工程由 `xcodegen` 依据 `project.yml` 生成；改了配置后重跑 `xcodegen generate` 即可再生。

### 方式二：免 Xcode（只装了 Command Line Tools）
```bash
./build-app.sh          # swiftc 直接产出 build/PureViewMedia.app
open build/PureViewMedia.app
```

### 逻辑回归测试（无需 Xcode / 无需图形界面）
```bash
./Verify/verify.sh      # 40 项断言：魔数识别 / GPS 扫描 / 越界修复 / 地址清洗 / 目录扫描 / 缓存
```

## 环境要求
- macOS 12.0+（部署目标；开发机 SDK 用 macOS 26.4 验证通过）
- Swift 5 语言模式（用 Swift 6.3 工具链编译通过，零错误零警告）
- 非沙盒应用：可读取用户选择的任意目录、访问网络（Nominatim 反查）

## 目录结构
```
macos/
├── project.yml                    # xcodegen 工程定义
├── PureViewMedia.xcodeproj/       # 生成的 Xcode 工程
├── build-app.sh                   # 免 Xcode 构建 .app（会把图标打包进去）
├── Resources/
│   └── AppIcon.icns               # 应用图标（渐变 squircle + 照片卡 + 播放徽标）
├── Sources/
│   ├── main.swift                 # 入口（等价 wWinMain）
│   ├── AppDelegate.swift          # 应用生命周期 + 菜单
│   ├── Atomic.swift               # 线程安全会话计数器
│   ├── MediaFile.swift            # 魔数识别（等价 IdentifyFile）
│   ├── DirectoryScanner.swift     # 目录扫描：分出子目录 + 媒体（可测/可取消）
│   ├── MetadataReader.swift       # EXIF/GPS 读取 + 视频 ISO-6709 扫描 + AVFoundation 兜底
│   ├── AssetFactory.swift         # 带 MIME 提示建 AVURLAsset（无扩展名视频的关键修复）
│   ├── Geocoder.swift             # Nominatim 反查 + 缓存 + 地址清洗
│   ├── ThumbnailProvider.swift    # 图片/视频缩略图与全图解码
│   ├── ThumbnailCache.swift       # 本次运行的全局缩略图缓存（跨目录复用）
│   ├── BrowserWindowController.swift  # 主窗口：网格 + 异步扫描
│   └── ViewerWindowController.swift   # 查看器：播放/信息/GPS/快捷键
└── Verify/
    ├── LogicTests.swift           # 无头逻辑测试
    └── verify.sh                  # 一键编译并运行测试
```

## 已知平台差异（无损）
- 播放器视频面用 `AVPlayerView(controlsStyle: .none)` 提供画面，控制条为手搓，与原作一致。
- 「双击地图」沿用原作的 Google Maps 网页 URL（若想改 Apple Maps，把 `ViewerWindowController.openMap` 里的 URL 换成 `https://maps.apple.com/?ll=<lat>,<lon>` 即可）。
- 音频文件与原作一样：不显示视频画面，展示「🎧 音频文件」占位与文件信息，照常播放。
