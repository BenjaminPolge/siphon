# siphon

> A fork of [spotify/portal-ai-plugins](https://github.com/spotify/portal-ai-plugins),
> **adapted to run without Spotify Portal** — it calls the Google AI Studio (Gemini)
> API directly, so an API key is the only prerequisite.
>
> See the [root README](../../README.md) for the overview, or its
> [French version](../../README.fr.md).

Siphons I/O-heavy work to Gemini, saving most of the context a coding agent would
otherwise spend on bytes. Works in Claude Code, Codex and Cursor.

## Quick start

```bash
export GEMINI_API_KEY="your-key"     # https://aistudio.google.com/apikey
```

Then, in a new session: `/siphon:setup` to configure, `/siphon:doctor` to diagnose.

This README is the technical reference; start with the root one.

## How it works

Three layers, from hard gate to soft suggestion:

1. **Hooks** block reads that would dump a large file into context and redirect
   to the bulk-reader skill.
2. **Scripts** handle the Gemini call and output cleanup.
3. **Skills** tell the agent when and how to call the scripts.

The agent never assembles a bash pipeline from prose. It calls a script with
named arguments, and the scripts handle everything internally.

Delegation is one HTTPS call per request to
`generativelanguage.googleapis.com`, with the system instruction read from
`prompts/`. There is no broker, no CLI and no server-side state.

## Prerequisites

- [`jq`](https://jqlang.org) — `brew install jq`
- `curl`
- A key from https://aistudio.google.com/apikey

Then, in a new session:

```text
/siphon:setup
```

`setup` verifies the key by making one metadata call and writes the configuration
into the host's own config — never into the repository.

## Modes

The two system instructions live in `prompts/`, as plain text:

```
prompts/
├── bulk-reader.md   # "You are a precise code analyst…"
├── code-writer.md   # "You generate code files based on a spec…"
└── mode.json        # per-mode temperature
```

To customise one, edit the file. To keep your edits across plugin updates, copy
the directory elsewhere and set `SIPHON_PROMPTS_DIR`.

## Plugin structure

```
siphon/
├── plugin.json                  # portable manifest, canonical for Codex
├── .claude-plugin/plugin.json
├── .codex-plugin/plugin.json    # compatibility fallback
├── .cursor-plugin/plugin.json   # + hooks + variables (API key prompt)
├── hooks/
│   ├── hooks.json               # Claude Code + Codex
│   ├── cursor-hooks.json        # Cursor (camelCase events)
│   ├── lib/hook-io.sh           # tri-host input parsing + union output
│   ├── check-file-size
│   └── check-bash-read
├── scripts/
│   ├── lib/gemini.sh            # the transport
│   ├── lib/plugin-root.sh
│   ├── bulk-read
│   └── code-write
├── prompts/
├── skills/
└── evals/
```

## Scripts

### bulk-read

```bash
bulk-read --question "Which methods call the database?" --paths src/Service.java src/Handler.java
```

### code-write

Strips a wrapping markdown fence and can write straight to disk. `--reference` is
required — without a file to match patterns against, the worker generates
context-free code that fits nothing in the project.

```bash
code-write --spec "Write tests for UserService" --reference tests/OrderTest.java --target tests/UserTest.java
code-write --spec "Generate a config stub" --reference config/existing.yaml   # to stdout
```

An answer that hit the output cap is discarded rather than written: a `--target`
file is either complete or absent. Set `SIPHON_ALLOW_TRUNCATED=1` to override.

### One shot per call

Every delegation stands alone. `generateContent` is stateless, and the only way
to carry context across calls would be to replay it from this side — which for a
file corpus is the very cost the plugin exists to avoid. Re-sending files is free
where it matters, because the corpus goes to the worker and never enters the main
model's context.

## Hooks

Both hooks emit the **union** of the three hosts' response shapes and exit 2,
which is the one contract all three document as blocking. They read the tool
payload from either the nested `tool_input` shape or Cursor's top-level shape.

### check-file-size

Fires on file reads. Blocks above `SIPHON_MIN_LINES` (default 350). Allows
targeted reads (offset or limit set), small files, and nonexistent paths.

**Codex has no `Read` tool**, so this hook never fires there.

### check-bash-read

Fires on shell commands and catches anything that would dump a large file into
context: `cat`, `head`, `tail`, `less`, `more`, `grep`/`rg`, `awk`, `sed`.

Allowed through:

- reducing forms — `grep -c`, `grep -l`, `grep -q`, `grep -m`
- an explicit small count — `head -n 5`, `tail -n 20`, `sed -n '1,10p'`
- pipelines with a reducing stage — `cat big.ts | grep export`
- redirections — `cat big.ts > out` is not a read into context

The coverage is deliberately wider than the obvious tools. In a real session the
agent reached for `grep -n "export" big.ts` on a 600-line file where every line
matched: the whole file entered context, and a gate that only knew `cat` allowed
it. Some false positives are the price; `SIPHON_PEEK_LINES` tunes the peek
threshold.

Command parsing is quote-aware. A path containing a space used to split into
fragments and fail **open**, which is the wrong direction for a cost gate.

## Configuration

See the table in the [root README](../../README.md).

## What doesn't get delegated

- **Debugging** — requires real reasoning, not a summary
- **Editing** — the agent needs exact content in context; use a targeted read
- **Architectural decisions** — judgment stays with the main model
- **Small files** — below the threshold the round trip costs more than it saves

## Limitations

- **Latency** — a round trip is seconds, so tiny delegations are counterproductive.
- **Codex enforcement is partial** — no `Read` tool, so only the shell gate applies.
- **Cursor hooks are not yet verified end-to-end** on a live install.
- **Request size** — capped by `SIPHON_MAX_REQUEST_BYTES` (2 MB) as a cost
  circuit-breaker, not an OS limit. The model accepts about 1M tokens.
- **Benchmarks** — the numbers in `evals/benchmarks.json` were measured against
  the previous AiKA backend and are pending re-measurement on `gemini-2.5-flash`.

## Evals

```bash
bash evals/run.sh              # 75 checks: hooks + transport, no key, no network
bash evals/run.sh --benchmark  # adds the real round trip
```
