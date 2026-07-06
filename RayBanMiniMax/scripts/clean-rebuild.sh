#!/usr/bin/env bash
#
# scripts/clean-rebuild.sh
# Wipes all SPM/Xcode caches for this project so a clean build picks up
# the current package URL. Run this if you see a stale "Authentication
# failed" or any other SPM error referencing an outdated package URL.
#
# After running this, you MUST also:
#   1. Open the project:  open -a Xcode RayBanMiniMax.xcodeproj
#   2. File → Packages → Reset Package Caches
#   3. Product → Clean Build Folder (⇧⌘K)
#   4. Product → Build (⌘B)
#

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 1. Wiping project-local SPM artifacts"
rm -rf .build .swiftpm
find . -maxdepth 3 -name "Package.resolved" -not -path "./.git/*" -delete 2>/dev/null || true
find . -name "*.xcworkspace" -not -path "./.git/*" -not -path "./RayBanMiniMax.xcodeproj/*" -exec rm -rf {} + 2>/dev/null || true

echo "==> 2. Wiping Xcode DerivedData for this project"
for DD in ~/Library/Developer/Xcode/DerivedData/RayBanMiniMax-*; do
  if [ -d "$DD" ]; then
    echo "    removing $DD"
    rm -rf "$DD"
  fi
done

echo "==> 3. Wiping SPM global cache (forces re-fetch of package metadata)"
for d in manifests package-metadata repositories; do
  if [ -d ~/Library/Caches/org.swift.swiftpm/$d ]; then
    echo "    removing ~/Library/Caches/org.swift.swiftpm/$d"
    rm -rf ~/Library/Caches/org.swift.swiftpm/$d
  fi
done
rm -f ~/Library/Caches/org.swift.swiftpm/package-collection.db*

echo "==> 4. Regenerating Xcode project from project.yml"
xcodegen generate

echo ""
echo "================================================================"
echo "  Done. Now do the following in Xcode:"
echo "================================================================"
echo "  1. open -a Xcode RayBanMiniMax.xcodeproj"
echo "  2. Wait for the project to open"
echo "  3. File → Packages → Reset Package Caches"
echo "  4. File → Packages → Resolve Package Versions"
echo "     (this should now successfully fetch facebook/meta-wearables-dat-ios)"
echo "  5. Product → Clean Build Folder (⇧⌘K)"
echo "  6. Product → Build (⌘B)"
echo ""
echo "  If the build still shows the old 'meta-quest/MetaWearables-SDK-iOS' error,"
echo "  it means Xcode is showing a STALE error. Quit Xcode (⌘Q) and reopen."
