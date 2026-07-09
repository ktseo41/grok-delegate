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
# Large prompts (e.g. instructions + a big `git diff`): pass "-" as the prompt to
# stream the whole thing from stdin. It goes to grok via --prompt-file, so it
# never hits ARG_MAX and grok gets it in full (no read_file pagination). The
# read-only guard is unchanged — only prompt delivery differs:
#   { echo "Review this diff:"; git -C /repo diff --staged; } | grok-run.sh review - --cwd /repo
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
COMMON=(--output-format plain)

# Prompt delivery: normally -p "<prompt>". If the prompt is "-", stream the whole
# thing from stdin into a temp file and hand it to grok via --prompt-file — lets a
# caller pipe instructions + a large `git diff` without hitting ARG_MAX, and grok
# receives it in full. This changes ONLY how the prompt is delivered; the --tools
# read-only guard below is untouched.
PROMPT_FILE=""
if [[ "$PROMPT" == "-" ]]; then
  PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/grok-prompt.XXXXXX")"
  trap 'rm -f "$PROMPT_FILE"' EXIT
  cat >"$PROMPT_FILE"
  if [[ ! -s "$PROMPT_FILE" ]]; then
    echo "grok-run.sh: prompt was '-' but stdin was empty. Pipe the prompt in, e.g. | grok-run.sh review -" >&2
    exit 2
  fi
  COMMON+=(--prompt-file "$PROMPT_FILE")
else
  COMMON+=(-p "$PROMPT")
fi

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

ERRFILE="$(mktemp)"
OUT="$(grok "${ARGS[@]}" 2>"$ERRFILE")"; RC=$?
ERR="$(cat "$ERRFILE")"; rm -f "$ERRFILE"

if [[ $RC -ne 0 ]]; then
  echo "[grok-run] grok exited $RC." >&2
fi

# Known grok 0.2.93 bug: adding a web tool to a --tools allowlist fails to build the session
# ("agent building failed: ... run_terminal_cmd ... auto_background_on_timeout"). This breaks
# research mode. Do NOT "fix" it by dropping the allowlist or switching to --disallowed-tools /
# --permission-mode: those build fine but re-enable file writes and shell (canary-verified), so
# the run would no longer be read-only. Fail closed instead — research returns once grok fixes it.
if grep -qiE 'agent building failed|auto_background_on_timeout' <<<"$ERR"; then
  if [[ "$MODE" == "research" ]]; then
    echo "[grok-run] FAILED: research mode is unavailable on this grok build (0.2.93)." >&2
    echo "[grok-run]   grok can't combine web tools with a read-only --tools allowlist" >&2
    echo "[grok-run]   (upstream session-build bug). Not worked around on purpose: dropping the" >&2
    echo "[grok-run]   allowlist would re-enable writes/shell. Use 'review' for read-only code work," >&2
    echo "[grok-run]   or (with the user's OK to let grok write) 'fix -w <name>' — it has web." >&2
  else
    echo "[grok-run] FAILED: grok could not build the session:" >&2
    printf '%s\n' "$ERR" | head -3 >&2
  fi
  # This branch is the wrapper's OWN "FAILED" verdict, so it must exit non-zero
  # even when grok itself returned 0 — empty output on an expired auth / transport
  # error can come back as exit 0. `${RC:-1}` did NOT do this: it only falls back
  # to 1 when RC is *unset*, and RC is always set by `RC=$?` above, so a grok 0
  # sailed straight through as a success code. Preserve a real non-zero grok code,
  # otherwise force 1.
  exit $(( RC == 0 ? 1 : RC ))
fi

# Empty output almost always means auth expired or a transport error — treat as failure.
if [[ -z "${OUT//[[:space:]]/}" ]]; then
  echo "[grok-run] FAILED: empty output. Check 'grok login' / network." >&2
  # This branch is the wrapper's OWN "FAILED" verdict, so it must exit non-zero
  # even when grok itself returned 0 — empty output on an expired auth / transport
  # error can come back as exit 0. `${RC:-1}` did NOT do this: it only falls back
  # to 1 when RC is *unset*, and RC is always set by `RC=$?` above, so a grok 0
  # sailed straight through as a success code. Preserve a real non-zero grok code,
  # otherwise force 1.
  exit $(( RC == 0 ? 1 : RC ))
fi

printf '%s\n' "$OUT"
exit "$RC"
