#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-model-speed-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
sdk="$(xcrun --show-sdk-path)"
if grep -qs StateMacro "$sdk"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface; then
    for candidate in $(printf '%s\n' "$(dirname "$sdk")"/MacOSX*.*.sdk | sort -rV); do
        if ! grep -qs StateMacro "$candidate"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface; then
            sdk="$candidate"
            break
        fi
    done
fi
bash "$root/Scripts/build-zstd.sh" "$scratch"
swiftc -swift-version 5 -sdk "$sdk" -module-cache-path "$scratch/module-cache" \
    -I "$root/Sources/CZstd/include" "$scratch/zstddeclib.o" -o "$scratch/model-speed-tests" \
    $(find "$root/Sources/Clio" -name '*.swift' ! -name 'main.swift') \
    "$root/Tests/ModelSpeedTests.swift"
"$scratch/model-speed-tests" "$scratch"
