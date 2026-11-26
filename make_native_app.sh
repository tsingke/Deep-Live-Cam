#!/bin/zsh
# 构建原生 LiveFace.app（SwiftUI + AVFoundation，后台静默复用 Python 换脸服务）
#   ./make_native_app.sh             # 构建到项目目录
#   ./make_native_app.sh --install   # 同时安装到 ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/LiveFace.app"
BUILD="$ROOT/.build-native"

if [ ! -f "assets/AppIcon.icns" ]; then
  .venv/bin/python assets/make_icon.py
fi

echo "编译 Swift 原生界面…"
mkdir -p "$BUILD"
xcrun swiftc \
  -swift-version 5 -O \
  -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework CoreImage -framework ImageIO -framework UniformTypeIdentifiers \
  -framework QuartzCore \
  native/*.swift -o "$BUILD/LiveFace"

echo "打包 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/LiveFace" "$APP/Contents/MacOS/LiveFace"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf '%s' "$ROOT" > "$APP/Contents/Resources/ProjectPath.txt"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>LiveFace</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.liveface.studio</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>LiveFace</string>
  <key>CFBundleDisplayName</key><string>实时换脸</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>实时换脸需要访问摄像头来采集画面。</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
/usr/bin/xattr -cr "$APP" 2>/dev/null || true
touch "$APP"
echo "✓ 已生成：$APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/LiveFace.app"
  cp -R "$APP" "$HOME/Applications/LiveFace.app"
  /usr/bin/codesign --force --deep --sign - "$HOME/Applications/LiveFace.app" >/dev/null 2>&1 || true
  /usr/bin/xattr -cr "$HOME/Applications/LiveFace.app" 2>/dev/null || true
  touch "$HOME/Applications/LiveFace.app"
  echo "✓ 已安装：$HOME/Applications/LiveFace.app"
fi
