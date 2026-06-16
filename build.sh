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

# ── 签名 / 公证（可选，仅 dmg 分发用）──────────────────────────────────────
# SIGN_ID：Developer ID Application 证书名；不设则自动探测本机第一张。缺证书时
#   回退 ad-hoc 签名（本机可跑，但他人下载会被 Gatekeeper 拦）。
# NOTARY_PROFILE：notarytool 钥匙串凭证 profile 名，一次性配好后 dmg 目标自动公证：
#   xcrun notarytool store-credentials AgentDeck \
#     --apple-id <AppleID> --team-id <TeamID> --password <App专用密码>
# 末尾 || true：无证书时 grep 不匹配会以 1 退出，叠加 set -euo pipefail 会让整脚本
# 在此处静默夭折（实测 exit 1、零输出）。兜底为空串即可正常回退 ad-hoc。
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AgentDeck}"

# 签名 .app：有 Developer ID 则带「硬化运行时 + 安全时间戳」（公证前置条件），
# 否则回退 ad-hoc。无内嵌 framework/helper，故不需 --deep。
sign_app() {
  if [ -n "$SIGN_ID" ]; then
    echo "▸ Developer ID 签名（硬化运行时）: $SIGN_ID"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  else
    echo "  ⚠️ 未找到 Developer ID Application 证书 → ad-hoc 签名（不可公证分发）"
    codesign --force --deep -s - "$APP" 2>/dev/null || true
  fi
}

# 公证并装订票据（仅对已签名的 DMG 调用；Apple 公证 DMG 时会一并覆盖内部 .app）。
# 缺证书或未配 profile 时跳过；--wait 因网络中断时不掐断构建（提交多半已在 Apple 端
# 继续处理，DMG 已生成只是未装订），打印补救步骤后照常返回。
notarize() {
  local target="$1"
  if [ -z "$SIGN_ID" ]; then
    echo "  ⚠️ 无 Developer ID 证书，跳过公证: $(basename "$target")"; return 0
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "  ⚠️ 未配置 notarytool 凭证 profile「$NOTARY_PROFILE」，跳过公证"
    echo "     一次性配置: xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "                   --apple-id <AppleID> --team-id <TeamID> --password <App专用密码>"
    return 0
  fi
  echo "▸ 提交公证（--wait，可能数分钟）: $(basename "$target")"
  if ! xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "  ⚠️ 公证未在本地等到结果（多为网络中断）。DMG 已签名生成但未装订。"
    echo "     提交可能仍在 Apple 端处理；确认 Accepted 后手动装订即可，无需重新构建："
    echo "       xcrun notarytool history --keychain-profile $NOTARY_PROFILE   # 查最近提交状态"
    echo "       xcrun stapler staple \"$target\""
    return 0
  fi
  echo "▸ 装订票据（stapler）: $(basename "$target")"
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

build() {
  echo "▸ 编译 AgentDeck.app ($VERSION) — Swift Package 通用二进制 (arm64+x86_64)，最低 macOS ${MIN_MACOS}…"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  # SPM 同时构两架构产出通用二进制；部署目标由 Package.swift 的 platforms 决定（无需 -target）。
  # 系统框架（Cocoa/WebKit/ServiceManagement）随 import 自动链接，无需 -framework。
  # 产物路径用 --show-bin-path 解析，免去硬编码 .build 布局。
  # 只构 AgentDeck 壳产物（不带开发用 PreviewGen）。
  local ARCHS=(--arch arm64 --arch x86_64)
  local PROD=(--product AgentDeck)
  if ! swift build -c release "${PROD[@]}" "${ARCHS[@]}" 2>"$DIST/.swiftbuild.err"; then
    echo "  ⚠️ x86_64 交叉构建失败，回退 arm64-only（仍适配 ${MIN_MACOS}+ 的 Apple Silicon）"
    cat "$DIST/.swiftbuild.err" | tail -5
    ARCHS=(--arch arm64)
    swift build -c release "${PROD[@]}" "${ARCHS[@]}"
  fi
  rm -f "$DIST/.swiftbuild.err"
  local BIN; BIN="$(swift build -c release "${PROD[@]}" "${ARCHS[@]}" --show-bin-path)"
  cp "$BIN/AgentDeck" "$APP/Contents/MacOS/AgentDeck"

  # AgentDeckKit 资源包（Claude/Codex 官方品牌字形）：Bundle.module 需在 .app 内找到它，
  # 否则额度卡/徽章会回退到 SF Symbol 占位图。放进 Resources（= 主包 resourceURL，可被解析）。
  if [ -d "$BIN/AgentDeck_AgentDeckKit.bundle" ]; then
    cp -R "$BIN/AgentDeck_AgentDeckKit.bundle" "$APP/Contents/Resources/"
  else
    echo "  ⚠️ 未找到 AgentDeck_AgentDeckKit.bundle（品牌字形将回退占位图）"
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
  sign_app
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
    notarize "$FINAL"   # 公证+装订 DMG，用户下载首次打开不再被 Gatekeeper 拦
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
