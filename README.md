# Siphon

**🇬🇧 English** · [🇫🇷 Français](README.fr.md)

> A fork of [spotify/portal-ai-plugins](https://github.com/spotify/portal-ai-plugins),
> **adapted to run without Spotify Portal**. Same idea, same prompts, same results —
> but it talks straight to the Google AI Studio (Gemini) API, so you only need an API key.

Most of what a coding agent does is not thinking — it is I/O. Siphon intercepts the
expensive part and sends it to a cheap worker model:

- **bulk-reader** — read many or large files and answer one question about them
- **code-writer** — generate boilerplate that matches your existing files

Measured on this repo's own fixtures: a 602-line file costs **12,006 tokens** to read
directly, versus **137 tokens** for the answer that comes back — **98% less context**,
in about 2 seconds for roughly half a cent.

Works in **Claude Code**, and ships manifests for **Codex** and **Cursor**.

## Quick start

```bash
# 1. Get a key at https://aistudio.google.com/apikey, then:
export GEMINI_API_KEY="your-key"

# 2. Install
claude plugin marketplace add BenjaminPolge/siphon
claude plugin install siphon@siphon-plugins
```

Start a new session and run:

```text
/siphon:setup
```

That's it. From then on, any attempt to read a file over 350 lines is blocked and
redirected to Gemini automatically.

Something not working? Run `/siphon:doctor` — it is read-only and spends no tokens.

## What changed from the original

The original required a Spotify Portal instance and its CLI, with the worker model
chosen server-side. This fork removes that dependency entirely.

| | Original | Siphon |
|---|---|---|
| Transport | `portal-cli actions aika:invoke-chat` | direct HTTPS to `generativelanguage.googleapis.com` |
| Requirement | a Portal instance + auth | a Gemini API key |
| Worker prompts | server-side "AiKA modes" | plain text files in `prompts/`, editable |
| Model | chosen by the instance | `SIPHON_MODEL`, default `gemini-2.5-flash` |
| Request size | 120 KB (the prompt travelled through `argv`) | ~1M tokens |
| Hosts | Claude Code | Claude Code, Codex, Cursor |
| Portal catalog workflows | `search`, `service`, `actions`, `feedback` | removed — they query a Backstage catalog no API can replace |

The three-layer design, the two worker prompts (copied verbatim), the command-line
interface and the one-shot-per-call rule are all unchanged. This is a change of
plumbing, not of design.

Beyond the port, three bugs inherited from the original are fixed: benchmarks
reported a flawless 100% saving when the transport failed; the shell gate failed
**open** on any path containing a space; and `grep` walked straight past the gate.

## How it works

Three layers, from hard gate to soft suggestion:

1. **Hooks** block reads that would dump a large file into context.
2. **Scripts** make the Gemini call and clean up the output.
3. **Skills** tell the agent when and how to delegate.

The agent never assembles a pipeline from prose; it calls a script with named arguments.

### What actually works, per host

| Layer | Claude Code | Codex | Cursor |
|---|---|---|---|
| Hook on file reads | ✅ | ❌ **no `Read` tool exists** | ✅ |
| Hook on shell reads | ✅ | ✅ | ✅ |
| Scripts | ✅ | ✅ | ✅ |
| Skills | ✅ | ✅ | ✅ |

Verified end-to-end on Claude Code. Codex and Cursor support is written to their
official documentation but has **not been verified on a live install** — on Codex
enforcement is partial in any case, since the host has no `Read` tool and file reads
go through the shell.

## Requirements

- [`jq`](https://jqlang.org) — `brew install jq`
- `curl` — ships with macOS
- A Google AI Studio API key

> **Where your code goes.** Delegated files are sent to Google's public API under your
> own key. If you are used to an internally operated endpoint, this is a change of
> destination for your source code, not just of transport. Check it fits your
> organisation's policy first.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | — | API key |
| `GEMINI_API_KEY_FILE` | `~/.config/siphon/gemini.key` | Read when the variable is unset |
| `SIPHON_MODEL` | `gemini-2.5-flash` | Model for delegated calls |
| `SIPHON_MIN_LINES` | `350` | Line count above which a read is blocked |
| `SIPHON_PEEK_LINES` | `50` | An explicit count at or below this is a peek, not a bulk read |
| `SIPHON_THINKING_BUDGET` | `0` | Gemini reasoning budget — see below |
| `SIPHON_TIMEOUT_SECONDS` | `180` | Per-call ceiling |

### Why reasoning is off by default

`gemini-2.5-flash` reasons by default, and those tokens are billed as output **and drawn
from the same budget as the answer**. With `maxOutputTokens` at 40, a probe spent 35
tokens thinking and had 1 left to reply, returning a truncated answer. Worker tasks gain
nothing from it. Set `SIPHON_THINKING_BUDGET=-1` to let the model decide.

## What doesn't get delegated

- **Debugging** — needs real reasoning, not a summary
- **Editing** — the agent needs exact content; use a targeted read
- **Architectural decisions** — judgment stays with the main model

## Development

```bash
bash plugins/siphon/evals/run.sh              # 86 checks, no key, no network
bash plugins/siphon/evals/run.sh --benchmark  # adds the real round trip
```

## Licence

Apache-2.0, like the upstream project. See [`NOTICE`](NOTICE) for the required
attribution to Spotify AB.

Not affiliated with, endorsed by, or sponsored by Spotify or Google. Gemini and Google
AI Studio are trademarks of Google LLC.
