#!/usr/bin/env bash
# PreToolUse(Write|Edit|NotebookEdit) hook. Hard deny on em-dash in authored
# content.
#
# The user's standing rule (rules/no-em-dash.md) forbids em-dashes
# (U+2014) and the horizontal bar (U+2015) as sentence connectors in
# ALL authored output. A text rule is advisory; this hook makes the violation
# impossible for file writes. Use a comma, colon, period, parentheses, or a new
# sentence instead.
#
# Scope of the deny:
#   - Em-dash (U+2014) and horizontal bar (U+2015): denied unconditionally.
#   - En-dash (U+2013): denied ONLY when used as a connector (a space on either
#     side). A bare numeric range such as 2 to 3 joined by an en-dash is allowed.
#
# Escape hatch: set ALLOW_EMDASH=1 in the session environment for the rare
# legitimate case (importing a fixture, quoting source text verbatim).
#
# Emits a single JSON object on stdout per Claude Code's hook protocol.

set -euo pipefail
[ "${RUNTIME_HOOKS_DISABLE:-0}" = "1" ] && exit 0
[ "${ALLOW_EMDASH:-0}" = "1" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$HOOK_DIR/lib/log.sh"

payload="$(cat)"

# Extract the text being written across Write/Edit/NotebookEdit shapes, then
# run the shared detector (hooks/lib/prose-detect.py) so this guard and the
# git pre-commit backstop apply exactly one detection implementation. Python
# handles the JSON parse and Unicode reliably.
text="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except json.JSONDecodeError:
    sys.exit(0)
ti = d.get("tool_input") or {}
# Gather every field that carries newly authored text.
parts = []
for k in ("content", "new_string", "new_source"):
    v = ti.get(k)
    if isinstance(v, str):
        parts.append(v)
sys.stdout.write("\n".join(parts))
' 2>/dev/null || true)"

[ -n "$text" ] || exit 0

reason="$(printf '%s' "$text" | python3 "$HOOK_DIR/lib/prose-detect.py" emdash 2>/dev/null || true)"

if [ -n "$reason" ]; then
  msg="Forbidden dash in authored content ($reason). The em-dash rule is absolute (rules/no-em-dash.md): never use em-dashes. Rewrite with a comma, colon, period, parentheses, or a new sentence. (A bare numeric range joined by an en-dash is fine; set ALLOW_EMDASH=1 only to quote source text verbatim.)"
  log_warn "no-emdash-guard: denied write ($reason)"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  exit 0
fi

exit 0
