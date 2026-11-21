#!/usr/bin/env bash
# Builds Debug and renders every state with fake data into qa/.
set -euo pipefail
cd "$(dirname "$0")/../Tally"
D="$HOME/Library/Developer/Xcode/DerivedData/TallyDev"
xcodegen >/dev/null
xcodebuild -scheme Tally -configuration Debug -derivedDataPath "$D" -quiet build
rm -f ../qa/*.png
"$D/Build/Products/Debug/Tally.app/Contents/MacOS/Tally" -qa ../qa
