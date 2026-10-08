#!/bin/zsh
set -eu
cd "${0:A:h}"
mode="${1:-product}"
mkdir -p build/module-cache
swiftc -module-cache-path build/module-cache Sources/Shortcuts.swift Sources/Detect.swift Tests.swift -o build/checks
./build/checks
if [[ "$mode" == "--checks-only" ]]; then
  print "Checks passed"
  exit 0
fi
if [[ "$mode" == "--dev" ]]; then
  mkdir -p "build/Shortcup Dev.app/Contents/MacOS"
  swiftc -D SHORTCUP_DEV -module-cache-path build/module-cache \
    Sources/Shortcuts.swift Sources/Detect.swift Sources/App.swift Sources/Validation.swift Sources/SelfTest.swift \
    -o "build/Shortcup Dev.app/Contents/MacOS/ShortcupDev" \
    -framework AppKit -framework ApplicationServices -framework Carbon
  minos="$(vtool -show-build "build/Shortcup Dev.app/Contents/MacOS/ShortcupDev" | awk '/minos/ { print $2; exit }')"
  [[ -n "$minos" ]]
  cat > "build/Shortcup Dev.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ShortcupDev</string>
<key>CFBundleIdentifier</key><string>com.shortcup.dev</string>
<key>CFBundleName</key><string>Shortcup Dev</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>${minos}</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
  print "Built: $PWD/build/Shortcup Dev.app"
  exit 0
fi
mkdir -p build/Shortcup.app/Contents/MacOS
swiftc -module-cache-path build/module-cache Sources/Shortcuts.swift Sources/Detect.swift Sources/App.swift Sources/Validation.swift -o build/Shortcup.app/Contents/MacOS/Shortcup -framework AppKit -framework ApplicationServices -framework Carbon
minos="$(vtool -show-build build/Shortcup.app/Contents/MacOS/Shortcup | awk '/minos/ { print $2; exit }')"
[[ -n "$minos" ]]
# Keep the checked-in plist in sync with the binary before copying it into the bundle.
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minos" Info.plist
cp Info.plist build/Shortcup.app/Contents/Info.plist
codesign --force --sign - --identifier com.shortcup.app build/Shortcup.app
touch build/Shortcup.app
print "Built: $PWD/build/Shortcup.app"
