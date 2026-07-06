import Foundation

/// 线程安全的自增计数器。等价于原作里的 std::atomic<int> 会话号，
/// 用于取消过期的后台任务（切目录 / 快速切图时旧线程回来发现号对不上就丢弃结果）。
final class AtomicInt {
    private var value: Int
    private let lock = NSLock()

    init(_ initial: Int = 0) { value = initial }

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
