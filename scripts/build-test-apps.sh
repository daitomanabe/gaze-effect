#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"${SCRIPT_DIR}/build-camera-test-app.sh"
"${SCRIPT_DIR}/build-offline-renderer-app.sh"
