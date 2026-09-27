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
# Blocks, unless the Gemini backend cannot serve the delegation this redirects
# to -- see "Fail-open" at the foot of this file.
hook_block() {
  local reason="$1"
  if ! hook_backend_ok; then
    hook_allow_warn "siphon: allowing this read. ${reason} The Gemini backend cannot serve that delegation right now (model \"${SIPHON_MODEL:-gemini-3.8-flash}\": no key, unreachable, retired or rate-limited), so blocking would only cost you the read. Run siphon:doctor. Set SIPHON_HOOK_FAIL_OPEN=0 to block regardless."
  fi
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

# -- Fail-open --------------------------------------------------------------
#
# The gate redirects a large read to bulk-reader, which calls Gemini. When that
# backend cannot serve the read, blocking replaces a read the agent CAN do with
# a delegation it CANNOT, and the read happens manually anyway: slower, and into
# context regardless. Measured 2026-09-23: the shipped default model had been
# retired (404 on generateContent) while both hooks went on mandating the skill
# that could not run, for a whole session.
#
# So: probe before blocking, and allow with a warning when the backend is down.
# Set SIPHON_HOOK_FAIL_OPEN=0 to restore unconditional blocking, which is what
# evals/run.sh does to stay hermetic.
#
# The probe calls generateContent, NOT the metadata endpoint: a retired model
# still answers metadata with 200 and refuses to generate. That is exactly the
# failure this exists to catch, and why doctor's own probe used to miss it.
# Cost is ~3 tokens, once per SIPHON_PROBE_TTL_SECONDS (default 600) while
# healthy, or per SIPHON_PROBE_DOWN_TTL_SECONDS (default 60) while failing.

hook_allow_warn() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    decision: "allow",
    permission: "allow",
    systemMessage: $r,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: $r
    }
  }'
  printf '%s\n' "$reason" >&2
  exit 0
}

# 0 = the backend can serve a delegated read; 1 = it cannot.
hook_backend_ok() {
  case "${SIPHON_HOOK_FAIL_OPEN:-1}" in
    0|false|no) return 0 ;;   # fail-open disabled: always "reachable", always block
  esac

  local model="${SIPHON_MODEL:-gemini-3.8-flash}"
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/siphon"
  local cache="$dir/probe-${model}"
  local ttl="${SIPHON_PROBE_TTL_SECONDS:-600}"
  local down_ttl="${SIPHON_PROBE_DOWN_TTL_SECONDS:-60}"
  local now mtime cached age

  # A healthy result is cached for the full TTL; a failure only briefly, so the
  # gate comes back within a minute of the backend recovering. That matters most
  # for 429, where the free-tier per-minute window clears in ~20s.
  if [ -f "$cache" ]; then
    now=$(date +%s)
    mtime=$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null)
    cached=$(cat "$cache" 2>/dev/null)
    if [ -n "$mtime" ]; then
      age=$((now - mtime))
      case "$cached" in
        ok)   [ "$age" -lt "$ttl" ]      && return 0 ;;
        down) [ "$age" -lt "$down_ttl" ] && return 1 ;;
      esac
    fi
  fi

  mkdir -p "$dir" 2>/dev/null

  local key="" keyfile="${GEMINI_API_KEY_FILE:-$HOME/.config/siphon/gemini.key}"
  if [ -n "${GEMINI_API_KEY:-}" ]; then key="$GEMINI_API_KEY"
  elif [ -r "$keyfile" ]; then key=$(head -n1 "$keyfile" 2>/dev/null); fi
  key=$(printf '%s' "$key" | tr -d '[:space:]')
  if [ -z "$key" ]; then printf 'down' > "$cache" 2>/dev/null; return 1; fi

  # The key goes through --config, never argv, matching scripts/lib/gemini.sh.
  local base="${SIPHON_API_BASE:-https://generativelanguage.googleapis.com/v1beta}"
  local status
  status=$(printf 'header = "x-goog-api-key: %s"\n' "$key" | curl -sS --config - \
    -o /dev/null -w '%{http_code}' \
    --max-time "${SIPHON_PROBE_TIMEOUT_SECONDS:-5}" \
    -H 'Content-Type: application/json' -X POST \
    -d '{"contents":[{"parts":[{"text":"x"}]}],"generationConfig":{"maxOutputTokens":1,"thinkingConfig":{"thinkingBudget":0}}}' \
    "$base/models/${model}:generateContent" 2>/dev/null)

  case "$status" in
    # 429 counts as down on purpose: the backend is up, but it cannot serve a
    # bulk read right now, which is the only thing the block is redirecting to.
    200) printf 'ok'   > "$cache" 2>/dev/null; return 0 ;;
    *)   printf 'down' > "$cache" 2>/dev/null; return 1 ;;
  esac
}
