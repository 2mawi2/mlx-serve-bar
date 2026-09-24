#!/bin/zsh
# Build, selftest, bundle, and optionally install MLX Bar.
#   ./build.sh              → build + selftest + bundle (dist/MLXBar.app)
#   ./build.sh --install    → also copy to ~/Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
.build/release/mlxbar --selftest

APP=dist/MLXBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MLX Bar</string>
  <key>CFBundleDisplayName</key><string>MLX Bar</string>
  <key>CFBundleIdentifier</key><string>com.mariuswichtner.mlxbar</string>
  <key>CFBundleExecutable</key><string>mlx-bar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
cp .build/release/mlxbar "$APP/Contents/MacOS/mlx-bar"
codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -f 'MLXBar.app/Contents/MacOS/mlx-bar' 2>/dev/null || true
  sleep 0.3
  rsync -a --delete "$APP/" "$HOME/Applications/MLXBar.app/"
  open "$HOME/Applications/MLXBar.app"
  echo "installed → ~/Applications/MLXBar.app"
else
  echo "built → $APP"
fi
