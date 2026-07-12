import Foundation

enum MediaType {
    case unknown, image, video, audio
}

struct MediaFile {
    let url: URL
    let name: String
    let type: MediaType
}

/// 法医级魔数嗅探：只读前 16 字节，靠二进制文件头判定真实格式，完全无视扩展名。
/// 等价于原作的 IdentifyFile()。
enum MediaIdentifier {
    static func identify(_ url: URL) -> MediaType {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 16), data.count >= 3 else { return .unknown }
        let b = [UInt8](data)

        // JPEG: FF D8 FF
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .image }
        // PNG: 89 50 4E 47
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .image }
        // GIF: "GIF8"（87a/89a）
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return .image }
        // TIFF: "II*\0"（小端）或 "MM\0*"（大端）
        if b.count >= 4, (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) ||
                         (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) { return .image }
        // WebP: "RIFF" + 偏移 8 处 "WEBP"
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
                          b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return .image }
        // BMP: "BM"——两字节魔数太弱，加验偏移 6..9 的保留字段必须为 0，压低误报
        if b.count >= 12, b[0] == 0x42, b[1] == 0x4D,
                          b[6] == 0, b[7] == 0, b[8] == 0, b[9] == 0 { return .image }
        // ISO-BMFF：偏移 4 处为 "ftyp"
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            switch brand {
            case "heic", "heix", "hevc", "heif",
                 "mif1", "msf1":                 return .image  // HEIC/HEIF
            case "avif", "avis":                 return .image  // AVIF（ImageIO macOS 13+ 原生解码）
            case "M4A ", "M4B ":                 return .audio  // 音频
            default:                             return .video  // MP4 / MOV 等
            }
        }
        return .unknown
    }
}
