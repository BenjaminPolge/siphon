#!/bin/bash
# Shared Gemini plumbing for siphon's delegation scripts.
#
# Everything goes straight to the Google AI Studio generateContent endpoint over
# HTTPS, so the plugin needs no broker, no CLI and no company backend — just a
# key and curl.
#
# Modes are local: each one is a system instruction file under prompts/ plus a
# temperature in prompts/mode.json. There is no server-side mode object to
# resolve, so "the mode was not applied" is no longer a failure that can happen
# silently after the fact — either the instruction file loads before the call or
# there is no call at all.
#
# Every delegation is one shot. generateContent is stateless by construction,
# and the only way to carry context across calls would be to replay it from this
# side, which for a file corpus is the very cost the plugin exists to avoid.
# Ask again with the files instead.

. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/plugin-root.sh"

SIPHON_API_BASE="${SIPHON_API_BASE:-https://generativelanguage.googleapis.com/v1beta}"
SIPHON_MODEL="${SIPHON_MODEL:-gemini-2.5-flash}"
SIPHON_TIMEOUT_SECONDS="${SIPHON_TIMEOUT_SECONDS:-180}"
SIPHON_CONNECT_TIMEOUT_SECONDS="${SIPHON_CONNECT_TIMEOUT_SECONDS:-10}"
SIPHON_RETRIES="${SIPHON_RETRIES:-2}"

# gemini-2.5-flash reasons by default, and those tokens are billed as output AND
# drawn from the same budget as the answer: with maxOutputTokens at 40, a probe
# spent 35 tokens thinking and had 1 left for the reply, returning MAX_TOKENS
# with a truncated answer. Worker tasks -- read these files, emit this
# boilerplate -- gain nothing from it, so it is off unless asked for.
SIPHON_THINKING_BUDGET="${SIPHON_THINKING_BUDGET:-0}"

# Cost circuit-breaker, not an OS limit. The old ARG_MAX ceiling existed because
# the prompt travelled through argv; the body now goes through a file, and the
# model accepts ~1M tokens. This is just the point where one call starts costing
# real money.
SIPHON_MAX_REQUEST_BYTES="${SIPHON_MAX_REQUEST_BYTES:-2000000}"

SIPHON_PROMPTS_DIR="${SIPHON_PROMPTS_DIR:-$(siphon_plugin_root)/prompts}"

# mktemp with cleanup on script exit. Usage: siphon_tmpfile <varname>
SIPHON_TMPFILES=()
siphon_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SIPHON_TMPFILES+=("$f")
  trap 'rm -f "${SIPHON_TMPFILES[@]:-}"' EXIT
  printf -v "$1" '%s' "$f"
}

# Indirect lookup of SIPHON_<MODE>_<SUFFIX>, e.g. SIPHON_BULK_READER_MODEL.
siphon_env_override() {
  local var
  var="SIPHON_$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')_$2"
  printf '%s' "${!var:-}"
}

# Prints the key on stdout and nothing else. Never exported, never in argv.
siphon_api_key() {
  local key="" file="${GEMINI_API_KEY_FILE:-$HOME/.config/siphon/gemini.key}"

  if [ -n "${GEMINI_API_KEY:-}" ]; then
    key="$GEMINI_API_KEY"
  elif [ -r "$file" ]; then
    key=$(head -n1 "$file")
  fi
  key=$(printf '%s' "$key" | tr -d '[:space:]')

  if [ -z "$key" ]; then
    echo "Error: no Gemini API key." >&2
    echo "  Set GEMINI_API_KEY, or put the key in $file (chmod 600)." >&2
    echo "  Get one at https://aistudio.google.com/apikey" >&2
    return 1
  fi

  # The key is interpolated into a curl config line inside double quotes, so a
  # quote or backslash would break parsing or inject another directive. Real
  # keys never contain these; this is pure defence.
  case "$key" in
    *'"'*|*'\'*)
      echo "Error: the API key contains characters that cannot be sent safely." >&2
      echo "  Check for a stray quote or backslash." >&2
      return 1 ;;
  esac

  printf '%s' "$key"
}

siphon_preflight() {
  local missing=""
  command -v jq   >/dev/null 2>&1 || missing="$missing jq"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"

  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "  jq   - brew install jq, or apt-get install jq" >&2
    echo "  curl - ships with macOS; apt-get install curl on Debian" >&2
    return 1
  fi

  siphon_api_key >/dev/null || return 1
  return 0
}

