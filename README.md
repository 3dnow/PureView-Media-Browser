PureView Media Browser (本源媒体浏览器)

In an era dominated by bloated Electron apps and heavy multi-platform frameworks, PureView goes back to the roots. It is a hardcore, ultra-lightweight Windows media browser built entirely with pure Win32 API, GDI+, and Windows Media Foundation. Absolutely zero third-party libraries (No Qt, No MFC, No FFmpeg).

The core philosophy of this project is "Content over Extensions". Whether your media files have missing extensions, incorrect extensions (like .bak, .1, .dat), or are completely obfuscated, PureView will instantly identify their true format, decode them, and render them flawlessly.

✨ Key Technical Highlights

🚫 Forensic-Level Format Sniffing
Instead of relying on Windows Explorer's fragile extension system, PureView reads the binary "Magic Numbers" of the file header. It seamlessly and accurately detects JPEG, PNG, HEIC, MP4, MOV, and M4A, processing them automatically regardless of their filenames.

⚡ Zero-Flicker Double Buffering Engine
Achieving smooth image transitions in native Win32 is notoriously difficult. PureView implements a highly optimized, handcrafted GDI+ double-buffering architecture in memory. Switching between massive high-res images is silky smooth with zero screen-tearing, white flashes, or black frames—rivaling or exceeding the native Windows Photos app.

📍 Deep GPS & EXIF Extraction

Images: Interrogates WIC metadata nodes to extract EXIF timestamps and correctly rotate images based on orientation flags.

Videos (The Magic): Finding GPS data in a video without an extension is incredibly hard. PureView includes a custom high-frequency binary scanner that hunts down Apple QuickTime ISO-6709 coordinate atoms (e.g., +39.9042-079.0783/) directly from the raw video stream.

🌍 Intelligent & Bulletproof Geocoding
Integrates OpenStreetMap (Nominatim) to convert GPS coordinates into clean, human-readable addresses, backed by an enterprise-grade anti-DDoS architecture:

Lazy Loading: Network requests are only fired when the info panel is explicitly opened.

Debounce Timer: Safely allows you to rapidly scroll through hundreds of images by delaying network requests until you pause for 800ms.

Grid Caching: Caches ~100m radius coordinate grids in memory. Neighboring photos load their addresses instantly with zero network latency.

Deep Text Cleaning: Automatically reverses western address formats to fit local norms, strips out postal codes, and purges unwanted traditional Chinese characters.

🎬 Native Hardware Decoding
Harnesses the power of IMFSourceReader and MFPlay. By tapping directly into the system's native GPU acceleration pipeline, it effortlessly plays 4K MP4/MOV videos and decodes HEIC photos (requires Windows HEVC extension) without breaking a sweat.

🎛️ Custom Native UI & Asynchronous Engine

Features a beautifully handcrafted, minimalist media player UI (Seek bar, Volume control, Dynamic Timers) built natively.

Driven by a robust multi-threaded engine (std::thread with strict MTA COM initialization) ensuring the main UI never freezes, even when scanning directories with thousands of corrupted files.

🚀 Getting Started

Prerequisites:

Windows 10/11

Visual Studio (2019/2022/2025)

(Optional) "HEVC Video Extensions" installed from the Microsoft Store for .heic viewing.

Build Instructions (Extremely Simple):

Create a new "Windows Desktop Application" (C++) project in Visual Studio.

Replace the default main.cpp with the main.cpp from this repository.

Build and Run! All dependencies (gdiplus.lib, mfplay.lib, wininet.lib, etc.) are dynamically linked via #pragma comment. Zero configuration required.

⌨️ Hotkeys

Left Arrow / Right Arrow: Seamlessly switch between media in the same folder.

Space: Play/Pause the current video or audio track.

ESC: Close the media viewer and return to the thumbnail grid.

<h2 id="中文">中文 (Chinese)</h2>

在 Electron 和各类庞大跨平台框架泛滥的今天，PureView (本源媒体浏览器) 选择回归极致的纯粹。这是一款基于 纯 Win32 API、GDI+ 以及 Media Foundation 打造的硬核、超轻量级 Windows 媒体浏览器。没有 Qt，没有 MFC，无需携带臃肿的 FFmpeg，真正的零第三方依赖。

