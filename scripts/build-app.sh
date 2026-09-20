#!/bin/bash
# 打包 MacClean.app（无 Xcode 环境：swift build + 手工 .app 结构 + ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MacClean"
BUILD_DIR=".build/release"
APP_DIR="dist/$APP_NAME.app"
VERSION="1.49.0"

# ---- 构建 SDK 选择（无 Xcode 的纯 CLT 环境必读）----
# macOS 26.x 起 SwiftUI 的 @State 等属性包装器由宏实现，宏插件 `SwiftUIMacros`
# 随 Xcode 提供、CommandLineTools 中不含。SDK 27.0 的 SwiftUI 接口引用了该宏，
# 故纯 CLT 环境用默认 SDK 构建必然失败：
#   error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
# 对策：回退到 SDK 26.5（实测可完整通过自检）。详见 docs/RELEASE-CHECKLIST.md 第 0 节。
if [ -z "${SDKROOT:-}" ]; then
    OLD_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if [ -d "$OLD_SDK" ] && [ ! -d "/Applications/Xcode.app" ]; then
        export SDKROOT="$OLD_SDK"
        echo "==> 未检测到 Xcode，自动改用 SDK: $OLD_SDK"
    fi
fi

# 注意：变量引用后紧跟多字节字符时必须写成 ${VAR}，否则 bash（C locale 下）
# 会把该字符的首字节并入变量名，在 set -u 下报 "SDKROOT?: unbound variable"。
SDK_NOTE=""
if [ -n "${SDKROOT:-}" ]; then SDK_NOTE="（SDKROOT=${SDKROOT}）"; fi
echo "==> Release 构建${SDK_NOTE}"
swift build -c release

echo "==> 配置图标"
if [ -f "Resources/AppIcon.icns" ]; then
    ICON_SRC="Resources/AppIcon.icns"
else
    ICON_DIR="/tmp/macclean-icon.iconset"
    rm -rf "$ICON_DIR"
    swift scripts/make-icon.swift "$ICON_DIR" >/dev/null
    iconutil -c icns "$ICON_DIR" -o "$ICON_DIR/AppIcon.icns"
    ICON_SRC="$ICON_DIR/AppIcon.icns"
fi

echo "==> 组装 .app"
rm -rf "dist"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/"
cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacClean</string>
    <key>CFBundleDisplayName</key><string>MacClean</string>
    <key>CFBundleIdentifier</key><string>com.macclean.app</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>MacClean</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 MacClean</string>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 完成: $(pwd)/$APP_DIR"
