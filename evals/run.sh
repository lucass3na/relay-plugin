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

make_file() {
  local lines="$1" path="$2"
  if [ -z "$lines" ] || [ "$lines" = "null" ]; then
    return
  fi
  seq 1 "$lines" > "$path"
}

run_read_hook_case() {
  local case_json="$1"
  local name lines expect reason_contains file_path input result decision reason ok=1

  name=$(echo "$case_json" | jq -r '.name')
  lines=$(echo "$case_json" | jq -r '.file_lines')
  expect=$(echo "$case_json" | jq -r '.expect')
  reason_contains=$(echo "$case_json" | jq -r '.reason_contains // empty')

  file_path=$(echo "$case_json" | jq -r '.tool_input.file_path // empty')
  if [ -z "$file_path" ] && [ "$lines" != "null" ]; then
    file_path="$WORKDIR/$(echo "$name" | tr -c 'a-zA-Z0-9' '_').txt"
    make_file "$lines" "$file_path"
  fi

  input=$(echo "$case_json" | jq --arg fp "$file_path" \
    '.tool_input + (if (.tool_input | has("file_path")) then {} else {file_path: $fp} end)' \
    | jq '{tool_input: .}')

  env_json=$(echo "$case_json" | jq -c '.env // {}')
  result=$(env $(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null) \
    bash -c "echo '$input' | '$PLUGIN_ROOT/hooks/check-file-size'")

  decision=$(echo "$result" | jq -r '.decision // empty')
  reason=$(echo "$result" | jq -r '.reason // empty')

  [ "$decision" = "$expect" ] || ok=0
  if [ -n "$reason_contains" ]; then
    echo "$reason" | grep -q "$reason_contains" || ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [check-file-size] $name — expected decision=$expect, got: $result"
  fi
}

run_bash_hook_case() {
  local case_json="$1"
  local name lines expect reason_contains command file_path input result decision reason ok=1

  name=$(echo "$case_json" | jq -r '.name')
  lines=$(echo "$case_json" | jq -r '.file_lines')
  expect=$(echo "$case_json" | jq -r '.expect')
  reason_contains=$(echo "$case_json" | jq -r '.reason_contains // empty')
  command=$(echo "$case_json" | jq -r '.command')

  if [[ "$command" == *"{file}"* ]]; then
    file_path="$WORKDIR/$(echo "$name" | tr -c 'a-zA-Z0-9' '_').txt"
    make_file "$lines" "$file_path"
    command="${command//\{file\}/$file_path}"
  fi

  input=$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')

  env_json=$(echo "$case_json" | jq -c '.env // {}')
  result=$(env $(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null) \
    bash -c "echo '$input' | '$PLUGIN_ROOT/hooks/check-bash-read'")

  decision=$(echo "$result" | jq -r '.decision // empty')
  reason=$(echo "$result" | jq -r '.reason // empty')

  [ "$decision" = "$expect" ] || ok=0
  if [ -n "$reason_contains" ]; then
    echo "$reason" | grep -q "$reason_contains" || ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [check-bash-read] $name — expected decision=$expect, got: $result"
  fi
}

run_hooks() {
  echo "== check-file-size =="
  local n; n=$(jq '.cases | length' "$DIR/hook-evals.json")
  for i in $(seq 0 $((n - 1))); do
    run_read_hook_case "$(jq -c ".cases[$i]" "$DIR/hook-evals.json")"
  done

  echo "== check-bash-read =="
  n=$(jq '.cases | length' "$DIR/bash-hook-evals.json")
  for i in $(seq 0 $((n - 1))); do
    run_bash_hook_case "$(jq -c ".cases[$i]" "$DIR/bash-hook-evals.json")"
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
