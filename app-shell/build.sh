#!/bin/bash
# 构建 RHINE LAB 桌面 App 并安装到桌面。
# 用法：bash build.sh [--skip-web] [--install-dir <dir>]
set -euo pipefail

PROJECT="$HOME/Desktop/RhineLabUI"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RhineLab.app"
INSTALL_DIR="$HOME/Desktop"

SKIP_WEB=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-web) SKIP_WEB=1 ;;
    --install-dir) INSTALL_DIR="$2"; shift ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
  shift
done

# 1. 构建 Web 前端
if [[ $SKIP_WEB -eq 0 ]]; then
  echo "==> 构建 Web 前端 (npm run build)"
  (cd "$PROJECT" && npm run build)
fi

# 2. 组装 App 骨架
BUILD="$HERE/build"
rm -rf "$BUILD"
mkdir -p "$BUILD/$APP_NAME/Contents/MacOS"
mkdir -p "$BUILD/$APP_NAME/Contents/Resources/web"

echo "==> 复制 Web 产物"
cp -R "$PROJECT/dist/." "$BUILD/$APP_NAME/Contents/Resources/web/"

echo "==> 生成 App 图标 (AppIcon.icns)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
# 用 QuickLook 把 SVG 渲染成 1024 PNG
qlmanage -t -s 1024 -o "$(dirname "$ICONSET")" "$PROJECT/dist/favicon.svg" >/dev/null 2>&1
SVG_PNG="$(dirname "$ICONSET")/favicon.svg.png"
if [[ ! -f "$SVG_PNG" ]]; then
  echo "!! qlmanage 无法渲染 SVG，改用 sips 生成占位图标"
  SVG_PNG="$PROJECT/art/archive-studio.png"
fi
sips -z 16 16 "$SVG_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$SVG_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SVG_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$SVG_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SVG_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$SVG_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SVG_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$SVG_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SVG_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SVG_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$BUILD/$APP_NAME/Contents/Resources/AppIcon.icns"

echo "==> 编译 Swift 壳 (swiftc -O)"
swiftc -O -swift-version 5 "$HERE/main.swift" -o "$BUILD/$APP_NAME/Contents/MacOS/RhineLab" \
  -framework AppKit -framework WebKit -framework Network \
  -framework PDFKit -framework QuickLookThumbnailing \
  -framework UniformTypeIdentifiers -framework CryptoKit

echo "==> 写入 Info.plist"
cp "$HERE/Info.plist" "$BUILD/$APP_NAME/Contents/Info.plist"

echo "==> 代码签名 (ad-hoc)"
codesign --force --deep --sign - "$BUILD/$APP_NAME" >/dev/null 2>&1 || echo "!! 签名失败（本地运行通常无碍）"

echo "==> 安装到 $INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$BUILD/$APP_NAME" "$INSTALL_DIR/"
touch "$INSTALL_DIR/$APP_NAME"
echo "完成：$INSTALL_DIR/$APP_NAME"
