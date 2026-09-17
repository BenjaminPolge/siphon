#!/bin/bash
# Host-format evals for the hooks.
#
# The hook suites assert the decision; this one asserts the wire format. Each
# host reads a different key out of the same response, so a change that keeps
# Claude Code working can silently disable enforcement on Codex or Cursor.
#
# Prints PASS/FAIL lines plus a "## <pass> <fail>" trailer for run.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR="$(mktemp -d)"

big="$WORKDIR/big.txt";   seq 1 600 > "$big"
small="$WORKDIR/small.txt"; seq 1 10 > "$small"

PASSED=0
FAILED=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$4"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

run_hook() { printf '%s' "$2" | bash "$PLUGIN_DIR/hooks/$1" 2>/dev/null; }
hook_status() { printf '%s' "$2" | bash "$PLUGIN_DIR/hooks/$1" >/dev/null 2>&1; echo $?; }

block_in=$(jq -nc --arg p "$big"   '{tool_input:{file_path:$p}}')
allow_in=$(jq -nc --arg p "$small" '{tool_input:{file_path:$p}}')
cursor_in=$(jq -nc --arg p "$big"  '{file_path:$p}')
bash_in=$(jq -nc --arg p "$big"    '{tool_input:{command:("cat " + $p)}}')

out=$(run_hook check-file-size "$block_in")

check "claude-legacy-block" "block" "$(printf '%s' "$out" | jq -r '.decision')" \
  "Claude Code's decision/reason shape"
check "claude-new-block" "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" \
  "the hookSpecificOutput shape Codex documents"
check "cursor-block" "deny" "$(printf '%s' "$out" | jq -r '.permission')" \
  "Cursor's permission shape"
check "cursor-agent-message" "0" "$(printf '%s' "$out" | jq -r '.agent_message | length == 0 | if . then 1 else 0 end')" \
  "Cursor needs a message to hand back to the agent"
check "reason-is-actionable" "0" "$(printf '%s' "$out" | jq -r '.reason | test("bulk-reader") | if . then 0 else 1 end')" \
  "the block names the way out, not just the refusal"

check "block-exit-code" "2" "$(hook_status check-file-size "$block_in")" \
  "exit 2 is the one contract all three hosts honour"
check "allow-exit-code" "0" "$(hook_status check-file-size "$allow_in")" \
  "an allowed read exits cleanly"

out=$(run_hook check-file-size "$allow_in")
check "allow-all-hosts" "allow allow allow" \
  "$(printf '%s' "$out" | jq -r '[.decision, .permission, .hookSpecificOutput.permissionDecision] | join(" ")')" \
  "an allow is expressed in all three dialects too"

check "cursor-top-level-input" "block" "$(run_hook check-file-size "$cursor_in" | jq -r '.decision')" \
  "Cursor sends file_path at the top level, not under tool_input"

out=$(run_hook check-bash-read "$bash_in")
check "bash-hook-block-shapes" "block deny deny" \
  "$(printf '%s' "$out" | jq -r '[.decision, .permission, .hookSpecificOutput.permissionDecision] | join(" ")')" \
  "the shell gate speaks the same three dialects"
check "bash-hook-exit-code" "2" "$(hook_status check-bash-read "$bash_in")" \
  "and blocks with the universal exit code"

rm -rf "$WORKDIR"
echo "## $PASSED $FAILED"
[ "$FAILED" -eq 0 ]
