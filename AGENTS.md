# Siphon

This repository packages the `siphon` plugin for Claude Code, Codex and Cursor.
Siphon routes I/O-heavy agent work — reading large files, generating boilerplate —
to the Google AI Studio (Gemini) API, so the expensive reasoning model never pays
for the bytes.

It began as a fork of `spotify/portal-ai-plugins`; see `NOTICE`.

## Repository structure

- The repository root is a **marketplace, not a plugin**. It carries one
  marketplace manifest per host: `.claude-plugin/`, `.codex-plugin/`, `.cursor-plugin/`.
- `plugins/siphon/` is the only plugin, with four manifests:
  - `plugin.json` — portable Agent Plugins 1.0.0, canonical for Codex.
  - `.claude-plugin/plugin.json` — Claude Code.
  - `.codex-plugin/plugin.json` — Codex compatibility fallback (no `hooks`, no
    `skills`: both are unsupported in that manifest and resolved elsewhere).
  - `.cursor-plugin/plugin.json` — Cursor, and the only manifest carrying
    `variables`, which is how Cursor prompts for the API key at install time.
- `plugins/siphon/prompts/` holds the system instructions that used to live
  server-side as AiKA modes.
- `plugins/siphon/hooks/` holds both hook configs: `hooks.json` (Claude Code and
  Codex, PascalCase `PreToolUse`) and `cursor-hooks.json` (Cursor, camelCase).

## Design rules

- The plugin identifier is `siphon`, producing `/siphon:<skill>` in Claude Code. It
  is identical across four plugin manifests and three marketplace entries —
  changing it means changing seven files.
- Keep `doctor` read-only, and keep it off `generateContent`: diagnosis must not
  spend tokens.
- Keep each skill canonical in `plugins/siphon/skills/`.
- Do not publish the bundled skills as standalone packages.
- Do not add release automation unless a tagged release or another distribution
  channel is explicitly planned.
- **Never print, log, or echo `GEMINI_API_KEY`.** Verify it only by making a call
  and reporting the HTTP status. The key travels as a header through a `curl
  --config` pipe — never in argv, where `ps` would expose it, and never in a
  query string, which proxies log.
- Hooks emit the **union** of all three hosts' response shapes *and* exit 2 on
  block. Exit 2 is the one contract every host documents as blocking, so
  enforcement survives a host rejecting a JSON shape it does not know. Any change
  to hook output must stay covered by the eval suite.
- Scripts resolve their own location from `$0`; skills resolve the plugin root
  through the four-tier `SIPHON_ROOT → CLAUDE_PLUGIN_ROOT → CURSOR_PLUGIN_ROOT →
  PLUGIN_ROOT` chain. **Never hardcode `${CLAUDE_PLUGIN_ROOT}` in skill prose** —
  no host substitutes variables there; it only ever worked because the shell did.
- Quote every path. This project has been developed under a checkout path
  containing a space, and unquoted expansion fails open — the wrong direction for
  a cost gate.
- Do not ship Spotify or Google trademarks. The `NOTICE` attribution is required
  by Apache-2.0 §4 and must not be removed.

## Validation

```bash
claude plugin validate --strict .
claude plugin validate --strict plugins/siphon

# hooks + transport evals — no API key, no network
bash plugins/siphon/evals/run.sh

# adds the real round trip; needs GEMINI_API_KEY
bash plugins/siphon/evals/run.sh --benchmark
```
