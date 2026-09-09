#!/bin/bash
# Builds Clio.app and wraps it in a disk image for installing elsewhere.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build"
app="$build/Clio.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Resources/Info.plist")"
dmg="$build/Clio-$version.dmg"

"$root/Scripts/build.sh"

echo "制作磁盘映像…"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
hdiutil create -volname "Clio" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null

echo "完成：$dmg"
du -h "$dmg" | cut -f1 | xargs echo "大小："
