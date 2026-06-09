#!/bin/bash
# AgentDeck 构建 / 安装 / 打包脚本
#   ./build.sh             构建自包含 dist/AgentDeck.app
#   ./build.sh install     构建并安装到 /Applications（自动迁移旧版自启方式）
#   ./build.sh dmg         构建并产出 dist/AgentDeck-<版本>.dmg
#   ./build.sh uninstall   完整卸载（App + 登录项 + 数据目录可选保留）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/AgentDeck.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUNDLE_ID="com.agentdeck.app"

MIN_MACOS="13.0"   # 部署目标：不显式指定时 swiftc 会按构建机系统版本打 minos，
                   # 在更低系统上直接拒绝启动（实测 macOS 26 上构建会要求 26）。

build() {
  echo "▸ 编译 AgentDeck.app ($VERSION) — 通用二进制 (arm64+x86_64)，最低 macOS ${MIN_MACOS}…"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  local FRAMEWORKS=(-framework Cocoa -framework WebKit -framework ServiceManagement)
  local A="$DIST/.AgentDeck-arm64" X="$DIST/.AgentDeck-x86_64"
  swiftc -O "${FRAMEWORKS[@]}" -target arm64-apple-macos${MIN_MACOS} \
    -o "$A" "$ROOT/app/main.swift"
  if swiftc -O "${FRAMEWORKS[@]}" -target x86_64-apple-macos${MIN_MACOS} \
       -o "$X" "$ROOT/app/main.swift" 2>/dev/null; then
    lipo -create "$A" "$X" -o "$APP/Contents/MacOS/AgentDeck"
    rm -f "$A" "$X"
  else
    echo "  ⚠️ x86_64 交叉编译失败，回退为 arm64-only（仍适配 ${MIN_MACOS}+ 的 Apple Silicon）"
    mv "$A" "$APP/Contents/MacOS/AgentDeck"
  fi

  # 自包含：后端 + UI + 图标全部入包
  cp "$ROOT/agentdeckd.py" "$APP/Contents/Resources/"
  cp "$ROOT/VERSION" "$APP/Contents/Resources/"
  cp -R "$ROOT/static" "$APP/Contents/Resources/static"
  [ -f "$ROOT/assets/AgentDeck.icns" ] || {
    swift "$ROOT/scripts/makeicon.swift" "$ROOT/assets"
    iconutil -c icns "$ROOT/assets/AgentDeck.iconset" -o "$ROOT/assets/AgentDeck.icns"
    rm -rf "$ROOT/assets/AgentDeck.iconset"
  }
  cp "$ROOT/assets/AgentDeck.icns" "$APP/Contents/Resources/"

  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentDeck</string>
  <key>CFBundleDisplayName</key><string>AgentDeck</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>AgentDeck</string>
  <key>CFBundleIconFile</key><string>AgentDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF
  codesign --force --deep -s - "$APP" 2>/dev/null
  echo "✓ 构建完成: $APP"
}

stop_running() {
  pkill -x AgentDeck 2>/dev/null || true
  pkill -f agentdeckd.py 2>/dev/null || true
  sleep 0.5
}

case "${1:-build}" in
  build)
    build
    ;;
  install)
    build
    stop_running
    echo "▸ 安装到 /Applications…"
    rm -rf "/Applications/AgentDeck.app"
    cp -R "$APP" /Applications/
    open "/Applications/AgentDeck.app"
    echo "✓ 已安装并启动。首次启动会自动注册「登录项」开机自启"
    echo "  （系统设置 → 通用 → 登录项 可见；右键菜单栏图标也可切换）"
    ;;
  dmg)
    build
    echo "▸ 打包 DMG（含 Finder 安装布局）…"
    VOL="AgentDeck"
    RW="$DIST/agentdeck-rw.dmg"
    FINAL="$DIST/AgentDeck-$VERSION.dmg"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    mkdir "$STAGE/.background"
    [ -f "$ROOT/assets/dmg-bg.png" ] || \
      swift "$ROOT/scripts/makedmgbg.swift" "$ROOT/assets/dmg-bg.png"
    cp "$ROOT/assets/dmg-bg.png" "$STAGE/.background/bg.png"

    # 先建可写镜像，挂载后用 Finder 排版（背景图 + 图标定位），再压缩为只读
    rm -f "$RW" "$FINAL"
    hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
    MOUNT_DIR="/Volumes/$VOL"
    hdiutil attach "$RW" -noautoopen >/dev/null
    osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 480}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 104
    set text size of vo to 12
    set background picture of vo to file ".background:bg.png"
    set position of item "AgentDeck.app" of container window to {140, 185}
    set position of item "Applications" of container window to {400, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
    sync
    hdiutil detach "$MOUNT_DIR" >/dev/null
    hdiutil convert "$RW" -format UDZO -o "$FINAL" >/dev/null
    rm -f "$RW"
    rm -rf "$STAGE"
    echo "✓ $FINAL"
    ;;
  uninstall)
    stop_running
    rm -rf "/Applications/AgentDeck.app" "$DIST"
    echo "✓ 已卸载 App。数据目录保留在:"
    echo "    ~/Library/Application Support/AgentDeck"
    echo "  如需彻底清理: rm -rf ~/Library/Application\\ Support/AgentDeck ~/Library/Logs/AgentDeck.log"
    ;;
  *)
    echo "用法: ./build.sh [build|install|dmg|uninstall]"; exit 1 ;;
esac
