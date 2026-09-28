#!/usr/bin/env bash
#
# Runs the unit tests: ./test.sh
#
# With Xcode installed this is just `swift test`. The Command Line Tools ship the
# Swift Testing framework too, but outside the default search paths, so it has to
# be pointed at explicitly - and at macOS 14, the oldest it was built for.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

args=()
if [[ "$(xcode-select -p)" == */CommandLineTools ]]; then
    DEV="$(xcode-select -p)/Library/Developer"
    FRAMEWORKS="$DEV/Frameworks"
    args+=(
        -Xswiftc -target -Xswiftc "$(uname -m)-apple-macos14.0"
        -Xswiftc -F -Xswiftc "$FRAMEWORKS"
        -Xlinker -F -Xlinker "$FRAMEWORKS"
        -Xlinker -rpath -Xlinker "$FRAMEWORKS"
        -Xlinker -rpath -Xlinker "$DEV/usr/lib"
    )
fi

swift test --package-path "$ROOT" ${args[@]+"${args[@]}"} "$@"
