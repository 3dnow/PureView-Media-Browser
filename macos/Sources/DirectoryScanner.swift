import Foundation

/// 扫描单个目录，分出「子目录」和「可识别的媒体文件」两类。
/// 抽成纯函数便于无头测试；`isCancelled` 让上层能在扫描大目录途中取消（切目录/返回时）。
/// 只列直接子项（非递归），子目录与媒体各自按名字自然排序（数字按数值序）。
enum DirectoryScanner {
    struct Result {
        var dirs: [(url: URL, name: String)]
        var medias: [MediaFile]
    }

    static func scan(_ folder: URL, isCancelled: () -> Bool = { false }) -> Result {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [])) ?? []
        var dirs: [(url: URL, name: String)] = []
        var medias: [MediaFile] = []

        for u in entries {
            if isCancelled() { return Result(dirs: [], medias: []) }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                dirs.append((url: u, name: u.lastPathComponent))
            } else {
                let t = MediaIdentifier.identify(u)
                if t != .unknown {
                    medias.append(MediaFile(url: u, name: u.lastPathComponent, type: t))
                }
            }
        }

        dirs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        medias.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Result(dirs: dirs, medias: medias)
    }
}
