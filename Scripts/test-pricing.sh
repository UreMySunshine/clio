#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-pricing-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 5 -module-cache-path "$scratch/module-cache" -o "$scratch/pricing-tests" \
    "$root/Sources/Clio/Model/Usage.swift" \
    "$root/Sources/Clio/Model/Pricing.swift" \
    "$root/Sources/Clio/Model/RateLimits.swift" \
    "$root/Sources/Clio/Data/UsageLedger.swift" \
    "$root/Sources/Clio/Data/AppPaths.swift" \
    "$root/Sources/Clio/Data/StatusLineInstaller.swift" \
    "$root/Sources/Clio/Data/PriceService.swift" \
    "$root/Tests/PricingTests.swift"
"$scratch/pricing-tests"
