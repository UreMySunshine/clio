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

# Notarising is what removes the "Apple 无法验证" prompt on another Mac. It
# needs a Developer ID signature on the app first, plus stored credentials:
#   xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password …
if [ -n "${CLIO_NOTARY_PROFILE:-}" ]; then
    echo "公证中（几分钟）…"
    xcrun notarytool submit "$dmg" --keychain-profile "$CLIO_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    echo "公证完成，已装订票据"
else
    echo "未公证（未设置 CLIO_NOTARY_PROFILE），别的 Mac 首次打开需手动放行"
fi

echo "完成：$dmg"
du -h "$dmg" | cut -f1 | xargs echo "大小："
