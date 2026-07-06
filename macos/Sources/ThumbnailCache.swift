import AppKit

/// 本次运行的全局缩略图缓存（按文件路径）。跨目录、跨导航共享：
/// 进子目录再返回、来回切换时，已生成过的缩略图直接命中，无需重复解码/抽帧。
///
/// 用 NSCache：本身线程安全（缩略图在后台线程生成、主线程读取），且在内存压力下会自动驱逐
/// （缩略图可随时重建，被驱逐也只是下次重新生成，不影响正确性）。
/// Key 用文件路径 —— 本次会话内浏览的文件极少被外部替换；若真被替换，重启即刷新。
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 4000   // 常规浏览足够，超出按 NSCache 策略驱逐
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func set(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url.path as NSString)
    }
}
