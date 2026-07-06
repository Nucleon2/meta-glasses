#!/usr/bin/env bash
#
# scripts/clean-rebuild.sh
# Wipes all SPM/Xcode caches for this project and forces a fresh resolve.
# Use this when SPM is stuck on a stale package URL (e.g. after we changed
# the MetaWearables SDK from the old meta-quest URL to facebook/meta-wearables-dat-ios).
#

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Wiping SPM package cache (for this project)"
rm -rf .build
rm -rf .swiftpm
rm -rf Package.resolved

echo "==> Wiping Xcode DerivedData for RayBanMiniMax"
DD=$(ls -td ~/Library/Developer/Xcode/DerivedData/RayBanMiniMax-* 2>/dev/null | head -1 || true)
if [ -n "$DD" ]; then
    echo "    removing $DD"
    rm -rf "$DD"
fi

echo "==> Wiping SPM global cache (forces re-fetch of package metadata)"
rm -rf ~/Library/Caches/org.swift.swiftpm/manifests
rm -rf ~/Library/Caches/org.swift.swiftpm/package-metadata
rm -rf ~/Library/Caches/org.swift.swiftpm/package-collection.db*
echo "    (left security/ and configuration/ alone — those are safe)"

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate

echo ""
echo "Done. Now in Xcode:"
echo "  1. Open the project:    open -a Xcode RayBanMiniMax.xcodeproj"
echo "  2. Xcode > File > Packages > Reset Package Caches"
echo "  3. Xcode > File > Packages > Resolve Package Versions"
echo "  4. Product > Clean Build Folder (⇧⌘K)"
echo "  5. Product > Build (⌘B)"
