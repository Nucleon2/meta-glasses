#!/usr/bin/env bash
#
# scripts/clean-rebuild.sh
#
# Wipes all stale state for the RayBan AI project so a clean build picks
# up the current package URL. The "Authentication failed" SPM error from
# an outdated package URL can be cached in three places:
#
#   1. Xcode's DerivedData for this project
#   2. SPM's global cache (~/Library/Caches/org.swift.swiftpm/)
#   3. The per-user xcuserdata (e.g. UserInterfaceState.xcuserstate
#      caches the "Recent Issues" panel that shows the stale error)
#
# This script wipes all three. Run it when SPM errors look stale.
#
# After running, you MUST also:
#   1. Quit Xcode completely (⌘Q — closing the window is not enough)
#   2. Reopen:  open -a Xcode RayBanMiniMax.xcodeproj
#   3. Product → Clean Build Folder (⇧⌘K)
#   4. Product → Build (⌘B)
#

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 1. Wiping project-local SPM artifacts"
rm -rf .build .swiftpm
find . -maxdepth 3 -name "Package.resolved" -not -path "./.git/*" -delete 2>/dev/null || true

echo "==> 2. Wiping xcuserdata (this is where the 'Recent Issues' panel caches)"
rm -rf RayBanMiniMax.xcodeproj/xcuserdata/ 2>/dev/null || true
rm -rf RayBanMiniMax.xcodeproj/project.xcworkspace/xcuserdata/ 2>/dev/null || true
rm -rf RayBanMiniMax.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/ 2>/dev/null || true

echo "==> 3. Wiping Xcode DerivedData for this project"
for DD in ~/Library/Developer/Xcode/DerivedData/RayBanMiniMax-*; do
  if [ -d "$DD" ]; then
    echo "    removing $DD"
    rm -rf "$DD"
  fi
done

echo "==> 4. Wiping SPM global cache (forces re-fetch of package metadata)"
for d in manifests package-metadata repositories; do
  if [ -d ~/Library/Caches/org.swift.swiftpm/$d ]; then
    echo "    removing ~/Library/Caches/org.swift.swiftpm/$d"
    rm -rf ~/Library/Caches/org.swift.swiftpm/$d
  fi
done
rm -f ~/Library/Caches/org.swift.swiftpm/package-collection.db*

echo "==> 5. Regenerating Xcode project from project.yml"
xcodegen generate

echo ""
echo "================================================================"
echo "  Done. Now do the following:"
echo "================================================================"
echo "  1. QUIT Xcode completely (⌘Q) — closing the window is not enough"
echo "  2. open -a Xcode RayBanMiniMax.xcodeproj"
echo "  3. Wait for Xcode to finish indexing"
echo "  4. Product → Clean Build Folder (⇧⌘K)"
echo "  5. Product → Build (⌘B)"
echo ""
echo "  The first build will take a few minutes because SPM needs to"
echo "  re-download the MetaWearables SDK (facebook/meta-wearables-dat-ios @ 0.8.0)."
