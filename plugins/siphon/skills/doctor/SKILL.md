---
name: doctor
description: Diagnose Siphon without changing anything — plugin install state per host, jq/curl presence, API key presence, Gemini connectivity, model availability, and hook enforcement. Use when delegation fails, the key looks wrong, a model 404s, hooks stopped firing, or the user asks whether Siphon is ready.
---

# Diagnose Siphon

**Read-only.** Do not install, write config, create or delete files, or set variables.
Report and recommend only. Never print the API key. The one call that costs anything is the
model probe in §5: a single output token with thinking off, roughly three tokens. It is not
optional, because a metadata call cannot tell a live model from a retired one.

## 1. Plugin install state

Run only the command for the detected host:

```bash
claude plugin list --json            # Claude Code
codex plugin list --available --json # Codex
```

Cursor has no documented plugin-list CLI: inspect via **Settings → Customize → Plugins**
and ask the user to report name, version and enabled state. Do not invent a Cursor command.

If the version is current but skill descriptions look stale, recommend `/reload-plugins`
or a fresh session.

## 2. Toolchain

`jq` and `curl` present, with versions. Report each missing one with its install command.

## 3. Plugin root

```bash
SIPHON="${SIPHON_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}}"
```

Report which tier won, and whether `$SIPHON/scripts/bulk-read` exists **and is executable**.
A resolved-but-not-executable root is the single most likely post-install failure; call it
out specifically and recommend `chmod +x`.

## 4. API key

`scripts/lib/gemini.sh` resolves the key from two places, in order: `$GEMINI_API_KEY`, then
the file at `$GEMINI_API_KEY_FILE` (default `~/.config/siphon/gemini.key`). **Check both.**
An install whose key lives only in the file is healthy; reporting it unset sends the user to
replace a key that already works, and the probe in §5 then goes out with an empty header and
comes back `403`, which reads as a second, unrelated failure.

```bash
keyfile="${GEMINI_API_KEY_FILE:-$HOME/.config/siphon/gemini.key}"
if [ -n "${GEMINI_API_KEY:-}" ]; then
  echo "key: GEMINI_API_KEY (${#GEMINI_API_KEY} chars)"
elif [ -r "$keyfile" ]; then
  k=$(head -n1 "$keyfile" | tr -d '[:space:]'); echo "key: $keyfile (${#k} chars)"
else
  echo "key: NOT SET - neither GEMINI_API_KEY nor $keyfile"
fi
```

Report which source supplied it, and the length. **Never the value.**

## 5. Connectivity and model

**A metadata call is not enough, and using one is how this check has been wrong before.**
`GET /models/<id>` returns `200` in at least two states where nothing can actually be
generated. Both measured:

| State | metadata | `generateContent` |
|---|---|---|
| retired model (`gemini-2.5-flash`, 2026-09-23) | `200` | `404` no longer available |
| billing-dead key (prepay credits depleted, 2026-09-27) | `200` | `402` credits depleted |

In the second case the key cannot serve **any** model, and metadata still says `200` for all
of them. Probing metadata alone reports a dead backend as ready, which is the exact failure
this section exists to catch.

So: one minimal generation. A single output token with thinking off is the cheapest call
that proves the model will answer, about three tokens. Resolve the key as in §4. The key
travels through a `curl --config` pipe, never in argv where `ps` would expose it to any local
user, matching `scripts/lib/gemini.sh` and the rule in `AGENTS.md`:

```bash
keyfile="${GEMINI_API_KEY_FILE:-$HOME/.config/siphon/gemini.key}"
key="${GEMINI_API_KEY:-$(head -n1 "$keyfile" 2>/dev/null)}"
printf 'header = "x-goog-api-key: %s"\n' "$(printf '%s' "$key" | tr -d '[:space:]')" \
| curl -sS --config - -o /dev/null -w '%{http_code}\n' \
    -H 'Content-Type: application/json' -X POST \
    -d '{"contents":[{"parts":[{"text":"x"}]}],"generationConfig":{"maxOutputTokens":1,"thinkingConfig":{"thinkingBudget":0}}}' \
    "https://generativelanguage.googleapis.com/v1beta/models/${SIPHON_MODEL:-gemini-3.8-flash}:generateContent"
```

Interpret the status:

- `200` — the model will answer. Ready.
- `400` — **an invalid key returns 400, not 401.** Treat it as a bad key.
- `403` — restricted key, API not enabled, **or an empty key header, so re-check §4 before
  blaming the key**.
