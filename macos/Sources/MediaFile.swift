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
        // ISO-BMFF：偏移 4 处为 "ftyp"
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            switch brand {
            case "heic", "heix", "mif1", "msf1": return .image  // HEIC/HEIF
            case "M4A ", "M4B ":                 return .audio  // 音频
            default:                             return .video  // MP4 / MOV 等
            }
        }
        return .unknown
    }
}
