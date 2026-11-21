#!/usr/bin/env bash
# Builds Tally (Release, signed with the local certificate) and installs it in /Applications.
#   ./scripts/install.sh            build, install, start
#   NO_OPEN=1 ./scripts/install.sh  build and install only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData/TallyRel"
BUILT="${DERIVED}/Build/Products/Release/Tally.app"
TARGET="/Applications/Tally.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

# Erik's local identity when present; ad-hoc signing for everyone else.
IDENTITY="Erik Local Signing"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"

echo "Building (Release)..."
cd "${REPO_ROOT}/Tally"
xcodegen >/dev/null
xcodebuild -scheme Tally -configuration Release -derivedDataPath "${DERIVED}" CODE_SIGN_IDENTITY="${IDENTITY}" -quiet build

echo "Quitting Tally..."
osascript -e 'tell application id "com.erikkirillov.Tally" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x Tally >/dev/null || break; sleep 1; done
pkill -x Tally 2>/dev/null || true

echo "Installing in ${TARGET}..."
rm -rf "${TARGET}"
ditto "${BUILT}" "${TARGET}"
"${LSREGISTER}" -u "${BUILT}" >/dev/null 2>&1 || true
"${LSREGISTER}" -f "${TARGET}" >/dev/null 2>&1 || true

if [ -z "${NO_OPEN:-}" ]; then open "${TARGET}"; echo "Tally is running from ${TARGET}."; else echo "Installed ${TARGET}."; fi