# Resolves the model for a mode: per-mode env, then global env, then default.
siphon_mode_model() {
  local override
  override=$(siphon_env_override "$1" MODEL)
  printf '%s' "${override:-$SIPHON_MODEL}"
}

# Resolves the temperature for a mode: per-mode env, then prompts/mode.json.
siphon_mode_temperature() {
  local override temp
  override=$(siphon_env_override "$1" TEMPERATURE)
  if [ -n "$override" ]; then printf '%s' "$override"; return 0; fi
  temp=$(jq -r --arg m "$1" '.[$m].temperature // 0.2' "$SIPHON_PROMPTS_DIR/mode.json" 2>/dev/null)
  printf '%s' "${temp:-0.2}"
}

siphon_mode_instructions() {
  printf '%s' "$SIPHON_PROMPTS_DIR/$1.md"
}

# Builds the generateContent request body. Pure: no network, so the evals can
# assert request shape without stubbing anything.
#   $1 mode name   $2 file holding the message   $3 file to write the body to
siphon_build_request() {
  local mode="$1" message_file="$2" body_file="$3" instructions

  instructions=$(siphon_mode_instructions "$mode")
  if [ ! -s "$instructions" ]; then
    echo "Error: unknown mode \"$mode\": no instructions at $instructions" >&2
    echo "  Set SIPHON_PROMPTS_DIR if your prompts live elsewhere." >&2
    return 1
  fi

  jq -n \
    --rawfile system "$instructions" \
    --rawfile message "$message_file" \
    --argjson temperature "$(siphon_mode_temperature "$mode")" \
    --argjson thinking "$SIPHON_THINKING_BUDGET" \
    '{
       systemInstruction: { parts: [ { text: $system } ] },
       contents: [ { role: "user", parts: [ { text: $message } ] } ],
       generationConfig: {
         temperature: $temperature,
         thinkingConfig: { thinkingBudget: $thinking }
       }
     }' > "$body_file"
}

# THE TRANSPORT SEAM. Stdout is the HTTP status and nothing else; the response
# body lands in $2; the return value is curl's exit code. The eval suite stubs
# this one function.
#   $1 body file   $2 output file   $3 model
siphon_transport() {
  local body_file="$1" out_file="$2" model="$3" key

  key=$(siphon_api_key) || return 1

  # The key goes through a --config pipe: never in argv (visible to `ps`), never
  # in the query string (logged by every proxy), and never on disk.
  printf 'header = "x-goog-api-key: %s"\n' "$key" | curl \
    --config - \
    --silent --show-error \
    --request POST \
    --header 'Content-Type: application/json' \
    --header 'Expect:' \
    --data-binary "@$body_file" \
    --connect-timeout "$SIPHON_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$SIPHON_TIMEOUT_SECONDS" \
    --retry "$SIPHON_RETRIES" \
    --output "$out_file" \
    --write-out '%{http_code}' \
    "$SIPHON_API_BASE/models/$model:generateContent"
}

# Concatenates the non-thought text parts. Taking parts[0].text would silently
# truncate a multi-part answer, and with thinking on parts[0] can be a thought.
siphon_extract_text() {
  jq -r '[ .candidates[0].content.parts[]?
           | select((.thought // false) | not)
           | .text // empty ] | join("")' "$1" 2>/dev/null
}

# Surfaces a failed call. Gemini's envelope is {"error":{code,message,status}} --
# there is no remediation field, so the hint is generated locally.
siphon_report_error() {
  local label="$1" response="$2" message status

  message=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
  status=$(printf '%s' "$response"  | jq -r '.error.status  // empty' 2>/dev/null)

  if [ -n "$message" ]; then
    echo "Error: $label: $message" >&2
    [ -n "$status" ] && echo "  status: $status" >&2
  else
    echo "Error: $label" >&2
    printf '%s\n' "$response" | head -c 400 >&2
    echo >&2
  fi
}

# Strips exactly one wrapping fence pair, and only when the first non-blank line
# opens and the last non-blank line closes. The old `sed '/^```/d'` deleted every
# fence line anywhere in the output, destroying nested fences in generated docs.
siphon_strip_outer_fence() {
  awk '{ line[NR] = $0 }
       END {
         s = 1; e = NR
         while (s <= e && line[s] ~ /^[[:space:]]*$/) s++
         while (e >= s && line[e] ~ /^[[:space:]]*$/) e--
         if (s < e && line[s] ~ /^```/ && line[e] ~ /^```[[:space:]]*$/) { s++; e-- }
         for (i = s; i <= e; i++) print line[i]
       }' "$1"
}

# Maps a curl exit code to an actionable message. Replaces the old string-match
# on "timed out", which was the only signal portal-cli gave.
siphon_report_curl_error() {
  case "$1" in
    28) echo "Error: the call exceeded ${SIPHON_TIMEOUT_SECONDS}s." >&2
        echo "  Raise SIPHON_TIMEOUT_SECONDS or split the work into smaller calls." >&2 ;;
    6|7|35)
        echo "Error: could not reach $SIPHON_API_BASE (curl exit $1)." >&2
        echo "  Check your network or proxy settings." >&2 ;;
    *)  echo "Error: curl failed (exit $1)." >&2 ;;
  esac
}

