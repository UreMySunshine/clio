#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-reclassify.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
bash "$root/Scripts/build-zstd.sh" "$scratch"
swiftc -swift-version 5 -O -module-cache-path "$scratch/module-cache" \
    -I "$root/Sources/CZstd/include" "$scratch/zstddeclib.o" -o "$scratch/reclassify-day" \
    "$root/Sources/Clio/Model/Usage.swift" "$root/Sources/Clio/Model/RateLimits.swift" \
    "$root/Sources/Clio/Model/Pricing.swift" "$root/Sources/Clio/Data/LogScanner.swift" \
    "$root/Sources/Clio/Data/SleepHistory.swift" "$root/Sources/Clio/Data/ClaudeCodeReader.swift" \
    "$root/Sources/Clio/Data/CodexReader.swift" "$root/Sources/Clio/Data/UsageLedger.swift" \
    "$root/Sources/Clio/Data/AppPaths.swift" "$root/Sources/Clio/Data/StatusLineInstaller.swift" \
    "$root/Tools/ReclassifyDay.swift"
"$scratch/reclassify-day" "$@"
