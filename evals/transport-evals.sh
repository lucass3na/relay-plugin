#!/bin/bash
# Exercises scripts/lib/delegate.sh's relay_invoke() against a stubbed `claude`
# binary, so parsing/error-handling can be tested with no live API calls.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$DIR")"
STUBDIR=$(mktemp -d)
trap 'rm -rf "$STUBDIR"' EXIT

PASS=0
FAIL=0

cat > "$STUBDIR/claude" <<'STUB'
#!/bin/bash
cat > /dev/null  # consume stdin
case "${CLAUDE_STUB_MODE:-success}" in
  success)
    echo '{"is_error": false, "result": "STUBBED_ANSWER", "total_cost_usd": 0.0012, "modelUsage": {"claude-haiku-4-5-20251001": {}}}'
    ;;
  is_error)
    echo '{"is_error": true, "result": "the mode blew up"}'
    ;;
  garbage)
    echo 'not json at all'
    ;;
  failexit)
    echo '{"error": "boom"}' >&2
    exit 1
    ;;
  hang)
    sleep 5
    echo '{"is_error": false, "result": "too late"}'
    ;;
esac
STUB
chmod +x "$STUBDIR/claude"

check() {
  local name="$1" expect_rc="$2" actual_rc="$3" stdout="$4" stderr="$5"
  local expect_stdout="${6:-}" expect_stderr_contains="${7:-}"
  local ok=1

  [ "$actual_rc" -eq "$expect_rc" ] || ok=0
  if [ -n "$expect_stdout" ]; then
    [ "$stdout" = "$expect_stdout" ] || ok=0
  fi
  if [ -n "$expect_stderr_contains" ]; then
    echo "$stderr" | grep -q "$expect_stderr_contains" || ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [transport] $name — rc=$actual_rc (expected $expect_rc), stdout=[$stdout], stderr=[$stderr]"
  fi
}

msg=$(mktemp)
echo "hello world" > "$msg"

# success
out=$(PATH="$STUBDIR:$PATH" CLAUDE_STUB_MODE=success bash -c \
  ". '$PLUGIN_ROOT/scripts/lib/delegate.sh'; relay_invoke 'sys' '$msg'" 2>/tmp/relay_eval_err)
rc=$?
check "success returns result text" 0 "$rc" "$out" "$(cat /tmp/relay_eval_err)" "STUBBED_ANSWER"

# is_error from the model
out=$(PATH="$STUBDIR:$PATH" CLAUDE_STUB_MODE=is_error bash -c \
  ". '$PLUGIN_ROOT/scripts/lib/delegate.sh'; relay_invoke 'sys' '$msg'" 2>/tmp/relay_eval_err)
rc=$?
check "is_error surfaces as failure" 1 "$rc" "$out" "$(cat /tmp/relay_eval_err)" "" "mode blew up"

# garbage / unparseable output
out=$(PATH="$STUBDIR:$PATH" CLAUDE_STUB_MODE=garbage bash -c \
  ". '$PLUGIN_ROOT/scripts/lib/delegate.sh'; relay_invoke 'sys' '$msg'" 2>/tmp/relay_eval_err)
rc=$?
check "unparseable output fails" 1 "$rc" "$out" "$(cat /tmp/relay_eval_err)" "" "unparseable"

# non-zero exit from claude
out=$(PATH="$STUBDIR:$PATH" CLAUDE_STUB_MODE=failexit bash -c \
  ". '$PLUGIN_ROOT/scripts/lib/delegate.sh'; relay_invoke 'sys' '$msg'" 2>/tmp/relay_eval_err)
rc=$?
check "non-zero exit fails" 1 "$rc" "$out" "$(cat /tmp/relay_eval_err)" "" "exited with status"

# timeout, if timeout/gtimeout is available
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  out=$(PATH="$STUBDIR:$PATH" CLAUDE_STUB_MODE=hang RELAY_TIMEOUT_SECONDS=1 bash -c \
    ". '$PLUGIN_ROOT/scripts/lib/delegate.sh'; relay_invoke 'sys' '$msg'" 2>/tmp/relay_eval_err)
  rc=$?
  check "hang past timeout fails with timeout message" 1 "$rc" "$out" "$(cat /tmp/relay_eval_err)" "" "exceeded"
else
  echo "SKIP timeout case — no timeout/gtimeout on PATH"
fi

# oversized input, rejected before ever invoking claude
big=$(mktemp)
head -c 100 /dev/zero > "$big"
out=$(PATH="$STUBDIR:$PATH" RELAY_MAX_INPUT_CHARS=10 bash -c \
  ". '$PLUGIN_ROOT/scripts/lib/delegate.sh'; relay_invoke 'sys' '$big'" 2>/tmp/relay_eval_err)
rc=$?
check "oversized input rejected without calling claude" 1 "$rc" "$out" "$(cat /tmp/relay_eval_err)" "" "over the"
rm -f "$big"

rm -f "$msg" /tmp/relay_eval_err

echo "Transport passed: $PASS  Transport failed: $FAIL"
[ "$FAIL" -eq 0 ]
