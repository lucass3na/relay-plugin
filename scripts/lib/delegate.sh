#!/bin/bash
# Shared transport for relay's delegation scripts.
#
# Goes straight through the `claude` CLI's own headless mode (`claude -p`), so it
# needs no extra service and reuses whatever auth Claude Code already has on this
# machine. Each call is a one-shot text-in/text-out completion:
#   --tools ""                 no tool access — the worker can't call Read/Bash
#   --system-prompt "<text>"   full override, not append: replaces Claude Code's
#                               own ~6.4k-token agent prompt with a short,
#                               purpose-built instruction (this is most of the
#                               saving — see README benchmarks)
#   --no-session-persistence   don't write this ephemeral turn to disk
#   --strict-mcp-config        ignore any configured MCP servers
#   --setting-sources ""       ignore user/project CLAUDE.md, settings, and
#                               hooks (including relay's own) for this call
#
# The prompt is piped over stdin, not passed as an argv string, so there is no
# ARG_MAX ceiling on how much can be sent in one call.

if [ -z "${RELAY_MAX_INPUT_CHARS:-}" ]; then
  RELAY_MAX_INPUT_CHARS=600000
fi
RELAY_TIMEOUT_SECONDS="${RELAY_TIMEOUT_SECONDS:-180}"
RELAY_MODEL="${RELAY_MODEL:-claude-haiku-4-5-20251001}"
RELAY_EFFORT="${RELAY_EFFORT:-low}"

# mktemp with cleanup on script exit. Usage: relay_tmpfile <varname>
RELAY_TMPFILES=()
relay_tmpfile() {
  local f
  f=$(mktemp) || return 1
  RELAY_TMPFILES+=("$f")
  trap 'rm -f "${RELAY_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

relay_preflight() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing=" jq"
  command -v claude >/dev/null 2>&1 || missing="$missing claude"

  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "  jq     — brew install jq" >&2
    echo "  claude — https://claude.com/claude-code" >&2
    return 1
  fi
  return 0
}

# Runs one ephemeral headless turn and prints the answer to stdout.
#   $1 system prompt text (defines the worker's role — bulk-reader, code-writer, ...)
#   $2 file holding the message (the corpus + question/spec)
relay_invoke() {
  local system_prompt="$1" message_file="$2"
  local chars runner response rc mode

  chars=$(wc -c < "$message_file" | tr -d ' ')
  if [ "$chars" -gt "$RELAY_MAX_INPUT_CHARS" ]; then
    echo "Error: input is $chars chars, over the $RELAY_MAX_INPUT_CHARS char limit." >&2
    echo "Send fewer or smaller files, or raise RELAY_MAX_INPUT_CHARS if there is headroom." >&2
    return 1
  fi

  runner=()
  if command -v timeout >/dev/null 2>&1; then
    runner=(timeout "${RELAY_TIMEOUT_SECONDS}s")
  elif command -v gtimeout >/dev/null 2>&1; then
    runner=(gtimeout "${RELAY_TIMEOUT_SECONDS}s")
  fi
  # Without timeout/gtimeout on PATH, the call runs unbounded — that's the
  # documented degradation on a stock macOS with no GNU coreutils installed.

  response=$("${runner[@]}" claude -p \
    --model "$RELAY_MODEL" \
    --effort "$RELAY_EFFORT" \
    --output-format json \
    --tools "" \
    --no-session-persistence \
    --strict-mcp-config \
    --setting-sources "" \
    --system-prompt "$system_prompt" \
    < "$message_file")
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "Error: relay invocation exceeded ${RELAY_TIMEOUT_SECONDS}s." >&2
    echo "Raise RELAY_TIMEOUT_SECONDS or split the work into smaller calls." >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "Error: claude -p exited with status $rc:" >&2
    printf '%s\n' "$response" >&2
    return 1
  fi
  if ! printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
    echo "Error: claude -p returned unparseable output:" >&2
    printf '%s\n' "$response" >&2
    return 1
  fi

  if [ "$(printf '%s' "$response" | jq -r '.is_error // false')" = "true" ]; then
    echo "Error: $(printf '%s' "$response" | jq -r '.result // "unknown error"')" >&2
    return 1
  fi

  printf '%s' "$response" | jq -r '.result // empty'

  local cost model_used
  cost=$(printf '%s' "$response" | jq -r '.total_cost_usd // empty')
  model_used=$(printf '%s' "$response" | jq -r '.modelUsage | keys[0] // empty' 2>/dev/null)
  echo "[relay: delegated to ${model_used:-$RELAY_MODEL} | cost \$${cost:-?}]" >&2
}
