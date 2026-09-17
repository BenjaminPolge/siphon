---
name: doctor
description: Diagnose Siphon without changing anything — plugin install state per host, jq/curl presence, API key presence, Gemini connectivity, model availability, and hook enforcement. Use when delegation fails, the key looks wrong, a model 404s, hooks stopped firing, or the user asks whether Siphon is ready.
---

# Diagnose Siphon

**Read-only.** Do not install, write config, create or delete files, or set variables.
Report and recommend only. Never print the API key. **Never call `generateContent`** —
`doctor` must not spend tokens.

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

Report set or unset, and character length. **Never the value.**

## 5. Connectivity and model

The metadata probe only — no generation:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "x-goog-api-key: $GEMINI_API_KEY" \
  "https://generativelanguage.googleapis.com/v1beta/models/${SIPHON_MODEL:-gemini-2.5-flash}"
```

Interpret the status: `200` ready; **`400` means the key was rejected — an invalid key
returns 400, not 401**; `403` restricted key or API not enabled; `404` wrong model id,
in which case list the models that support `generateContent`; `429` quota, key valid.

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
