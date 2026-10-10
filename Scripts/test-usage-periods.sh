#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
swiftc -swift-version 5 -o "$root/build/usage-period-tests" \
    "$root/Sources/Clio/Model/Usage.swift" \
    "$root/Sources/Clio/Model/Pricing.swift" \
    "$root/Sources/Clio/Model/RateLimits.swift" \
    "$root/Sources/Clio/Data/DashboardBuilder.swift" \
    "$root/Sources/Clio/Data/AppPaths.swift" \
    "$root/Sources/Clio/Data/StatusLineInstaller.swift" \
    "$root/Tests/UsagePeriods.swift"
"$root/build/usage-period-tests"
