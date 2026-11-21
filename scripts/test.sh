#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tally-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
flags=()
if [[ ${CODEX_SANDBOX:-} == seatbelt ]]; then flags+=(-Xfrontend -disable-sandbox); fi
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -module-cache-path "$TEST_DIR/modules" \
    ${flags[@]+"${flags[@]}"} Tally/Sources/Core/*.swift tests/TallyTests.swift tests/IntroFlowTests.swift -o "$TEST_DIR/t"
"$TEST_DIR/t" "$PWD/tests/Fixtures"
