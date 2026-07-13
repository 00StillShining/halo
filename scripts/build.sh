#!/usr/bin/env bash
# halo build helper — Brief §10 functional gate.
# Usage: scripts/build.sh [build|test|run|clean]
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-build}"
SCHEME="Halo"
DEST='platform=macOS'

case "$ACTION" in
  build)
    xcodebuild -scheme "$SCHEME" -destination "$DEST" -configuration Debug build
    ;;
  test)
    xcodebuild -scheme "$SCHEME" -destination "$DEST" test
    ;;
  run)
    xcodebuild -scheme "$SCHEME" -destination "$DEST" -configuration Debug build
    APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 4 -name Halo.app -path '*Debug*' 2>/dev/null | head -1)
    echo "Launching $APP"
    open "$APP"
    ;;
  clean)
    xcodebuild -scheme "$SCHEME" clean
    ;;
  *)
    echo "unknown action: $ACTION (build|test|run|clean)"; exit 1
    ;;
esac
