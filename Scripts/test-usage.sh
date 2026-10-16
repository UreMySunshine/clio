#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-usage-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

bash "$root/Scripts/build-zstd.sh" "$scratch"
swiftc -swift-version 5 -module-cache-path "$scratch/module-cache" \
    -I "$root/Sources/CZstd/include" "$scratch/zstddeclib.o" \
    -o "$scratch/usage-tests" \
    "$root/Sources/Clio/Model/Usage.swift" \
    "$root/Sources/Clio/Model/RateLimits.swift" \
    "$root/Sources/Clio/Model/Pricing.swift" \
    "$root/Sources/Clio/Model/Milestones.swift" \
    "$root/Sources/Clio/Data/LogScanner.swift" \
    "$root/Sources/Clio/Data/SleepHistory.swift" \
    "$root/Sources/Clio/Data/ClaudeCodeReader.swift" \
    "$root/Sources/Clio/Data/ClaudeConfigReader.swift" \
    "$root/Sources/Clio/Data/RateLimitBridge.swift" \
    "$root/Sources/Clio/Data/CodexReader.swift" \
    "$root/Sources/Clio/Data/PlanReader.swift" \
    "$root/Sources/Clio/Data/AppPaths.swift" \
    "$root/Sources/Clio/Data/StatusLineInstaller.swift" \
    "$root/Sources/Clio/Data/DashboardBuilder.swift" \
    "$root/Sources/Clio/Data/UsageLedger.swift" \
    "$root/Sources/Clio/View/Formatting.swift" \
    "$root/Tests/UsageTests.swift"

"$scratch/usage-tests"
