#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR=${OPENCODE_CONFIG_DIR:-"$HOME/.config/opencode"}

COMMAND_SOURCE="$SOURCE_DIR/.opencode/commands/stats.md"
TOOL_SOURCE="$SOURCE_DIR/.opencode/tools/session_stats.ts"
SCRIPT_SOURCE="$SOURCE_DIR/session-stats.sh"

for source in "$COMMAND_SOURCE" "$TOOL_SOURCE" "$SCRIPT_SOURCE"; do
  if [[ ! -f "$source" ]]; then
    echo "Error: required file not found: $source" >&2
    exit 1
  fi
done

mkdir -p "$CONFIG_DIR/commands" "$CONFIG_DIR/tools"

cp "$COMMAND_SOURCE" "$CONFIG_DIR/commands/stats.md"
cp "$TOOL_SOURCE" "$CONFIG_DIR/tools/session_stats.ts"
cp "$SCRIPT_SOURCE" "$CONFIG_DIR/session-stats.sh"
chmod +x "$CONFIG_DIR/session-stats.sh"

cat <<EOF
Installed opencode session stats globally:
  $CONFIG_DIR/commands/stats.md
  $CONFIG_DIR/tools/session_stats.ts
  $CONFIG_DIR/session-stats.sh

Restart opencode, then run /stats from the TUI.
EOF
