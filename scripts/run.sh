#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/dist/拾光剪贴板.app"

if [[ ! -x "$APP_PATH/Contents/MacOS/ClipboardShelf" ]]; then
  "$PROJECT_ROOT/scripts/build-app.sh"
fi

if [[ "${1:-}" == "--demo" ]]; then
  open -n "$APP_PATH" --args "$@"
else
  open "$APP_PATH" --args "$@"
fi
