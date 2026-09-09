#!/bin/bash
# Builds Clio.app.
#
# swiftc is invoked directly rather than through `swift build`: SwiftPM's
# manifest compiler fails to link against the PackageDescription library in a
# Command Line Tools-only install. Package.swift is kept for toolchains where
# SwiftPM works.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build"
app="$build/Clio.app"
target="arm64-apple-macosx14.0"

mkdir -p "$build"
rm -rf "$app"

echo "编译…"
swiftc \
    -target "$target" \
    -sdk "$(xcrun --show-sdk-path)" \
    -swift-version 5 \
    -O \
    -o "$build/Clio" \
    $(find "$root/Sources" -name '*.swift')

echo "组装 app bundle…"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build/Clio" "$app/Contents/MacOS/"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/"
cp "$root/Resources/Info.plist" "$app/Contents/"
# An ad-hoc signature is enough for local use; launch-at-login registration
# needs a real Developer ID signature.
codesign --force --sign - "$app" >/dev/null 2>&1 || echo "跳过签名"

echo "完成：$app"
