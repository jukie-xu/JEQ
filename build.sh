#!/bin/bash
# JEQ 构建脚本：Swift 源码 → .app bundle（无需 Xcode 工程）
# 每次构建都从空目录开始，build/ 下只会存在 JEQ.app 这一个产物。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/JEQ.app"
BIN="$APP/Contents/MacOS/JEQ"

echo "▸ 清理旧产物"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 编译 Swift"
SRCS=$(find "$ROOT/Sources/JEQ" -name '*.swift' | sort)
swiftc \
  -O -wmo \
  -swift-version 5 \
  -target arm64-apple-macos14.4 \
  -o "$BIN" \
  $SRCS \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework AppKit \
  -framework SwiftUI \
  -framework ServiceManagement

echo "▸ 组装 bundle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$BIN"
cp "$ROOT/Resources/JEQ.icns" "$APP/Contents/Resources/JEQ.icns"
cp "$ROOT/Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
if [ -f "$ROOT/Resources/MenuBarIcon@2x.png" ]; then
    cp "$ROOT/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"
fi

echo "▸ ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "▸ 校验"
codesign -dv "$APP" 2>&1 | head -3
echo "✓ 产物: $APP"
ls -lh "$BIN" | awk '{print "  binary size:", $5}'
