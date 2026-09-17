#!/bin/bash
# Host-agnostic hook I/O for Claude Code, Codex and Cursor.
#
# The three hosts disagree on both ends of a hook:
#
#   input   Claude Code / Codex  {"tool_input": {"file_path": …, "command": …}}
#           Cursor preToolUse    {"tool_input": {…}}          (same shape)
#           Cursor beforeReadFile        {"file_path": …}     (top level)
#           Cursor beforeShellExecution  {"command": …}       (top level)
#
#   block   Claude Code (legacy) {"decision": "block", "reason": …}
#           Claude/Codex (new)   {"hookSpecificOutput": {"permissionDecision": "deny", …}}
#           Cursor               {"permission": "deny", "agent_message": …}
#
# Rather than detect the host -- which nothing reliably tells us -- we read
# whichever input field is present and emit the union of all three output
# shapes. Unknown keys are ignored by each host.
#
# The belt to that braces is the exit code: 2 means "block" on all three hosts,
# so enforcement holds even if a host rejects every JSON shape it does not know.

# hook_field <json> <field>  -- nested form first, then Cursor's top-level form.
hook_field() {
  printf '%s' "$1" | jq -r --arg f "$2" '.tool_input[$f] // .[$f] // empty' 2>/dev/null
}

hook_allow() {
  echo '{"decision": "allow", "permission": "allow", "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}'
  exit 0
}

# hook_block <reason>
hook_block() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    decision: "block",
    reason: $r,
    permission: "deny",
    user_message: $r,
    agent_message: $r,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  # Exit 2 is the one contract all three hosts document as blocking.
  printf '%s\n' "$reason" >&2
  exit 2
}

# Line threshold above which a read is considered bulk.
hook_min_lines() {
  local n="${SIPHON_MIN_LINES:-350}"
  case "$n" in ''|*[!0-9]*) n=350 ;; esac
  printf '%s' "$n"
}

# A small explicit count (head -n 5) is a peek, not a bulk read.
hook_peek_lines() {
  local n="${SIPHON_PEEK_LINES:-50}"
  case "$n" in ''|*[!0-9]*) n=50 ;; esac
  printf '%s' "$n"
}

hook_line_count() {
  wc -l < "$1" 2>/dev/null | tr -d ' '
}
