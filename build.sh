#!/bin/zsh
set -eu
cd "${0:A:h}"
case "${1:-}" in
  "" | --no-sign) ;;
  *)
    print "usage: zsh build.sh [--no-sign]" >&2
    exit 2
    ;;
esac
mkdir -p build/module-cache build/Shortcup.app/Contents/MacOS
typeset -F SECONDS
unit_started=$SECONDS
swiftc -module-cache-path build/module-cache Sources/Shortcuts.swift Tests.swift -o build/checks
./build/checks
printf 'unit-tests-seconds: %.3f\n' $((SECONDS - unit_started))
app_started=$SECONDS
swiftc -module-cache-path build/module-cache Sources/Shortcuts.swift Sources/App.swift Sources/Validation.swift -o build/Shortcup.app/Contents/MacOS/Shortcup -framework AppKit -framework ApplicationServices -framework Carbon
cp Info.plist build/Shortcup.app/Contents/Info.plist
if [[ "${1:-}" != "--no-sign" ]]; then
  codesign --force --sign - --identifier com.shortcup.app build/Shortcup.app
fi
touch build/Shortcup.app
printf 'app-build-seconds: %.3f\n' $((SECONDS - app_started))
print "Built: $PWD/build/Shortcup.app"
