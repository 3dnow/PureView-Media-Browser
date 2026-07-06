#!/bin/bash
# 免 Xcode 构建：只用 Command Line Tools（swiftc）即可产出可双击运行的 PureViewMedia.app。
# 若装了完整 Xcode，直接开 PureViewMedia.xcodeproj 按 Cmd+R 更省事；本脚本是没装 Xcode 时的后路。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
APP="$DIR/build/PureViewMedia.app"
ARCH="$(uname -m)"   # arm64 或 x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo ">> 编译 (target: ${ARCH}-apple-macosx12.0) ..."
swiftc -sdk "$SDK" -target "${ARCH}-apple-macosx12.0" -swift-version 5 -O \
  "$DIR"/Sources/*.swift \
  -o "$APP/Contents/MacOS/PureViewMedia"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PureViewMedia</string>
<key>CFBundleIdentifier</key><string>com.pureview.media</string>
<key>CFBundleName</key><string>PureViewMedia</string>
<key>CFBundleDisplayName</key><string>PureView 媒体浏览器</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict></plist>
PLIST

# 本地 ad-hoc 签名，避免 Gatekeeper 直接拦（首次打开仍可能需在“系统设置-隐私与安全性”里放行）
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo ">> 完成: $APP"
echo ">> 运行: open \"$APP\"    或双击 build/ 里的 PureViewMedia.app"
