#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build/module-cache build/Shortcup.app/Contents/MacOS
swiftc -module-cache-path build/module-cache Sources/Shortcuts.swift Tests.swift -o build/checks
./build/checks
swiftc -module-cache-path build/module-cache Sources/Shortcuts.swift Sources/App.swift Sources/Validation.swift -o build/Shortcup.app/Contents/MacOS/Shortcup -framework AppKit -framework ApplicationServices -framework Carbon
cp Info.plist build/Shortcup.app/Contents/Info.plist
codesign --force --sign - --identifier com.shortcup.app build/Shortcup.app
touch build/Shortcup.app
print "Built: $PWD/build/Shortcup.app"