- `402` — **billing, not quota.** On a prepaid project, "Your prepayment credits are
  depleted": top up at <https://ai.studio/projects>, see
  <https://ai.google.dev/gemini-api/docs/billing#prepay>. Note the body's `status` field says
  `RESOURCE_EXHAUSTED`, the same string a `429` uses, so **read the HTTP code, not the
  status**: the remedies are paying and waiting respectively. The key and the model are both
  fine; nothing in §4 needs changing.
- `404` — the model id is wrong **or retired**. Drop `-o /dev/null` and read the message,
  which names the replacement, then list what is actually available:

  ```bash
  printf 'header = "x-goog-api-key: %s"\n' "$key" | curl -sS --config - \
    "https://generativelanguage.googleapis.com/v1beta/models" \
  | jq -r '.models[] | select(.supportedGenerationMethods[]? == "generateContent") | .name'
  ```

- `429` — quota, key valid. **`error.details[].quotaId` is the only thing that says which
  limit was hit**, and there are several. Two measured on the free tier:

  | quotaId | Window | Remedy |
  |---|---|---|
  | `…InputTokensPerModelPerMinute-FreeTier` | per minute, per model | pace the calls |
  | `GenerateRequestsPerDayPerProjectPerModel-FreeTier` | per day, per project per model | wait, or pay |

  Both observed on the free tier: the per-minute one on 2026-09-23 (three 131,855-token calls
  in 3s tripped it; the same call 45s later returned 200), the per-day one on 2026-09-27.

  Report the `quotaId` and the `quotaValue` the error gives, and **do not present either as
  the account's real limit.** Two reasons. `retryDelay` does not match the window it claims:
  a per-day trip reported `retryDelay 28s`, which is not when a daily bucket refills. And the
  per-day quota did not hold on observation: a `429` naming it was followed about a minute
  later by a served request on the same model, so enforcement is looser than the label reads.

  **The authoritative numbers are in the AI Studio dashboard**
  (<https://aistudio.google.com/rate-limit>), not in this error. Google's rate-limit page
  publishes no per-model free-tier figures and points there; per-day quotas reset at midnight
  Pacific, per project. Point the user at the dashboard rather than quoting a number at them.
  The limits follow the **project's billing tier**, not the model, and a key can belong to a
  project that is not listed in AI Studio at all, which is worth checking before reading
  anything into the numbers.

  Still say which window it was, because the remedies are opposite: pacing for a per-minute
  limit, waiting or paying for a per-day one. Reading a per-minute trip as a daily cap sends
  people to buy a key they may not need; the reverse has them retrying for hours.

## 6. Hook enforcement

Confirm `hooks/hooks.json` exists (plus `hooks/cursor-hooks.json` on Cursor) and that both
hook scripts are executable. Then dry-run them locally — this needs no host:

```bash
printf '{"tool_input":{"file_path":"%s"}}' "$SIPHON/scripts/bulk-read" \
  | "$SIPHON/hooks/check-file-size"
```

State coverage honestly:

- **Claude Code** — `Read` + `Bash`. Full.
- **Codex** — Bash only, **because Codex has no `Read` tool**. Partial by design.
- **Cursor** — `beforeReadFile` + `beforeShellExecution`. Full.

## 7. Configuration sanity

Report `SIPHON_MODEL`, `SIPHON_MIN_LINES`, `SIPHON_PEEK_LINES`, `SIPHON_TIMEOUT_SECONDS`,
`SIPHON_API_BASE`. Flag a non-numeric `SIPHON_MIN_LINES` (the hooks silently fall back to
350) and any non-default `SIPHON_API_BASE` — a proxy the user may have forgotten.

## Report

| Check | Status | Evidence or next action |
|---|---|---|
| Plugin | ready / warning / blocked | Host, version, reload guidance |
| Toolchain | ready / blocked | jq and curl versions |
| Plugin root | ready / blocked | Resolved path and which tier supplied it |
| API key | ready / blocked | Set or unset and length — never the value |
| Connectivity | ready / blocked | HTTP status for the model probe |
| Model | ready / blocked | Model id, or the available `generateContent` models |
| Hooks | full / partial / off | Per-host coverage, with the Codex `Read` caveat |

**Do not report overall readiness when any required check is blocked or unverified.**
