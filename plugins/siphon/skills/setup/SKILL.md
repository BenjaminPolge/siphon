---
name: setup
description: Set up and verify Siphon — install a Google AI Studio API key, confirm connectivity and model availability, and wire the plugin root for the current host. Use when the user asks to install, configure, connect, or authenticate Siphon, or when bulk-read/code-write report a missing key.
---

# Set Up Siphon

Configure the plugin for the current coding-agent host.

## Rules

- **Never ask the user to paste the API key into chat**, and never echo, log, or
  `echo $GEMINI_API_KEY`. Verify it only by making a call and reporting the status.
- **Never write the key to a file inside the repository.**
- Prefer `--json` / `jq` for anything you consume.
- `setup` may write config; `doctor` may not. Keep that line.

## 1. Identify the host

Check in order: `$CLAUDE_PLUGIN_ROOT` set → Claude Code; `$CURSOR_PLUGIN_ROOT` set →
Cursor; `$PLUGIN_ROOT` set → Codex. If ambiguous, ask. Every later step branches on this.

## 2. Verify the toolchain

```bash
command -v jq   || echo "MISSING jq"
command -v curl || echo "MISSING curl"
```

`jq` missing → `brew install jq`, or `apt-get install jq`. `curl` ships with macOS.

## 3. Resolve the plugin root

```bash
SIPHON="${SIPHON_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}}"
[ -n "$SIPHON" ] && [ -x "$SIPHON/scripts/bulk-read" ] && echo "root=$SIPHON"
```

If empty or not executable, locate the install directory (Claude: `~/.claude/plugins/…`;
Codex: `~/.agents/plugins/…`; Cursor: `~/.cursor/plugins/…`) and pin it in step 6.
A resolved-but-not-executable root is the most common post-install failure — a lost
`+x` through an archive install. Fix with `chmod +x`.

## 4. Check the key is present, without printing it

```bash
[ -n "${GEMINI_API_KEY:-}" ] && echo "GEMINI_API_KEY: set (${#GEMINI_API_KEY} chars)" \
                             || echo "GEMINI_API_KEY: NOT SET"
```

If unset, point the user to https://aistudio.google.com/apikey and to step 6.
Do not accept the key in conversation.

## 5. Verify connectivity and the model

One metadata call, no generation cost:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "x-goog-api-key: $GEMINI_API_KEY" \
  "https://generativelanguage.googleapis.com/v1beta/models/${SIPHON_MODEL:-gemini-2.5-flash}"
```

- `200` — key valid, model reachable.
- `400` — **an invalid key returns 400, not 401.** Treat it as a bad key.
- `403` — key restricted, or the Generative Language API is not enabled.
- `404` — wrong model id. List what is actually available:

  ```bash
  curl -sS -H "x-goog-api-key: $GEMINI_API_KEY" \
    "https://generativelanguage.googleapis.com/v1beta/models" \
  | jq -r '.models[] | select(.supportedGenerationMethods[]? == "generateContent") | .name'
  ```

- `429` — quota reached; the key works. Note it and continue.

## 6. Persist the configuration

| Host | Where | What |
|---|---|---|
| Claude Code | `env` block of `.claude/settings.json` (project) or `~/.claude/settings.json` (user) | `GEMINI_API_KEY`, `SIPHON_MODEL`, `SIPHON_ROOT`, `SIPHON_MIN_LINES`. `.claude/` is gitignored — confirm that before writing a key there, and offer the shell-profile alternative. |
| Codex | `~/.codex/config.toml`, or the shell profile | Same variables. Codex sets `PLUGIN_ROOT` itself, so `SIPHON_ROOT` is belt-and-braces. |
| Cursor | **Cursor's plugin variables UI** | The manifest declares `GEMINI_API_KEY` as required, so Cursor prompts at install and the key never touches the repository. Only `SIPHON_ROOT` may need a profile entry. |

Optionally symlink `bulk-read` and `code-write` into `~/.local/bin`, so the skills work
even where the host exports no plugin-root variable into the agent's shell.

## 7. Smoke test

The only step that spends tokens:

```bash
printf 'line %s\n' 1 2 3 4 5 > /tmp/siphon-smoke.txt
"$SIPHON/scripts/bulk-read" --question "How many lines?" --paths /tmp/siphon-smoke.txt
rm -f /tmp/siphon-smoke.txt
```

A non-empty answer plus the `[siphon: … in / … out]` line on stderr proves key, transport,
prompt files and path resolution all work together.

## 8. Confirm enforcement is live

Attempt a read of a file over the threshold and confirm the block fires.

State the coverage plainly, because it differs:

- **Claude Code** — `Read` and `Bash` both gated. Full.
- **Codex** — **no `Read` tool exists**; file reads go through the shell, so only the
  Bash gate applies. Partial, and that is a property of the host, not a misconfiguration.
- **Cursor** — `beforeReadFile` and `beforeShellExecution`. Full.

## Report

A table: host · jq/curl · plugin root · key (set or not, **never the value**) ·
model and HTTP status · config written to · smoke test · enforcement (full, bash-only, off).
