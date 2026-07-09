#!/usr/bin/env bash
# grok-run.sh — delegate a one-shot task to the grok CLI (xAI) from Claude Code.
#
# Verified against grok 0.2.93. Key safety facts:
#   * In headless mode, `grok -p ...` runs tools without a human to approve them, so it
#     EDITS FILES unless the write tools are removed. `--permission-mode` is NOT a reliable
#     guard here (tested: default/acceptEdits/auto/bypassPermissions/plan all wrote a canary
#     file; only `dontAsk` blocked it). If ~/.grok/config.toml sets permission_mode =
#     "always-approve" (or you pass --always-approve), edits happen with no prompt at all.
#     The ONLY robust read-only guard is a tool allowlist via `--tools` — used by review/research.
#   * A read-only agent asked to write will loop forever, so --max-turns is always set.
#
# Usage:
#   grok-run.sh review   "<prompt>" [extra grok args...]   # read-only, no web        (default)
#   grok-run.sh research "<prompt>" [extra grok args...]   # read-only + web_search/fetch
#   grok-run.sh fix      "<prompt>" [extra grok args...]   # AUTONOMOUS: edits files + shell
#
# Extra args pass straight through to grok, e.g.:
#   grok-run.sh review "..." -m grok-4.5 --cwd /path/to/repo --max-turns 40
#   grok-run.sh fix    "..." -w feat-x            # run in an isolated git worktree
#
# Env:
#   GROK_MODEL   default model (else grok's account default, currently grok-4.5)
#   GROK_MAXTURNS default max turns (default 30)
set -uo pipefail

MODE="${1:-review}"; shift || true
PROMPT="${1:-}"; shift || true

if [[ -z "$PROMPT" ]]; then
  echo "grok-run.sh: missing prompt. Usage: grok-run.sh <review|research|fix> \"<prompt>\" [args...]" >&2
  exit 2
fi

if ! command -v grok >/dev/null 2>&1; then
  echo "grok-run.sh: grok CLI not found on PATH. Install/login first (grok login)." >&2
  exit 127
fi

MAXTURNS="${GROK_MAXTURNS:-30}"
COMMON=(-p "$PROMPT" --output-format plain)

# grok errors on duplicate flags, so only inject defaults the caller did not already pass.
_extra="$* "
[[ "$_extra" != *"--max-turns "* ]] && COMMON+=(--max-turns "$MAXTURNS")
if [[ -n "${GROK_MODEL:-}" && "$_extra" != *"-m "* && "$_extra" != *"--model "* ]]; then
  COMMON+=(-m "$GROK_MODEL")
fi

case "$MODE" in
  review)
    # Read-only: only file-reading/search tools. No shell, no edits, no web.
    ARGS=(--tools "read_file,grep,list_dir" "${COMMON[@]}" "$@")
    ;;
  research)
    # Read-only + web. Still cannot edit files or run shell.
    ARGS=(--tools "read_file,grep,list_dir,web_search,web_fetch" "${COMMON[@]}" "$@")
    ;;
  fix)
    # AUTONOMOUS. grok gets its full toolset and auto-approves everything.
    # Prefer running with -w/--worktree so changes land in an isolated git worktree.
    ARGS=(--always-approve "${COMMON[@]}" "$@")
    ;;
  *)
    echo "grok-run.sh: unknown mode '$MODE' (use review|research|fix)" >&2
    exit 2
    ;;
esac

echo "[grok-run] mode=$MODE maxturns=$MAXTURNS model=${GROK_MODEL:-<account-default>}" >&2

OUT="$(grok "${ARGS[@]}" 2>/dev/null)"; RC=$?

if [[ $RC -ne 0 ]]; then
  echo "[grok-run] grok exited $RC. Partial output below (if any):" >&2
fi

# Empty output almost always means auth expired or a transport error — treat as failure.
if [[ -z "${OUT//[[:space:]]/}" ]]; then
  echo "[grok-run] FAILED: empty output. Check 'grok login' / network." >&2
  exit "${RC:-1}"
fi

printf '%s\n' "$OUT"
exit "$RC"
