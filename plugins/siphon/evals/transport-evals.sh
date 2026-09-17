#!/bin/bash
# Transport evals for scripts/lib/gemini.sh.
#
# Runs against a stubbed HTTP transport, so these need no API key, no network
# and no tokens — the benchmark suite covers the real round trip.
#
# Prints one PASS/FAIL line per check plus a machine-readable "## <pass> <fail>"
# trailer for run.sh. Runs as its own process so the stub cannot leak into the
# benchmark suite.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
CAPTURED_BODY="$WORKDIR/captured-body.json"
CAPTURED_MODEL="$WORKDIR/captured-model"
CAPTURED_ARGS="$WORKDIR/captured-args"

# A key must exist for siphon_api_key to succeed, but it must never reach argv.
export GEMINI_API_KEY="test-key-do-not-use"

# shellcheck source=../scripts/lib/gemini.sh
. "$PLUGIN_DIR/scripts/lib/gemini.sh"

# Stub the seam: record what it was handed, return canned output. Driven by
# variables so per-case subshells only set STUB_*, instead of redefining the
# function each time.
STUB_RESPONSE='{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"- first line\n- second line"}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5}}'
STUB_STATUS=200
STUB_CURL_RC=0

siphon_transport() {
  local body_file="$1" out_file="$2" model="$3"
  cat "$body_file" > "$CAPTURED_BODY"
  printf '%s' "$model" > "$CAPTURED_MODEL"
  printf '%s\n' "$@" > "$CAPTURED_ARGS"
  printf '%s' "$STUB_RESPONSE" > "$out_file"
  printf '%s' "$STUB_STATUS"
  return "$STUB_CURL_RC"
}

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

body_field() { jq -r "$1" "$CAPTURED_BODY" 2>/dev/null; }

message_file="$WORKDIR/message.txt"
printf 'line one\nline two\n' > "$message_file"

# ── Invocation ──

answer=$(siphon_invoke bulk-reader "$message_file" 2>/dev/null)
check "answer-text-extracted" "$(printf -- '- first line\n- second line')" "$answer" \
  "reads the candidate text instead of scraping stdout"

check "message-sent" "$(printf 'line one\nline two\n')" "$(body_field '.contents[0].parts[0].text')" \
  "message survives the round trip verbatim"

check "system-instruction-sent" "$(cat "$PLUGIN_DIR/prompts/bulk-reader.md")" \
  "$(body_field '.systemInstruction.parts[0].text')" \
  "the mode is applied by sending its instructions, not by naming it"

check "temperature-sent" "0.2" "$(body_field '.generationConfig.temperature')" \
  "temperature comes from prompts/mode.json"

check "thinking-disabled-by-default" "0" "$(body_field '.generationConfig.thinkingConfig.thinkingBudget')" \
  "thinking tokens are billed as output and share the answer's budget"

check "no-history-sent" "1" "$(body_field '.contents | length')" \
  "every delegation is one shot"

check "default-model-used" "gemini-2.5-flash" "$(cat "$CAPTURED_MODEL")" \
  "the documented default model"

# ── Security ──

check "no-key-in-body" "false" "$(body_field 'has("key") or has("apiKey")')" \
  "the key is a header, never part of the payload"

check "api-key-never-in-argv" "0" "$(grep -c "$GEMINI_API_KEY" "$CAPTURED_ARGS")" \
  "the key must never reach argv, where ps would expose it"

# Checked against preflight, not invoke: the stubbed seam never reaches the key.
( unset GEMINI_API_KEY; GEMINI_API_KEY_FILE=/nonexistent/key \
    siphon_preflight >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"GEMINI_API_KEY"*"aistudio.google.com"*) exit 0 ;; *) exit 1 ;; esac )
check "key-missing-explained" "0" "$?" "the error names the variable and where to get a key"

keyfile="$WORKDIR/key"; printf 'file-key\n' > "$keyfile"
actual=$( unset GEMINI_API_KEY; GEMINI_API_KEY_FILE="$keyfile" bash -c '. "$1"; siphon_api_key' _ "$PLUGIN_DIR/scripts/lib/gemini.sh" )
check "key-from-file" "file-key" "$actual" "a key file is read and its newline trimmed"

# ── Model resolution ──

( SIPHON_MODEL=gemini-2.5-flash-lite siphon_invoke bulk-reader "$message_file" >/dev/null 2>&1 )
check "global-model-override" "gemini-2.5-flash-lite" "$(cat "$CAPTURED_MODEL")" \
  "SIPHON_MODEL overrides the default"

( SIPHON_MODEL=gemini-2.5-flash-lite SIPHON_BULK_READER_MODEL=gemini-2.5-pro \
    siphon_invoke bulk-reader "$message_file" >/dev/null 2>&1 )
check "per-mode-model-override" "gemini-2.5-pro" "$(cat "$CAPTURED_MODEL")" \
  "a per-mode override beats the global one"

# ── Response handling ──

( STUB_RESPONSE='{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"reasoning"},{"text":"answer"}]}}]}'
  out=$(siphon_invoke bulk-reader "$message_file" 2>/dev/null)
  [ "$out" = "answer" ] ) && rc=0 || rc=1
check "thought-parts-excluded" "0" "$rc" "reasoning parts must not leak into the answer"

( STUB_RESPONSE='{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"one "},{"text":"two"}]}}]}'
  out=$(siphon_invoke bulk-reader "$message_file" 2>/dev/null)
  [ "$out" = "one two" ] ) && rc=0 || rc=1
