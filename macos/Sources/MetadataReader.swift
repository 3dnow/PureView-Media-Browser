import Foundation
import ImageIO
import AVFoundation

struct MediaMetadata {
    var infoText: String     // 信息面板顶部多行文本
    var hasGPS: Bool
    var lat: Double
    var lon: Double
}

/// 元数据提取：图片走 ImageIO 读 EXIF 拍摄时间 + GPS；视频/音频读文件时间 + ISO-6709 暴力扫描。
/// 等价于原作的 ReadMetadataDirect()。ImageIO 已把 GPS 解析成十进制度，比原作手工解有理数干净。
enum MetadataReader {
    static func read(url: URL, type: MediaType) -> MediaMetadata {
        var info = "文件名:\n" + url.lastPathComponent + "\n\n"
        var hasGPS = false
        var lat = 0.0, lon = 0.0

        if type == .image {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {

                // EXIF 拍摄时间
                if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                   let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    info += "拍摄时间:\n" + dt + "\n\n"
                } else {
                    info += "拍摄时间: 未找到 EXIF 数据\n\n"
                }

                // GPS（ImageIO 已解析为十进制度，Ref 决定正负）
                if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
                   let rawLat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
                   let rawLon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
                    lat = rawLat; lon = rawLon
                    if let r = gps[kCGImagePropertyGPSLatitudeRef] as? String, r.uppercased() == "S" { lat = -lat }
                    if let r = gps[kCGImagePropertyGPSLongitudeRef] as? String, r.uppercased() == "W" { lon = -lon }
                    if lat != 0 || lon != 0 { hasGPS = true }
                }
            }
        } else {
            // 文件记录时间
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let mtime = attrs[.modificationDate] as? Date {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                info += "文件记录时间:\n" + df.string(from: mtime) + "\n\n"
            }
            // 视频 GPS：主路暴力扫描 ISO-6709 ©xyz 原子（无扩展名/伪装文件也能读）；
            // 扫不到再用 AVFoundation 通用 location 元数据兜底。
            if let coord = VideoGPSScanner.scan(url: url) {
                lat = coord.lat; lon = coord.lon; hasGPS = true
            } else if let coord = VideoGPSScanner.locationViaAVFoundation(url: url, type: type) {
                lat = coord.lat; lon = coord.lon; hasGPS = true
            }
        }

        return MediaMetadata(infoText: info, hasGPS: hasGPS, lat: lat, lon: lon)
    }
}

/// 视频 GPS 暴力扫描器：在没有扩展名/被伪装的视频里，直接在原始字节流中定位
/// Apple QuickTime 的 ISO-6709 经纬度原子（如 "+39.9042-079.0783/"）。
/// 等价于原作的 FindVideoGPS()，但用有界切片彻底消除了原作 `len - 20` 的无符号回绕越界读。
enum VideoGPSScanner {
    private static let chunk: UInt64 = 2 * 1024 * 1024

    static func scan(url: URL) -> (lat: Double, lon: Double)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let fileSize = try? fh.seekToEnd() else { return nil }

        // 头部 2MB
        try? fh.seek(toOffset: 0)
        if let head = try? fh.read(upToCount: Int(min(fileSize, chunk))),
           let c = search(head) { return c }

        // 再扫尾部 2MB：iPhone/相机视频的 ©xyz 坐标原子多在 moov，而 moov 常在文件尾。
        // 放宽到「只要文件比头缓冲大」就尾扫（原作是 >4MB 才扫，会漏掉 2~4MB 的短视频）。
        if fileSize > chunk {
            try? fh.seek(toOffset: fileSize - chunk)
            if let tail = try? fh.read(upToCount: Int(chunk)),
               let c = search(tail) { return c }
        }
        return nil
    }

    /// AVFoundation 兜底：读容器的通用 location 元数据（commonKeyLocation）。
    /// 覆盖字节扫描窗口之外、以及 ©xyz 之外能被 AVFoundation 解析的 location 表示。
    /// 需要 asset 可识别，故同样用 AssetFactory 的 MIME 提示。
    static func locationViaAVFoundation(url: URL, type: MediaType) -> (lat: Double, lon: Double)? {
        let asset = AssetFactory.make(url: url, type: type)
        let items = AVMetadataItem.metadataItems(from: asset.metadata,
                                                 withKey: AVMetadataKey.commonKeyLocation,
                                                 keySpace: .common)
        if let s = items.first?.stringValue { return parseISO6709String(s) }
        return nil
    }

    /// 解析形如 "+39.9042-079.0783/" 或 "+39.9042-079.0783+010.5/" 的 ISO-6709 字符串。
    static func parseISO6709String(_ raw: String) -> (lat: Double, lon: Double)? {
        var s = raw
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return parse(s)
    }

    private static func search(_ data: Data) -> (lat: Double, lon: Double)? {
        let b = [UInt8](data)
        let n = b.count
        if n < 21 { return nil }

        func isDigit(_ x: UInt8) -> Bool { x >= 0x30 && x <= 0x39 }
        let plus = UInt8(ascii: "+"), minus = UInt8(ascii: "-")

        var i = 0
        while i + 2 < n {   // 有界，永不越界
            if (b[i] == plus || b[i] == minus), isDigit(b[i + 1]), isDigit(b[i + 2]) {
                let end = min(i + 60, n)
                // Latin-1 保证任意字节都能解码（等价于原作的裸 std::string），后续字符校验负责剔除噪声
                if let s = String(bytes: b[i..<end], encoding: .isoLatin1),
                   let slash = s.firstIndex(of: "/") {
                    let dist = s.distance(from: s.startIndex, to: slash)
                    if dist >= 15 && dist < 50 {
                        let coord = String(s[s.startIndex..<slash])
                        // 只认 ASCII 数字（等价原作 isdigit），避免 Latin-1 上标/分数字符（²½等）误判
                        if coord.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "+" || $0 == "-" || $0 == "." }),
                           let parsed = parse(coord) {
                            return parsed
                        }
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// 把 "+39.9042-079.0783" 按符号位切成 lat / lon 并做范围校验。等价于原作的第二/第三符号切分。
    private static func parse(_ s: String) -> (lat: Double, lon: Double)? {
        let c = Array(s)
        guard c.count > 1 else { return nil }

        // 从下标 1 起找第二个符号
        guard let second = (1..<c.count).first(where: { c[$0] == "+" || c[$0] == "-" }) else { return nil }
        // 第二个符号之后找第三个符号（可选）
        let third = ((second + 1)..<c.count).first(where: { c[$0] == "+" || c[$0] == "-" })

        let latStr = String(c[0..<second])
        let lonStr = third != nil ? String(c[second..<third!]) : String(c[second...])
        guard let tLat = Double(latStr), let tLon = Double(lonStr) else { return nil }

        if tLat >= -90, tLat <= 90, tLon >= -180, tLon <= 180, (tLat != 0 || tLon != 0) {
            return (tLat, tLon)
        }
        return nil
    }
}
