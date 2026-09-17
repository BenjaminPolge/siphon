#!/bin/bash
# Resolves the plugin root across Claude Code, Codex and Cursor.
#
# Two separate problems are at play, and conflating them is a trap:
#
#   1. Hook command strings in hooks.json ARE templated by the host, and all
#      three expand ${CLAUDE_PLUGIN_ROOT} (Codex and Cursor both set it for
#      compatibility). Nothing to solve there.
#
#   2. A ${CLAUDE_PLUGIN_ROOT} written in SKILL.md prose is NOT templated by
#      anyone. It only works on Claude Code because the model copies the literal
#      string into a Bash call and the shell expands it from an environment
#      Claude Code happens to export. No host documents that export for skills.
#
# So scripts never rely on the environment: they re-derive their own location
# from $0. Whatever entry path reaches a script, everything internal is
# self-locating. The env vars are only a convenience for the skills' prose.

# Absolute path to the plugin root, derived from this file's location.
# scripts/lib/plugin-root.sh -> ../.. is the plugin root.
SIPHON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SIPHON_PLUGIN_DIR="$(cd "$SIPHON_LIB_DIR/../.." && pwd)"

# Honour an explicit override, then the three hosts' own variables, then the
# self-derived path. The self-derived path is last because an override exists
# precisely to point somewhere else.
siphon_plugin_root() {
  printf '%s' "${SIPHON_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-${PLUGIN_ROOT:-$SIPHON_PLUGIN_DIR}}}}"
}
