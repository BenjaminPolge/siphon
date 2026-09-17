---
name: code-writer
description: "Delegate boilerplate code generation to Gemini. Use for tests, config, docstrings, type stubs, or any generation where >80% is predictable from reference files."
---

Resolve the plugin root first. No host substitutes variables inside skill prose, so
this expansion is done by the shell, and it covers all three hosts:

```bash
SIPHON="${SIPHON_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}}"

# Generate and write directly to target file
"$SIPHON/scripts/code-write" --spec "<what to generate>" --reference <reference-file> --target <output-path>

# Output to stdout instead (omit --target)
"$SIPHON/scripts/code-write" --spec "<what to generate>" --reference <reference-file>
```

If `$SIPHON` resolves empty, run `code-write` directly — `setup` offers to put it on `PATH`.

Each call is independent. To build on what was just generated, pass that file as the
`--reference` for the next call.

An answer that hit the output cap is discarded rather than written, so a `--target` file
is either complete or absent. Review the output and make surgical edits for the ~5-20%
that needs your own judgment.
