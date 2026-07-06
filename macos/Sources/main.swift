import AppKit

// 入口：等价于原作 wWinMain —— 建立 NSApplication 主循环
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