siphon_report_http_error() {
  local status="$1" response_file="$2" model="$3"

  siphon_report_error "the request failed (HTTP $status)" "$(cat "$response_file")"
  case "$status" in
    400) echo "  A malformed request, or the key was rejected -- an invalid key returns 400, not 401." >&2
         echo "  Check GEMINI_API_KEY." >&2 ;;
    401|403)
         echo "  The key was rejected. Check GEMINI_API_KEY and that the Generative Language API is enabled." >&2 ;;
    404) echo "  Model \"$model\" not found at $SIPHON_API_BASE. Check SIPHON_MODEL." >&2 ;;
    429) echo "  Rate-limited or out of quota; curl already retried $SIPHON_RETRIES times." >&2 ;;
    5*)  echo "  Upstream error -- usually transient. Raise SIPHON_RETRIES if it persists." >&2 ;;
  esac
}

# Runs one stateless turn against a mode and prints the answer.
#   $1 mode name   $2 file holding the message
siphon_invoke() {
  local mode="$1" message_file="$2"
  local body_file response_file model bytes status rc text finish reason usage

  siphon_tmpfile body_file     || return 1
  siphon_tmpfile response_file || return 1

  siphon_build_request "$mode" "$message_file" "$body_file" || return 1

  bytes=$(wc -c < "$body_file" | tr -d ' ')
  if [ "$bytes" -gt "$SIPHON_MAX_REQUEST_BYTES" ]; then
    echo "Error: request is $bytes bytes, over the $SIPHON_MAX_REQUEST_BYTES byte limit." >&2
    echo "  Send fewer or smaller files, or raise SIPHON_MAX_REQUEST_BYTES." >&2
    return 1
  fi

  model=$(siphon_mode_model "$mode")
  status=$(siphon_transport "$body_file" "$response_file" "$model")
  rc=$?

  if [ "$rc" -ne 0 ]; then
    siphon_report_curl_error "$rc"
    return 1
  fi

  if [ "$status" != "200" ]; then
    siphon_report_http_error "$status" "$response_file" "$model"
    return 1
  fi

  if ! jq -e . "$response_file" >/dev/null 2>&1; then
    siphon_report_error "the response could not be parsed" "$(cat "$response_file")"
    return 1
  fi

  reason=$(jq -r '.promptFeedback.blockReason // empty' "$response_file" 2>/dev/null)
  if [ -n "$reason" ]; then
    echo "Error: the prompt was blocked ($reason). Rephrase or remove the offending content." >&2
    return 1
  fi

  finish=$(jq -r '.candidates[0].finishReason // empty' "$response_file" 2>/dev/null)
  case "$finish" in
    STOP|"") ;;
    MAX_TOKENS)
      # Failing is the right default: code-write writes straight to disk, and a
      # half-written file that looks plausible is worse than no file.
      if [ -z "${SIPHON_ALLOW_TRUNCATED:-}" ]; then
        echo "Error: the answer hit the output cap and was discarded." >&2
        echo "  Split the request, or set SIPHON_ALLOW_TRUNCATED=1 to keep partial output." >&2
        return 1
      fi ;;
    *)
      echo "Error: the response was stopped: $finish. The answer was discarded." >&2
      return 1 ;;
  esac

  text=$(siphon_extract_text "$response_file")
  if [ -z "$text" ]; then
    siphon_report_error "the response contained no text" "$(cat "$response_file")"
    return 1
  fi

  usage=$(jq -r '.usageMetadata
                 | "\(.promptTokenCount // 0) in / \(.candidatesTokenCount // 0) out"
                   + (if (.thoughtsTokenCount // 0) > 0 then " (+\(.thoughtsTokenCount) thinking)" else "" end)' \
          "$response_file" 2>/dev/null)
  echo "[siphon: $usage | $model | $mode]" >&2

  printf '%s\n' "$text"
}
