#!/bin/bash
# Shared plumbing for relay's PreToolUse hooks.
#
# A hook that prints nothing lets the tool call through; relay_block prints a
# PreToolUse deny decision (the reason is shown to Claude) and exits.

MIN_LINES="${RELAY_MIN_LINES:-350}"
case "$MIN_LINES" in ''|*[!0-9]*) MIN_LINES=350 ;; esac

# Usage: relay_line_count <file>
relay_line_count() {
  wc -l < "$1" 2>/dev/null | tr -d ' ' || echo 0
}

# Usage: relay_is_binary <file>
# Images, PDFs and other binaries: wc -l counts stray newline bytes, not lines
relay_is_binary() {
  [ "$(file -b --mime-encoding "$1" 2>/dev/null)" = "binary" ]
}

# Usage: relay_block <reason>
relay_block() {
  jq -n --arg reason "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }}'
  exit 0
}
