#!/bin/bash
# Ralph Wiggum: Stop helper
#
# Stops the active Ralph loop/agent for a workspace by consulting the runtime
# state and sequential lock, then tears down the tracked process tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

WORKSPACE="${1:-.}"
REASON="${2:-Stopped from dashboard}"
SOURCE="${3:-dashboard}"

if [[ "$WORKSPACE" == "." ]]; then
  WORKSPACE="$(pwd)"
else
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
fi

stop_workspace_runtime "$WORKSPACE" "$REASON" "$SOURCE"
