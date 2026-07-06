#!/bin/bash
# 无头逻辑回归测试 —— 不需要 Xcode，只用命令行工具链即可运行。
# 编译 App 里的纯逻辑源文件 + 本目录的测试，然后运行。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
BIN="$(mktemp -t pvlogictest)"

swiftc -sdk "$SDK" -target arm64-apple-macosx12.0 -swift-version 5 \
  "$ROOT/Sources/MediaFile.swift" \
  "$ROOT/Sources/MetadataReader.swift" \
  "$ROOT/Sources/Geocoder.swift" \
  "$ROOT/Sources/AssetFactory.swift" \
  "$ROOT/Sources/DirectoryScanner.swift" \
  "$ROOT/Sources/ThumbnailCache.swift" \
  "$DIR/LogicTests.swift" \
  -o "$BIN"

"$BIN"