本项目的核心理念是 “直击本源，无视后缀”。无论你的媒体文件是没有扩展名、还是被错误命名（例如 .bak、.1、.dat），该工具都能瞬间洞悉其真实面貌，并完美解码渲染。

✨ 像素级打磨的核心亮点

🚫 法医级的格式嗅探
彻底抛弃 Windows 资源管理器对文件扩展名的脆弱依赖。底层通过读取二进制文件头的魔数 (Magic Number)，精准嗅探并分类 JPEG, PNG, HEIC, MP4, MOV, 和 M4A。即便文件被完全伪装，也能自动分发给正确的解码流水线。

⚡ 纯手工双缓冲，真正的零闪烁
在原生 Win32 控件中实现完美的图片切换极具挑战。PureView 在底层纯手工实现了高度优化的 GDI+ 内存双缓冲 (Double Buffering) 架构。在切换数兆的高清大图时，老画面会稳稳停留在屏幕上，直到后台异步解码完成瞬间进行内存级替换。无白屏、无黑场、无撕裂，切换体验如丝般顺滑，完美比肩甚至超越系统自带的“照片”应用。

📍 深海捞针：视频与图像的极客级 GPS 解析

图像: 直接探入 WIC 底层元数据节点，精准提取 EXIF 拍摄时间，并智能读取方向标识 (Orientation) 自动将手机横竖屏照片翻转回正。

视频 (黑科技): 在没有扩展名的视频文件中提取 GPS 堪称业界难题。本作内置了自研的高频二进制流扫描器，直接在茫茫的二进制数据中光速定位 Apple QuickTime ISO-6709 规范的经纬度原子报文（如 +39.9042-079.0783/），暴力破解视频地理位置。

🌍 企业级防封与智能地址提纯
集成 OpenStreetMap 将冰冷的经纬度转换为详细街道地址，并为此专门打造了一套防 DDoS 封禁的缓存架构：

按需懒加载: 仅在信息面板展开时才建立网络连接，绝不浪费请求。

毫秒级防抖 (Debounce): 允许你按住方向键一秒钟狂切几十张图，程序会冷静等待画面停留 800ms 后才安全发起请求，彻底告别 IP 封禁。

区块网格缓存: 内存级缓存周围约 100 米半径的坐标结果。当你浏览同一地点拍摄的一组照片时，地址瞬间“秒出”，彻底摆脱网络延迟。

深度正则清洗: 自动将西式倒装地址翻转为符合中国习惯的顺序，智能剔除海外邮政编码，并强力切断冗余的繁体字后缀。

🎬 原生级硬件加速流水线
深度调用 Windows 底层的 IMFSourceReader 和 MFPlay，直接唤醒显卡的原生硬件解码能力。不仅完美流畅播放 4K 视频，还能通过系统的 HEVC 扩展实现 HEIC 格式照片的极速加载，并自动矫正视频的旋转元数据。

🎛️ 无边框原生 UI 与强健的异步引擎

摒弃了丑陋的系统默认播放条，完全使用 Win32 原生 TRACKBAR_CLASS 手搓了包含毫秒级进度拖拽、音量调节、高精度时钟的极简播放控制器。

底层采用 std::thread 配合严格的 MTA COM 并发模型，即便是面对包含上万个损坏文件的文件夹，主 UI 也绝对不会卡死崩溃，且会自动生成纯色隔离的安全缩略图。

🚀 编译与运行

环境要求:

Windows 10/11 操作系统

Visual Studio (2019/2022/2025 均可)

(可选) 系统已从应用商店安装“HEVC 视频扩展”以支持 HEIC 照片原图显示。

极简编译 (Clone and Play):

在 Visual Studio 中创建一个空的“Windows 桌面应用程序” (C++) 项目。

将本仓库的 main.cpp 覆盖项目中的默认源文件。

直接点击编译运行！所有的系统库（如 gdiplus.lib, mfplay.lib, wininet.lib）已全部通过 #pragma comment 指令自动寻找并链接，全程免配置。

⌨️ 快捷键操作

左方向键 / 右方向键: 在当前目录下的媒体文件中进行无缝切换。即使焦点在音量条上，底层的键盘树追踪器也会确保快捷键永不失灵。

空格键 (Space): 全局暂停/播放当前的视频或音频文件。

ESC: 关闭当前全屏/窗口播放器，返回缩略图网格。

Built with ❤️ for Windows native development.
