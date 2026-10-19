#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-model-speed-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
sdk="$(xcrun --show-sdk-path)"
if rg -q StateMacro "$sdk"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface; then
    for candidate in $(printf '%s\n' "$(dirname "$sdk")"/MacOSX*.*.sdk | sort -rV); do
        if ! rg -q StateMacro "$candidate"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface; then
            sdk="$candidate"
            break
        fi
    done
fi
bash "$root/Scripts/build-zstd.sh" "$scratch"
swiftc -swift-version 5 -sdk "$sdk" -module-cache-path "$scratch/module-cache" \
    -I "$root/Sources/CZstd/include" "$scratch/zstddeclib.o" -o "$scratch/model-speed-tests" \
    $(rg --files "$root/Sources/Clio" -g '*.swift' -g '!main.swift') \
    "$root/Tests/ModelSpeedTests.swift"
"$scratch/model-speed-tests" "$scratch"
