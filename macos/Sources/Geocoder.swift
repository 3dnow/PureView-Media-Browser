import Foundation

/// 地址清洗：等价于原作 CleanLocationString —— 截断 " / "、";"、"；"、"/" 之后的内容，
/// 去首尾空白，并剔除“含数字且很短”的片段（邮编等）。
enum CleanLocation {
    static func clean(_ input: String) -> String {
        var part = input
        for sep in [" / ", ";", "；", "/"] {
            if let r = part.range(of: sep) { part = String(part[..<r.lowerBound]) }
        }
        part = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if part.isEmpty { return "" }
        // 只认 ASCII 数字：等价原作 isdigit。注意 Swift 的 Character.isNumber 对「京/万/千/亿」等
        // CJK 数字也返回 true，若不限定 ASCII，含这些字的地名（北京/南京/东京）会被误当邮编删掉。
        let hasDigit = part.contains { $0.isASCII && $0.isNumber }
        if hasDigit && part.count <= 8 { return "" }   // 邮编等短数字串
        return part
    }
}

/// Nominatim 反查 + 内存网格缓存。等价于原作 FetchAddressThread + g_gpsCache。
/// 防封策略：懒加载 + 800ms 防抖（在 ViewerWindowController 里）+ 按 ~100m 网格缓存。
final class Geocoder {
    static let shared = Geocoder()

    private var cache: [String: String] = [:]
    private let lock = NSLock()

    /// 按 0.001 度（约 100 米）抹平坐标，生成公用缓存 Key。等价于原作 GetGpsCacheKey。
    static func cacheKey(lat: Double, lon: Double) -> String {
        String(format: "%.3f_%.3f", lat, lon)
    }

    func cached(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// 拉取地址；成功时把 finalDisplay（📍 主行 + 详细地址）写入缓存并回调，失败回调 nil。
    /// 失败不写缓存——网络抖动一次不应污染该 100m 网格整个会话，调用方可安排重试。
    /// 回调在 URLSession 的后台线程触发，调用方负责切回主线程并做会话校验。
    func fetch(lat: Double, lon: Double, completion: @escaping (String?) -> Void) {
        let key = Geocoder.cacheKey(lat: lat, lon: lon)
        let urlStr = "https://nominatim.openstreetmap.org/reverse?format=json&lat=\(lat)&lon=\(lon)&accept-language=zh-CN"
        guard let url = URL(string: urlStr) else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        // Nominatim 使用条款要求带可识别 User-Agent
        req.setValue("PureViewMedia/1.0 (macOS media browser)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let result = Geocoder.parse(data)
            if let self = self, let result = result {
                self.lock.lock(); self.cache[key] = result; self.lock.unlock()
            }
            completion(result)
        }.resume()
    }

    /// 解析 Nominatim JSON，拼出 finalDisplay；什么都没解析出来（网络失败/JSON 异常/空地址）返回 nil。
    /// 深度清洗 + 详细地址倒序还原为中文习惯顺序。
    private static func parse(_ data: Data?) -> String? {
        guard let data = data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let address = obj["address"] as? [String: Any] ?? [:]
        func f(_ key: String) -> String { CleanLocation.clean((address[key] as? String) ?? "") }

        let country = f("country")
        var state = f("state"); if state.isEmpty { state = f("province") }
        var city = f("city"); if city.isEmpty { city = f("town") }
        let suburb = f("suburb")

        // 过滤空段再拼接，避免「中国␣␣␣」这类多余空格
        var resultText = "地址解析失败"
        let full = [country, state, city, suburb].filter { !$0.isEmpty }.joined(separator: " ")
        if full.count >= 2 { resultText = full }

        var detailed = ""
        if let displayName = obj["display_name"] as? String, !displayName.isEmpty {
            // display_name 是西式“小→大”倒装，reversed 后变“大→小”符合中文习惯
            for p in displayName.components(separatedBy: ",").reversed() {
                let cleaned = CleanLocation.clean(p)
                if cleaned.isEmpty { continue }
                detailed += cleaned + " "
            }
        }

        if resultText == "地址解析失败" && detailed.isEmpty { return nil }
        return "📍 " + resultText + "\n\n详细地址:\n" + detailed
    }
}