check "multi-part-text-joined" "0" "$rc" "a multi-part answer must not be truncated to its first part"

( STUB_RESPONSE='{"candidates":[{"finishReason":"STOP","content":{"parts":[]}}]}'
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>&1 )
check "empty-answer-fails" "1" "$?" "an answer with no text is an error"

( STUB_RESPONSE='not json at all'
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"could not be parsed"*) exit 0 ;; *) exit 1 ;; esac )
check "garbled-response-fails" "0" "$?" "a 200 with an unparseable body is a transport error"

( STUB_RESPONSE='{"candidates":[{"finishReason":"SAFETY","content":{"parts":[{"text":"partial"}]}}]}'
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"SAFETY"*"discarded"*) exit 0 ;; *) exit 1 ;; esac )
check "finish-reason-safety-fails" "0" "$?" "an answer stopped by a filter must not pass as a good one"

( STUB_RESPONSE='{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"half a file"}]}}]}'
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>&1 )
check "finish-reason-max-tokens-fails" "1" "$?" "truncated output is worse than none when it lands on disk"

( STUB_RESPONSE='{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"half"}]}}]}'
  SIPHON_ALLOW_TRUNCATED=1 siphon_invoke bulk-reader "$message_file" >/dev/null 2>&1 )
check "truncation-opt-in-honoured" "0" "$?" "SIPHON_ALLOW_TRUNCATED keeps the partial answer"

( STUB_RESPONSE='{"promptFeedback":{"blockReason":"OTHER"}}'
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"prompt was blocked"*) exit 0 ;; *) exit 1 ;; esac )
check "prompt-blocked-explained" "0" "$?" "a blocked prompt is named as such"

# ── Error dispatch ──

( STUB_STATUS=400
  STUB_RESPONSE='{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}'
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"API key not valid."*"400, not 401"*) exit 0 ;; *) exit 1 ;; esac )
check "http-400-explained" "0" "$?" "an invalid key returns 400, and the hint says so"

( STUB_STATUS=429
  STUB_RESPONSE='{"error":{"code":429,"message":"Quota exceeded.","status":"RESOURCE_EXHAUSTED"}}'
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"Rate-limited"*) exit 0 ;; *) exit 1 ;; esac )
check "http-429-explained" "0" "$?" "quota errors name the retry behaviour"

( STUB_STATUS=404
  STUB_RESPONSE='{"error":{"code":404,"message":"not found","status":"NOT_FOUND"}}'
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"SIPHON_MODEL"*) exit 0 ;; *) exit 1 ;; esac )
check "http-404-names-model" "0" "$?" "a wrong model id points at SIPHON_MODEL"

( STUB_CURL_RC=28
  siphon_invoke bulk-reader "$message_file" >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"SIPHON_TIMEOUT_SECONDS"*) exit 0 ;; *) exit 1 ;; esac )
check "curl-timeout-explained" "0" "$?" "curl exit 28 replaces the old string match on 'timed out'"

# ── Guards ──

siphon_invoke no-such-mode "$message_file" >/dev/null 2>"$WORKDIR/err"
rc=$?
check "unknown-mode-fails" "1" "$rc" "a mode with no instructions file fails before any network call"
case "$(cat "$WORKDIR/err")" in *"SIPHON_PROMPTS_DIR"*) rc=0 ;; *) rc=1 ;; esac
check "unknown-mode-names-dir" "0" "$rc" "the error points at the prompts directory"

( SIPHON_MAX_REQUEST_BYTES=10 siphon_invoke bulk-reader "$message_file" >/dev/null 2>&1 )
check "oversized-payload-fails" "1" "$?" "an oversized request is refused before it is sent"

( SIPHON_MAX_REQUEST_BYTES=10 siphon_invoke bulk-reader "$message_file" >/dev/null 2>"$WORKDIR/err"
  case "$(cat "$WORKDIR/err")" in *"over the 10 byte limit"*) exit 0 ;; *) exit 1 ;; esac )
check "oversized-payload-explained" "0" "$?" "the error names the limit"

# ── Output cleanup ──

fence_file="$WORKDIR/fenced.txt"
printf '```ts\nconst a = 1;\n```\n' > "$fence_file"
check "outer-fence-stripped" "const a = 1;" "$(siphon_strip_outer_fence "$fence_file")" \
  "one wrapping fence pair is removed"

printf 'Intro:\n\n```ts\nconst a = 1;\n```\n\nDone.\n' > "$fence_file"
check "inner-fences-preserved" "2" "$(siphon_strip_outer_fence "$fence_file" | grep -c '^```')" \
  "fences inside the content survive — the old sed deleted every one"

# ── Error reporting ──

out=$(siphon_report_error "could not invoke chat" '{"error":{"message":"Not authenticated.","status":"UNAUTHENTICATED"}}' 2>&1)
case "$out" in
  *"could not invoke chat: Not authenticated."*"UNAUTHENTICATED"*) rc=0 ;; *) rc=1 ;;
esac
check "error-unwrapped" "0" "$rc" "Gemini's message and status surface"

out=$(siphon_report_error "invoke failed" 'plain text failure' 2>&1)
case "$out" in *"invoke failed"*"plain text failure"*) rc=0 ;; *) rc=1 ;; esac
check "non-json-error-passed-through" "0" "$rc" "unparseable output is not swallowed"

rm -rf "$WORKDIR"
echo "## $PASSED $FAILED"
[ "$FAILED" -eq 0 ]
