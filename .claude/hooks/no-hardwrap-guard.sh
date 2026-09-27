#!/usr/bin/env bash
# PreToolUse(Write|Edit) hook. Hard deny on hard-wrapped prose in authored
# Markdown.
#
# The user's standing rule (rules/no-hardwrapped-writing.md) forbids hard-wrapping
# prose in authored Markdown: every paragraph and every list item must be a
# single physical line, left for the editor to soft-wrap. Real line breaks are
# allowed only at blank lines between blocks, headings, separate list items,
# table rows, code fences, and blockquotes. A text rule is advisory; this hook
# makes the violation impossible for file writes.
#
# Detection: two adjacent non-blank lines, neither of which is a heading,
# table row, horizontal rule, blockquote line, or the start of a new list item,
# are the same CommonMark paragraph (lazy continuation) or the same list item
# continuation. Under the rule that is always a violation, regardless of
# column width, so no line-length heuristic is needed. Lines inside fenced
# code blocks are skipped entirely.
#
# Scope: only fires for `*.md` files (the rule is explicitly about authored
# Markdown); Write's `content` and Edit's `new_string` are scanned.
#
# Escape hatch: set ALLOW_HARDWRAP=1 in the session environment for the rare
# legitimate case (importing a fixture, quoting source text verbatim).
#
# Emits a single JSON object on stdout per Claude Code's hook protocol.

set -u
trap 'exit 0' ERR
[ "${RUNTIME_HOOKS_DISABLE:-0}" = "1" ] && exit 0
[ "${ALLOW_HARDWRAP:-0}" = "1" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$HOOK_DIR/lib/log.sh"

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

# Extract the target file_path and the newly authored text (Write's `content`
# or Edit's `new_string`) in one python pass, NUL-separated so real newlines
# inside the text survive intact.
fields="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
print(ti.get("file_path") or "")
parts = []
for k in ("content", "new_string"):
    v = ti.get(k)
    if isinstance(v, str):
        parts.append(v)
print("\x00".join(parts), end="")
' 2>/dev/null || true)"
file_path="$(printf '%s\n' "$fields" | head -n1)"
text="$(printf '%s\n' "$fields" | tail -n +2)"
text="${text//$'\x00'/$'\n'}"

[ -n "$file_path" ] || exit 0

case "$file_path" in
  *.md) ;;
  *) exit 0 ;;
esac

[ -n "$text" ] || exit 0

# Run the shared detector (hooks/lib/prose-detect.py) so this guard and the
# git pre-commit backstop apply exactly one hard-wrap detection implementation.
# The payload mode scans an Edit's new_string in the context of the target
# file, so a fragment that starts inside a code fence is not read as prose.
reason="$(printf '%s' "$payload" | python3 "$HOOK_DIR/lib/prose-detect.py" hardwrap-payload 2>/dev/null || true)"

if [ -n "$reason" ]; then
  msg="Hard-wrapped prose in $(basename "$file_path") (line starting \"$reason\"). The no-hard-wrap rule is absolute (rules/no-hardwrapped-writing.md): write each paragraph and list item as one line and let the editor soft-wrap. Break lines only at blank lines between blocks, headings, separate list items, table rows, code fences, or blockquotes. Set ALLOW_HARDWRAP=1 only to quote source text verbatim."
  log_warn "no-hardwrap-guard: denied write to $file_path (wrapped: $reason)"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  exit 0
fi

exit 0
