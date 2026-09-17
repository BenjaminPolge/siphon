---
name: bulk-reader
description: "Delegate bulk file reading to Gemini. Use when you need to read files >350 lines, answer questions across 3+ files, or summarize large diffs."
---

Resolve the plugin root first. No host substitutes variables inside skill prose, so
this expansion is done by the shell, and it covers all three hosts:

```bash
SIPHON="${SIPHON_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}}"
"$SIPHON/scripts/bulk-read" --question "<question>" --paths <file1> [<file2> ...]
```

If `$SIPHON` resolves empty, run `bulk-read` directly — `setup` offers to put it on `PATH`.

Each call is independent. To ask a follow-up, ask again with the same `--paths` — the files
go to Gemini, never into your context, so re-sending them costs you nothing.

Verify specific line numbers or exact values before using them in edits.
