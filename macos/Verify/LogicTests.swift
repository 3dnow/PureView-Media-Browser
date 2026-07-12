import Foundation
import AppKit

// 无头逻辑回归测试：验证核心特性 + 修掉的隐患。可在纯命令行运行（无需图形界面）。
// 编译运行见同目录 verify.sh。与 App 目标（Sources/）分开编译，故用 @main 避免顶层表达式冲突。
@main
struct LogicTests {
    static var pass = 0
    static var fail = 0

    static func check(_ name: String, _ cond: Bool) {
        if cond { pass += 1; print("  ✅ \(name)") }
        else { fail += 1; print("  ❌ \(name)") }
    }

    static func writeTemp(_ bytes: [UInt8], _ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pvtest_" + name)
        try? Data(bytes).write(to: url)
        return url
    }

    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    static func main() {
        print("=== 1. 魔数识别（无视扩展名）===")
        let jpeg = writeTemp([0xFF,0xD8,0xFF,0xE0] + Array(repeating: 0, count: 12), "a.bak")
        let png  = writeTemp([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A] + Array(repeating: 0, count: 8), "b.dat")
        let heic = writeTemp([0,0,0,0x18] + ascii("ftypheic") + Array(repeating: 0, count: 8), "c.1")
        let m4a  = writeTemp([0,0,0,0x18] + ascii("ftypM4A ") + Array(repeating: 0, count: 8), "d.xxx")
        let mp4  = writeTemp([0,0,0,0x18] + ascii("ftypqt  ") + Array(repeating: 0, count: 8), "e")
        let txt  = writeTemp(ascii("hello world not media"), "f.jpg")
        check("JPEG(.bak) → image", MediaIdentifier.identify(jpeg) == .image)
        check("PNG(.dat) → image",  MediaIdentifier.identify(png)  == .image)
        check("HEIC(.1) → image",   MediaIdentifier.identify(heic) == .image)
        check("M4A(.xxx) → audio",  MediaIdentifier.identify(m4a)  == .audio)
        check("MP4(无扩展) → video", MediaIdentifier.identify(mp4)  == .video)
        check("伪装.jpg文本 → unknown", MediaIdentifier.identify(txt) == .unknown)

        print("=== 2. 视频 ISO-6709 GPS 暴力扫描 ===")
        let header = [UInt8](repeating: 0, count: 24)
        let tail   = [UInt8](repeating: 0x20, count: 30)
        let vgps = writeTemp(header + ascii("©xyz+39.9042-079.0783/") + tail, "g")
        if let c = VideoGPSScanner.scan(url: vgps) {
            check("提取纬度 ≈ 39.9042", abs(c.lat - 39.9042) < 0.0001)
            check("提取经度 ≈ -79.0783", abs(c.lon - (-79.0783)) < 0.0001)
        } else { check("提取纬度", false); check("提取经度", false) }
        let vgps2 = writeTemp(header + ascii("loci-33.8688+151.2093/") + tail, "h")
        if let c = VideoGPSScanner.scan(url: vgps2) {
            check("南纬 ≈ -33.8688", abs(c.lat - (-33.8688)) < 0.0001)
            check("东经 ≈ 151.2093", abs(c.lon - 151.2093) < 0.0001)
        } else { check("南纬/东经", false) }
        check("无坐标 → nil", VideoGPSScanner.scan(url: writeTemp(header + tail, "i")) == nil)
        // ISO-6709 字符串解析（AVFoundation 兜底路径复用它；含高度分量也要能切对）
        if let c = VideoGPSScanner.parseISO6709String("+37.7749-122.4194/") {
            check("parseISO6709String 基本", abs(c.lat - 37.7749) < 1e-4 && abs(c.lon - (-122.4194)) < 1e-4)
        } else { check("parseISO6709String 基本", false) }
        if let c = VideoGPSScanner.parseISO6709String("+39.9042-079.0783+010.5/") {
            check("parseISO6709String 带高度", abs(c.lat - 39.9042) < 1e-4 && abs(c.lon - (-79.0783)) < 1e-4)
        } else { check("parseISO6709String 带高度", false) }

        print("=== 3. 原作越界崩溃是否已修掉（关键回归）===")
        let tiny = writeTemp([0,0,0,0x18] + ascii("ftypqt  ") + [0,0], "j")  // 14 字节截断视频
        check("14字节截断视频 identify → video", MediaIdentifier.identify(tiny) == .video)
        check("对其扫描 GPS 不崩溃且返回 nil", VideoGPSScanner.scan(url: tiny) == nil)
        check("0字节文件扫描不崩溃", VideoGPSScanner.scan(url: writeTemp([], "k")) == nil)

        print("=== 4. 地址清洗 CleanLocation ===")
        check("截断 ' / ' 之后", CleanLocation.clean("北京市 / Beijing") == "北京市")
        check("截断 ';' 之后",   CleanLocation.clean("海淀区;something") == "海淀区")
        check("剔除短邮编",      CleanLocation.clean("100081") == "")
        check("保留正常地名",    CleanLocation.clean("  朝阳区  ") == "朝阳区")
        check("空串保持空",      CleanLocation.clean("") == "")
        // 回归：含 CJK 数字属性字符的地名不得被误删（京=10^16, Swift isNumber=true）
        check("保留『北京市』",  CleanLocation.clean("北京市") == "北京市")
        check("保留『南京』",    CleanLocation.clean("南京") == "南京")

        print("=== 5. 目录扫描：子目录与媒体分类 ===")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pvscan_\(UInt64(pass) &+ 7)")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("subA"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("subB"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent(".hiddenDir"), withIntermediateDirectories: true)
        try? Data([0xFF,0xD8,0xFF,0xE0] + Array(repeating: 0, count: 12)).write(to: root.appendingPathComponent("pic.bak"))
        try? Data([0,0,0,0x18] + ascii("ftypqt  ") + Array(repeating: 0, count: 8)).write(to: root.appendingPathComponent("clip"))
        try? Data(ascii("junk not media")).write(to: root.appendingPathComponent("readme.txt"))
        let r = DirectoryScanner.scan(root)
        check("识别出 2 个子目录", r.dirs.count == 2)
        check("子目录按名字排序", r.dirs.map { $0.name } == ["subA", "subB"])
        check("隐藏目录(.hiddenDir)不展示", !r.dirs.contains { $0.name == ".hiddenDir" })
        check("识别出 2 个媒体(图+视频)", r.medias.count == 2)
        check("非媒体 readme.txt 被排除", !r.medias.contains { $0.name == "readme.txt" })
        check("扫描可被取消(返回空)", DirectoryScanner.scan(root, isCancelled: { true }).medias.isEmpty)
        try? fm.removeItem(at: root)

        print("=== 6. 缩略图缓存（本次全局，跨目录复用）===")
        let cimg = NSImage(size: NSSize(width: 2, height: 2))
        let curl = URL(fileURLWithPath: "/tmp/pv_cache_probe.jpg")
        check("未命中返回 nil", ThumbnailCache.shared.image(for: curl) == nil)
        ThumbnailCache.shared.set(cimg, for: curl)
        check("命中返回同一对象", ThumbnailCache.shared.image(for: curl) === cimg)
        // 负缓存：生成失败过的文件（损坏媒体）跨目录导航不再反复重试
        let furl = URL(fileURLWithPath: "/tmp/pv_failed_probe.mov")
        check("初始未标记失败", ThumbnailCache.shared.isFailed(furl) == false)
        ThumbnailCache.shared.markFailed(furl)
        check("负缓存命中", ThumbnailCache.shared.isFailed(furl))

        print("=== 7. 扩展格式魔数（GIF/TIFF/BMP/WebP/AVIF）===")
        check("GIF89a → image", MediaIdentifier.identify(writeTemp(ascii("GIF89a") + Array(repeating: 0, count: 10), "x1")) == .image)
        check("TIFF(II,小端) → image", MediaIdentifier.identify(writeTemp([0x49,0x49,0x2A,0x00] + Array(repeating: 0, count: 12), "x2")) == .image)
        check("TIFF(MM,大端) → image", MediaIdentifier.identify(writeTemp([0x4D,0x4D,0x00,0x2A] + Array(repeating: 0, count: 12), "x3")) == .image)
        check("WebP → image", MediaIdentifier.identify(writeTemp(ascii("RIFF") + [0,0,0,0] + ascii("WEBP") + [0,0,0,0], "x4")) == .image)
        check("BMP(保留域=0) → image", MediaIdentifier.identify(writeTemp([0x42,0x4D, 1,2,3,4, 0,0,0,0, 54,0,0,0, 0,0], "x5")) == .image)
        check("伪BM文本(保留域≠0) → unknown", MediaIdentifier.identify(writeTemp(ascii("BMW is a car maker!!"), "x6")) == .unknown)
        check("AVIF → image", MediaIdentifier.identify(writeTemp([0,0,0,0x18] + ascii("ftypavif") + Array(repeating: 0, count: 8), "x7")) == .image)

        print("\n=== 结果: \(pass) 通过, \(fail) 失败 ===")
        exit(fail == 0 ? 0 : 1)
    }
}
