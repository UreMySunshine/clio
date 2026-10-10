#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
swiftc -swift-version 5 -o "$root/build/ccusage-alignment-tests" \
    "$root/Sources/Clio/Model/Usage.swift" \
    "$root/Sources/Clio/Model/Pricing.swift" \
    "$root/Sources/Clio/Model/RateLimits.swift" \
    "$root/Sources/Clio/Data/DashboardBuilder.swift" \
    "$root/Sources/Clio/Data/CodexReader.swift" \
    "$root/Sources/Clio/Data/LogScanner.swift" \
    "$root/Sources/Clio/Data/ClaudeCodeReader.swift" \
    "$root/Sources/Clio/Data/PlanReader.swift" \
    "$root/Tests/CCUsageAlignmentTests.swift"
"$root/build/ccusage-alignment-tests" "$@"
