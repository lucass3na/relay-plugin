#!/bin/bash
# Runs relay's hook + transport evals. No live claude/API calls are made.
#
#   bash evals/run.sh              hook + transport evals
#   bash evals/run.sh --transport  transport evals only
#   bash evals/run.sh --hooks      hook evals only

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$DIR")"
PASS=0
FAIL=0
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Usage: make_file <lines> <path> [binary]
make_file() {
  local lines="$1" path="$2" binary="${3:-false}"
  if [ -z "$lines" ] || [ "$lines" = "null" ]; then
    return
  fi
  if [ "$binary" = "true" ]; then
    # NUL bytes make it binary to `file`, the newlines make wc -l count high
    printf '\0\n%.0s' $(seq 1 "$lines") > "$path"
  else
    seq 1 "$lines" > "$path"
  fi
}

# Usage: run_hook_case <hook> <case_json>
run_hook_case() {
  local hook="$1" case_json="$2"
  local name id lines expect reason_contains file_path command input repeat env_args result decision reason ok=1

  name=$(echo "$case_json" | jq -r '.name')
  id=$(echo "$name" | tr -c 'a-zA-Z0-9' '_')
  lines=$(echo "$case_json" | jq -r '.file_lines')
  expect=$(echo "$case_json" | jq -r '.expect')
  reason_contains=$(echo "$case_json" | jq -r '.reason_contains // empty')

  file_path="$WORKDIR/$id.txt"
  make_file "$lines" "$file_path" "$(echo "$case_json" | jq -r '.binary // false')"

  # Each case gets its own session, so per-session read budgets don't leak between cases
  case "$hook" in
    check-file-size)
      input=$(echo "$case_json" | jq --arg fp "$file_path" --arg sid "$id" \
        '{session_id: $sid, tool_input: ({file_path: $fp} + .tool_input)}') ;;
    check-bash-read)
      command=$(echo "$case_json" | jq -r '.command')
      input=$(jq -n --arg cmd "${command//\{file\}/$file_path}" --arg sid "$id" \
        '{session_id: $sid, tool_input: {command: $cmd}}') ;;
  esac

  # "repeat": N sends the same call N times (chunked reading); the last decision is checked
  repeat=$(echo "$case_json" | jq -r '.repeat // 1')
  env_args=$(echo "$case_json" | jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"')
  for _ in $(seq 1 "$repeat"); do
    # shellcheck disable=SC2086 # env_args is a list of KEY=VALUE words
    result=$(printf '%s' "$input" | env RELAY_STATE_DIR="$WORKDIR/state" $env_args "$PLUGIN_ROOT/hooks/$hook")
  done

  decision=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  # No output means the hook has no objection, so the tool call proceeds
  [ -z "$result" ] && decision="allow"
  reason=$(echo "$result" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')

  [ "$decision" = "$expect" ] || ok=0
  if [ -n "$reason_contains" ]; then
    echo "$reason" | grep -q "$reason_contains" || ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [$hook] $name — expected decision=$expect, got: $result"
  fi
}

run_hooks() {
  local evals hook n i
  for evals in "$DIR/hook-evals.json" "$DIR/bash-hook-evals.json"; do
    hook=$(jq -r '.hook' "$evals")
    echo "== $hook =="
    n=$(jq '.cases | length' "$evals")
    for i in $(seq 0 $((n - 1))); do
      run_hook_case "$hook" "$(jq -c ".cases[$i]" "$evals")"
    done
  done
}

run_transport() {
  echo "== transport (stubbed claude) =="
  bash "$DIR/transport-evals.sh" || FAIL=$((FAIL + 1))
}

MODE="${1:-all}"
case "$MODE" in
  --hooks)     run_hooks ;;
  --transport) run_transport ;;
  *)           run_hooks; run_transport ;;
esac

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
