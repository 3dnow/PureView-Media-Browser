import AVFoundation

/// 用魔数已识别的类型给 AVFoundation 喂一个 MIME 提示，绕过它对扩展名/UTI 的依赖。
///
/// 根因：AVURLAsset 靠 URL 扩展名/UTI 推断容器格式来选 demuxer。原作的卖点是「无视后缀」，
/// 文件没扩展名或被伪装成 .bak/.dat 时，默认 AVURLAsset 会解析出 0 条轨道 → 既不能抽缩略图也不能播放。
/// 传入 AVURLAssetOutOfBandMIMETypeKey 后，AVFoundation 改用给定 MIME 选 demuxer，即可正常解码。
/// (ISO-BMFF 的 MOV/MP4 共用同一 demuxer，故视频统一用 video/quicktime 即可通吃两者。)
enum AssetFactory {
    static func mimeType(for type: MediaType) -> String {
        switch type {
        case .audio: return "audio/mp4"
        default:     return "video/quicktime"
        }
    }

    static func make(url: URL, type: MediaType) -> AVURLAsset {
        // 该 option key 未桥接为 Swift 符号，用其字符串字面量（已实测有效）。
        AVURLAsset(url: url, options: ["AVURLAssetOutOfBandMIMETypeKey": mimeType(for: type)])
    }
}
