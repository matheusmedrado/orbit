#!/bin/bash
# ./build.sh           build build/Orbit.app (universal: Apple silicon + Intel)
# ./build.sh install   build, copy to /Applications and launch
# ./build.sh dmg       build and package build/Orbit-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP=build/Orbit.app

build_arch() {
    swift build -c release --triple "$1-apple-macosx14.0" >&2
    echo "$(swift build -c release --triple "$1-apple-macosx14.0" --show-bin-path)/Orbit"
}

ARM=$(build_arch arm64)
INTEL=$(build_arch x86_64)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM" "$INTEL" -output "$APP/Contents/MacOS/Orbit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/*.png Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION)"

case "${1:-}" in
install)
    pkill -x Orbit 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Orbit.app
    cp -R "$APP" /Applications/
    open /Applications/Orbit.app
    echo "Installed /Applications/Orbit.app"
    ;;
dmg)
    DMG="build/Orbit-$VERSION.dmg"
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Orbit" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "Packaged $DMG"
    shasum -a 256 "$DMG"
    ;;
esac
