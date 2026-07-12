import AppKit
import ImageIO
import AVFoundation

/// 缩略图 / 全图解码。图片走 ImageIO（自动按 EXIF Orientation 翻正），视频走 AVAssetImageGenerator（自动按轨道 transform 旋转）。
/// 纯色留白缩略图用 CGContext 生成，可安全在后台线程运行（不用 NSImage.lockFocus，避免线程问题）。
enum ThumbnailProvider {

    /// 解出按 EXIF 方向翻正的 CGImage。maxPixel 为 nil 时返回全分辨率（供查看器显示大图）。
    static func orientedCGImage(url: URL, maxPixel: Int?) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true   // 关键：自动应用 Orientation
        ]
        if let mp = maxPixel { opts[kCGImageSourceThumbnailMaxPixelSize] = mp }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 视频抽帧：定位到第 1 秒（与原作 SetCurrentPosition 10000000 一致），已按旋转元数据翻正。
    /// 用 AssetFactory 建 asset，保证无扩展名/伪装文件也能被 AVFoundation 识别。
    static func videoThumbnail(url: URL, type: MediaType) -> CGImage? {
        let asset = AssetFactory.make(url: url, type: type)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        // 先试第 1 秒；极短视频 1 秒处可能越界无帧，退回到第 0 秒
        for sec in [1.0, 0.0] {
            let t = CMTime(seconds: sec, preferredTimescale: 600)
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) { return cg }
        }
        return nil
    }

    /// 生成深灰(30,30,30)背景、居中留白的方形缩略图。等价于原作 CreateSolidPaddedThumbnail。
    static func paddedThumbnail(cg: CGImage, size: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.interpolationQuality = .high

        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let s = CGFloat(size)
        let ratio = min(s / iw, s / ih)
        let w = max(1, iw * ratio), h = max(1, ih * ratio)
        ctx.draw(cg, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// 后台生成一个可直接用于 NSImageView 的 120pt 缩略图（240px 画布 → 视网膜清晰）。
    static func makeThumbnail(url: URL, type: MediaType) -> NSImage? {
        var cg: CGImage?
        switch type {
        case .image: cg = orientedCGImage(url: url, maxPixel: 240)
        case .video: cg = videoThumbnail(url: url, type: type)
        default:     cg = nil   // 音频无缩略图，UI 用占位符号
        }
        guard let raw = cg, let padded = paddedThumbnail(cg: raw, size: 240) else { return nil }
        return NSImage(cgImage: padded, size: NSSize(width: 120, height: 120))
    }

    /// 查看器全图解码上限：显示是 fit-to-window、没有缩放功能，按所有屏幕的最大像素维度封顶，
    /// 对屏幕显示零画质损失。收益是内存（8000×6000 位图 183MB → 48MB，实测 3.8×；亿像素更多）——
    /// 这让带成本上限的全图缓存真正装得下多张图，相邻预取才有意义。
    /// 注意实测封顶解码本身反而略慢（ImageIO 缩放解码有重采样开销），换内存是明确的取舍。
    /// MaxPixelSize 只缩不放：小于上限的图片保持原分辨率。首次访问需在主线程（内部读 NSScreen）。
    static let fullDecodeCap: Int = {
        let maxDim = NSScreen.screens
            .map { Int(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor) }
            .max() ?? 2880
        return max(2880, maxDim)
    }()

    /// 查看器全图：按屏幕上限封顶解码、已翻正。
    static func fullImage(url: URL) -> NSImage? {
        guard let cg = orientedCGImage(url: url, maxPixel: fullDecodeCap) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
