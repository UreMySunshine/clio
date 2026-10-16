#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
swiftc -swift-version 5 -o "$root/build/quota-ring-tests" \
    "$root/Sources/Clio/Model/Usage.swift" \
    "$root/Sources/Clio/Model/Pricing.swift" \
    "$root/Sources/Clio/Model/RateLimits.swift" \
    "$root/Sources/Clio/Data/UsageLedger.swift" \
    "$root/Sources/Clio/Data/AppPaths.swift" \
    "$root/Sources/Clio/Data/StatusLineInstaller.swift" \
    "$root/Sources/Clio/View/Theme.swift" \
    "$root/Sources/Clio/View/MenuBarQuotaLabel.swift" \
    "$root/Tests/MenuBarQuotaTests.swift"
"$root/build/quota-ring-tests"
