#!/usr/bin/env bash
# grok-run.sh — delegate a one-shot task to the grok CLI (xAI) from Claude Code.
#
# Canary-verified against grok 0.2.93; source-diff audits of 0.2.101→0.2.105 (2026-07-19)
# and 0.2.105→head a5727c596 (2026-07-22) found every surface this script depends on
# unchanged (allowlist enforcement, flags, web-tool names, "agent building failed" error
# text, unified.jsonl schema). The script invokes no removed flags — head dropped
# --check/--best-of-n from cli.rs, but this script never used them.
# Key safety facts:
#   * In headless mode, `grok -p ...` runs tools without a human to approve them, so it
#     EDITS FILES unless the write tools are removed. `--permission-mode` is NOT a reliable
#     guard here — every mode (default/acceptEdits/auto/bypassPermissions/plan AND dontAsk)
#     wrote a canary file in testing. An earlier run saw dontAsk not write, but that was an
#     incidental headless refusal, not a read-only guarantee: with a permission_mode =
#     "always-approve" config present, dontAsk writes too (verified on 0.2.93). If
#     ~/.grok/config.toml sets that (or you pass --always-approve), edits happen with no
#     prompt at all. The read-only guarantee rests on THREE independent layers (review/
#     research): (1) the `--sandbox read-only` KERNEL backstop — grok's OS-level sandbox
#     (seatbelt/landlock), which blocks writes even if the tool allowlist fails, and whose
#     own failure mode is CLOSED (an unknown profile name makes grok refuse to start).
#     CAVEAT (verified live on 0.2.111): the read-only profile deliberately keeps
#     TMPDIR//tmp and GROK_HOME writable (essential_writable_paths_minimal), so for a
#     working tree under a temp dir the kernel layer does not apply — layers 2+3 carry
#     it there. (2) the `--tools` allowlist, which removes write/shell tools — but
#     FAILS OPEN: one unresolvable name in the list makes grok keep the FULL toolset
#     (verified 0.2.99, issue #1), so it can never be the only guard; (3) a post-run
#     tripwire below that FAILS the run if signals.json shows a write/shell tool was
#     used anyway.
#   * A read-only agent asked to write will loop forever, so --max-turns is always set.
#
# Usage:
#   grok-run.sh review      "<prompt>" [extra grok args...]  # read-only, no web       (default)
#   grok-run.sh research    "<prompt>" [extra grok args...]  # read-only + web_search/fetch
#   grok-run.sh fix         "<prompt>" [extra grok args...]  # AUTONOMOUS: edits files + shell
#
# Self-verify gate (fix mode only): pass --verify "<cmd>" to make grok keep working
# until <cmd> succeeds. A Stop hook runs <cmd> each time grok is about to finish; while
# it fails, the failure is fed back and grok is forced to continue (grok caps at 8
# continuations per turn). Needs grok >= 0.2.111. The hook is injected into a throwaway
# GROK_HOME so it stays isolated under parallel fan-out. Slow builds: raise the hook
# timeout with GROK_VERIFY_TIMEOUT (default 600s; a timed-out gate fails open and lets
# grok stop). Example:
#   grok-run.sh fix "make the failing test pass" -w fix-x --verify "cargo test -q"
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
#   GROK_ALLOW_NOWEB=1  skip the web-collection gate (research runs that
#                make no web tool call normally FAIL — see the gate near the end)
#   GROK_VERIFY_TIMEOUT  Stop-hook gate timeout in seconds for --verify (default 600)
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

# --- Unified cleanup ------------------------------------------------------
# One EXIT trap owns every temp path the script creates (the streamed-prompt
# file and, for --verify, the throwaway GROK_HOME). Declared before anything
# that mktemps so a failure at any later point still tidies up. VERIFY_HOME is
# a directory of SYMLINKS into the real ~/.grok (plus one real hooks/ dir), so
# `rm -rf` removes the links, never their targets.
PROMPT_FILE=""
VERIFY_HOME=""
_cleanup() {
  [[ -n "$PROMPT_FILE" ]] && rm -f "$PROMPT_FILE"
  [[ -n "$VERIFY_HOME" ]] && rm -rf "$VERIFY_HOME"
}
trap _cleanup EXIT

# --- Extract the wrapper-only --verify flag -------------------------------
# `--verify <cmd>` is a grok-run.sh flag, NOT a grok flag, so it must be pulled
# out of the passthrough args before anything scans or forwards "$@" (grok would
# reject an unknown --verify). It arms a Stop-hook self-verify gate on `fix`
# mode: after each turn grok is about to end, the gate runs <cmd>; while <cmd>
# fails, the hook returns a `block` decision that feeds the failure back and
# makes grok keep working (grok's built-in cap ends the turn after 8
# continuations; a timed-out gate fails OPEN and lets grok stop). Restores and
# generalizes the removed `--check`. fix-only: the gate runs shell, so it must
# never touch the read-only review/research sandboxes.
VERIFY_CMD=""
_filtered_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      VERIFY_CMD="${2:-}"; shift 2 || { echo "grok-run.sh: --verify needs a command argument." >&2; exit 2; }
      ;;
    --verify=*)
      VERIFY_CMD="${1#*=}"; shift
      ;;
    *)
      _filtered_args+=("$1"); shift
      ;;
  esac
done
set -- "${_filtered_args[@]:+${_filtered_args[@]}}"

# Version detection. Two consumers: (a) the --verify >= 0.2.111 hard gate below (a Stop
# hook's block/continuation mechanism did not exist at 0.2.101 and is confirmed working
# on 0.2.111, so --verify refuses anything older or unparseable), and (b) a soft startup
# advisory for grok < 0.2.98 (the old allowlist+web session-build bug — fixed upstream,
# but a caller still running an old build benefits from a nudge to update). Parsing is
# best-effort: any failure to run/parse `grok --version` leaves GROK_VERSION empty; an
# empty version means no advisory here (nothing to warn about) — --verify has its own,
# separate refusal for an empty version, since a hard gate cannot assume support.
_grok_ver_lt() {
  # $1 < $2 for dotted a.b.c triples, numeric field by field. Ignores anything after
  # the third field (e.g. build metadata) — good enough for this gate, not a general
  # semver library.
  local a1 a2 a3 b1 b2 b3
  IFS='.' read -r a1 a2 a3 _ <<<"$1"
  IFS='.' read -r b1 b2 b3 _ <<<"$2"
  a1=${a1:-0} a2=${a2:-0} a3=${a3:-0}
  b1=${b1:-0} b2=${b2:-0} b3=${b3:-0}
  if (( a1 != b1 )); then (( a1 < b1 )); return; fi
  if (( a2 != b2 )); then (( a2 < b2 )); return; fi
  (( a3 < b3 ))
}
GROK_VERSION=""
if _grok_ver_raw="$(grok --version 2>/dev/null)"; then
  GROK_VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$_grok_ver_raw" | head -1)"
fi
# Soft version floor. The pre-0.2.98 allowlist+web session-build bug is fixed upstream;
# nothing below special-cases old builds anymore, so just warn once at startup.
if [[ -n "$GROK_VERSION" ]] && _grok_ver_lt "$GROK_VERSION" "0.2.98"; then
  echo "[grok-run] WARNING: grok $GROK_VERSION < 0.2.98 — research may fail its session build (old allowlist+web bug). Run 'grok update'." >&2
fi

# --verify validation. Two hard gates:
#   * Mode: fix only. The gate runs shell (<cmd>), so it must never be attached to
#     the read-only review/research sandboxes — that would smuggle shell in through
#     a "verify" flag.
#   * Version: the Stop-hook block/continuation mechanism this relies on did NOT exist
#     at 0.2.101 (source-verified: no Block decision, Stop dispatched non-blocking) and
#     is confirmed present + working headless on 0.2.111 (empirical smoke test). A Stop
#     hook on an older build fails OPEN — grok would stop without ever verifying, and the
#     caller would wrongly believe the gate ran. Refuse rather than silently skip. An
#     unparseable/empty version is refused too (can't confirm support).
VERIFY_ENABLED=0
if [[ -n "${VERIFY_CMD//[[:space:]]/}" ]]; then
  if [[ "$MODE" != "fix" ]]; then
    echo "grok-run.sh: --verify is only valid in 'fix' mode (it runs shell, so it cannot go in the" >&2
    echo "  read-only review/research sandboxes). Re-run as: grok-run.sh fix \"<prompt>\" --verify \"<cmd>\"" >&2
    exit 2
  fi
  if [[ -z "$GROK_VERSION" ]] || _grok_ver_lt "$GROK_VERSION" "0.2.111"; then
    echo "grok-run.sh: --verify needs grok >= 0.2.111 (Stop-hook self-verify; verified working there)." >&2
    echo "  Detected: ${GROK_VERSION:-unknown}. On older builds a Stop hook fails open, so the gate would" >&2
    echo "  silently NOT verify. Run 'grok update' first, then retry." >&2
    exit 2
  fi
  VERIFY_ENABLED=1
fi

MAXTURNS="${GROK_MAXTURNS:-30}"
COMMON=(--output-format plain)

# Web-mode prompt guard (research).
#   * Collection rules: no circumventing bot protection (observed on a real run: a
#     web-mode worker used run_terminal_command to get around a 403 — exactly the
#     unattended-shell behavior this skill exists to prevent), retry blocked sites via
#     domain-limited web_search instead of more fetches (a fetch-retry against a
#     blocked site cost 3x the median run), and verbatim quote + URL per claim so
#     downstream verification stays cheap.
# This is a plain prompt prefix — it does NOT touch the --tools sandbox. It applies to
# both -p and --prompt-file paths.
GUARD=""
case "$MODE" in
  research)
    GUARD='[수집 규칙] 사이트가 fetch를 차단하면(403·봇 방어) 우회하지 마라 — User-Agent 위장, 터미널/셸을 통한 fetch, 프록시 경유 전부 금지다. 대신 그 도메인으로 한정한 web_search로 같은 정보를 찾고, 그래도 확인이 안 되면 그 항목을 "미확인"으로 명시해서 보고하라. 사실 주장에는 원문 축자 인용과 출처 URL을 붙여라.'
    ;;
esac

# Prompt delivery: normally -p "<prompt>". If the prompt is "-", stream the whole
# thing from stdin into a temp file and hand it to grok via --prompt-file — lets a
# caller pipe instructions + a large `git diff` without hitting ARG_MAX, and grok
# receives it in full. This changes ONLY how the prompt is delivered; the --tools
# read-only guard below is untouched. In research mode the web GUARD above is
# prepended to whichever delivery path is used.
if [[ "$PROMPT" == "-" ]]; then
  PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/grok-prompt.XXXXXX")"  # cleaned by the unified EXIT trap
  cat >"$PROMPT_FILE"
  if [[ ! -s "$PROMPT_FILE" ]]; then
    echo "grok-run.sh: prompt was '-' but stdin was empty. Pipe the prompt in, e.g. | grok-run.sh review -" >&2
    exit 2
  fi
  if [[ -n "$GUARD" ]]; then
    # Prepend the guard as the first lines of the streamed prompt file.
    { printf '%s\n\n' "$GUARD"; cat "$PROMPT_FILE"; } >"$PROMPT_FILE.g" && mv "$PROMPT_FILE.g" "$PROMPT_FILE"
  fi
  COMMON+=(--prompt-file "$PROMPT_FILE")
else
  if [[ -n "$GUARD" ]]; then
    COMMON+=(-p "$GUARD"$'\n\n'"$PROMPT")
  else
    COMMON+=(-p "$PROMPT")
  fi
fi

# grok errors on duplicate flags, so only inject defaults the caller did not already
# pass. Scan the actual argv TOKENS (not a joined string): a joined-string substring
# test both missed the equals form (`--max-turns=40` -> default injected too ->
# duplicate flag -> grok errors) and false-matched a flag name that merely appeared
# inside another arg's value (`--system-prompt "...--max-turns..."` -> default skipped
# -> the read-only turn cap silently lost). Token + equals matching fixes both.
_has_maxturns=0 _has_model=0 _has_session=0
# Also capture the EFFECTIVE turn cap for the log line below. Logging the unused
# env default misled a real run: a `--max-turns 120` call still printed
# "maxturns=30", making the log claim a cap the run did not have.
_maxturns_eff="$MAXTURNS"
_prev=""
for _a in "$@"; do
  case "$_a" in
    --max-turns=*)                      _has_maxturns=1; _maxturns_eff="${_a#*=}" ;;
    --max-turns)                        _has_maxturns=1 ;;
    -m|-m=*|--model|--model=*)          _has_model=1 ;;
    # Any caller-supplied session control means we must NOT invent our own SID.
    -s|-s=*|--session-id|--session-id=*|-r|-r=*|--resume|--resume=*|-c|-c=*|--continue|--continue=*) _has_session=1 ;;
  esac
  [[ "$_prev" == "--max-turns" ]] && _maxturns_eff="$_a"
  _prev="$_a"
done
[[ "$_has_maxturns" -eq 0 ]] && COMMON+=(--max-turns "$MAXTURNS")
if [[ -n "${GROK_MODEL:-}" && "$_has_model" -eq 0 ]]; then
  COMMON+=(-m "$GROK_MODEL")
fi

# Pin a known session id so we can locate this run's signals.json afterwards for the
# usage trailer (below). Without a fixed id, a "most recent session dir" heuristic
# races under parallel fan-out and can read the wrong session's numbers. Only inject
# when the caller passed no session flag of their own, and only if uuidgen is around;
# the trailer is best-effort, so a missing SID just skips it, never fails the run.
GROK_SID=""
if [[ "$_has_session" -eq 0 ]] && command -v uuidgen >/dev/null 2>&1; then
  GROK_SID="$(uuidgen | tr 'A-Z' 'a-z')"
  COMMON+=(-s "$GROK_SID")
fi

case "$MODE" in
  review)
    # Read-only: only file-reading/search tools (lsp = read-only symbol/diagnostic
    # lookup, is_read_only in grok source). No shell, no edits, no web.
    # --sandbox read-only is the KERNEL backstop: the --tools allowlist FAILS OPEN if
    # any name stops resolving (grok keeps the full toolset — verified, issue #1),
    # while the sandbox blocks writes at the OS level and FAILS CLOSED (an unknown
    # profile name makes grok refuse to start). Verified on 0.2.111 — including the
    # caveat that temp paths (TMPDIR//tmp) and GROK_HOME stay writable by design, so
    # the kernel layer covers real working trees, not temp-dir ones (see header).
    ARGS=(--tools "read_file,grep,list_dir,lsp" --sandbox read-only "${COMMON[@]}" "$@")
    ;;
  research)
    # Read-only + web. Still cannot edit files or run shell. Same --sandbox read-only
    # kernel backstop as review — verified on 0.2.111 that it does NOT break the web
    # tools (they are backend-hosted, so the local network restriction doesn't apply).
    ARGS=(--tools "read_file,grep,list_dir,web_search,web_fetch" --sandbox read-only "${COMMON[@]}" "$@")
    ;;
  fix)
    # AUTONOMOUS. grok gets its full toolset and auto-approves everything.
    # Prefer running with -w/--worktree so changes land in an isolated git worktree.
    # Warn (don't block — in-place fixes are sometimes intentional) when no worktree
    # is requested, since fix then edits the working tree at --cwd directly.
    _has_worktree=0
    for _a in "$@"; do
      case "$_a" in -w|-w=*|--worktree|--worktree=*) _has_worktree=1 ;; esac
    done
    if [[ "$_has_worktree" -eq 0 ]]; then
      echo "[grok-run] WARNING: fix auto-approves edits + shell and no -w/--worktree was given," >&2
      echo "[grok-run]   so grok acts directly on the working tree at --cwd. Prefer 'fix ... -w" >&2
      echo "[grok-run]   <name>' to isolate changes for review. Note: a worktree branches from" >&2
      echo "[grok-run]   HEAD, so commit or stash uncommitted work first or grok won't see it." >&2
    fi
    ARGS=(--always-approve "${COMMON[@]}" "$@")
    ;;
  *)
    echo "grok-run.sh: unknown mode '$MODE' (use review|research|fix)" >&2
    exit 2
    ;;
esac

# --- Arm the --verify self-verify gate (fix mode, >= 0.2.111) ---------------
# Build a throwaway GROK_HOME so the injected Stop hook is isolated (safe under
# parallel fan-out) and never pollutes the user's ~/.grok/hooks. The real home is
# mirrored in by SYMLINK (auth, config, bundled catalog, sessions…) so grok
# authenticates and builds a session normally; only hooks/ is a real dir we own.
# Same per-worker minimal-home pattern the deepseek harness uses; validated
# end-to-end by the headless smoke test.
if [[ "$VERIFY_ENABLED" -eq 1 ]]; then
  _src_home="${GROK_HOME:-$HOME/.grok}"
  VERIFY_HOME="$(mktemp -d "${TMPDIR:-/tmp}/grok-verify-home.XXXXXX")"
  # Mirror every real-home entry except hooks/, which we provide ourselves. Any
  # global hooks the user has are intentionally NOT inherited for this run — the
  # gate must be the only Stop hook, or a user hook could allow the stop early.
  shopt -s dotglob nullglob
  for _entry in "$_src_home"/*; do
    _base="$(basename "$_entry")"
    [[ "$_base" == "hooks" ]] && continue
    ln -s "$_entry" "$VERIFY_HOME/$_base" 2>/dev/null
  done
  shopt -u dotglob nullglob
  mkdir -p "$VERIFY_HOME/hooks"

  # The user's <cmd> verbatim in its own file; the gate execs it with `sh`, so no
  # shell-quoting of <cmd> is needed and it can be a full pipeline.
  _cmdfile="$VERIFY_HOME/hooks/verify-cmd.sh"
  printf '%s\n' "$VERIFY_CMD" >"$_cmdfile"

  # The gate script. Only gates real turn-ends ("reason":"end_turn" — camelCase,
  # confirmed from the live headless payload); cd's into the payload cwd so <cmd>
  # runs where grok is editing (the worktree/--cwd); blocks with the failure tail
  # fed back when <cmd> is red, allows the stop when green. jq encodes the reason
  # safely; a static reason is the fallback when jq is absent.
  _gate="$VERIFY_HOME/hooks/verify.sh"
  {
    printf '#!/bin/sh\n'
    printf 'CMDFILE=%q\n' "$_cmdfile"
    cat <<'GATE_EOF'
INPUT=$(cat)
case "$INPUT" in
  *'"reason":"end_turn"'*) ;;
  *) exit 0 ;;
esac
CWD=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')
[ -n "$CWD" ] && cd "$CWD" 2>/dev/null
OUT=$( { sh "$CMDFILE"; } 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && exit 0
MSG="grok-delegate --verify: the gate command exited $RC. Fix the errors and finish only when it passes.
Gate output (tail):
$(printf '%s' "$OUT" | tail -n 40)"
if command -v jq >/dev/null 2>&1; then
  REASON=$(printf '%s' "$MSG" | jq -Rs .)
else
  REASON='"grok-delegate --verify: gate command failed; fix the errors before finishing."'
fi
printf '{"decision":"block","reason":%s}\n' "$REASON"
exit 0
GATE_EOF
  } >"$_gate"
  chmod +x "$_gate"

  # A timed-out Stop hook fails OPEN (grok stops without verifying), so the timeout
  # must comfortably exceed the gate command's runtime. Default 600s; override with
  # GROK_VERIFY_TIMEOUT for slow builds.
  _vtimeout="${GROK_VERIFY_TIMEOUT:-600}"
  printf '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "%s", "timeout": %s } ] } ] } }\n' \
    "$_gate" "$_vtimeout" >"$VERIFY_HOME/hooks/verify.json"

  export GROK_HOME="$VERIFY_HOME"
  echo "[grok-run] --verify armed: Stop-hook gate runs \`$VERIFY_CMD\` (timeout ${_vtimeout}s); grok keeps" >&2
  echo "[grok-run]   working until it passes (grok caps at 8 continuations/turn). Isolated GROK_HOME." >&2
fi

echo "[grok-run] mode=$MODE maxturns=$_maxturns_eff model=${GROK_MODEL:-<account-default>}" >&2

# Wrapped so the build-error retry below (research mode) can invoke the exact same grok
# call a second time and land its OUT/ERR/RC in the same variables the rest of the
# script already reads.
_run_grok_once() {
  local errfile
  errfile="$(mktemp)"
  OUT="$(grok "${ARGS[@]}" 2>"$errfile")"; RC=$?
  ERR="$(cat "$errfile")"; rm -f "$errfile"
}
_is_build_error() { grep -qiE 'agent building failed|auto_background_on_timeout' <<<"$1"; }

_run_grok_once

# One unconditional automatic retry for research build errors. On current builds the
# old deterministic allowlist+web bug is fixed, so a build error is presumed transient —
# a short sleep lets a backend/rate-limit blip clear before the retry.
BUILD_ERROR_RETRIED=0
if _is_build_error "$ERR" && [[ "$MODE" == "research" ]]; then
  echo "[grok-run] research hit a session-build error; retrying once after a short wait..." >&2
  sleep 3
  # Reuse the SID we own (only when we generated it ourselves — a caller-supplied
  # session flag is never touched) so the retry's usage trailer below is findable, but
  # mint a FRESH id: the first attempt's session never finished building, so replaying
  # the same SID would have the retry collide with a half-built (or nonexistent)
  # session dir instead of getting a clean one.
  if [[ -n "$GROK_SID" && "$_has_session" -eq 0 ]] && command -v uuidgen >/dev/null 2>&1; then
    _new_sid="$(uuidgen | tr 'A-Z' 'a-z')"
    for _i in "${!ARGS[@]}"; do
      if [[ "${ARGS[$_i]}" == "-s" ]] && [[ $((_i + 1)) -lt "${#ARGS[@]}" ]] && [[ "${ARGS[$((_i + 1))]}" == "$GROK_SID" ]]; then
        ARGS[$((_i + 1))]="$_new_sid"
        break
      fi
    done
    GROK_SID="$_new_sid"
  fi
  _run_grok_once
  BUILD_ERROR_RETRIED=1
fi

# grok usage trailer (best-effort). The whole point of delegating is to spend xAI
# quota instead of Claude's, but a plain run surfaces NONE of grok's own usage — the
# only numbers a courier sees are its own (Claude) tokens. Read this run's signals.json
# (located by the SID we pinned above) and print grok's real usage to stderr so it lands
# in the courier's summary. Fires on every exit path, including FAILED, so a wasted run
# still reports what it burned. Never affects the run: any missing tool/file is skipped.
GROK_TOOLSUSED="" GROK_HAVE_SIGNALS=0
if [[ -n "$GROK_SID" ]] && command -v jq >/dev/null 2>&1; then
  # Respect an effective GROK_HOME (a caller's, or the throwaway one --verify exports)
  # so the usage trailer finds this run's session dir. Under --verify the home's
  # sessions/ is a SYMLINK to the real one, so `find -L` is required to dereference
  # the start path and descend into it (plain find treats a symlinked start dir as a
  # file and matches nothing — which made the trailer wrongly print "no signals").
  _sigdir="$(find -L "${GROK_HOME:-$HOME/.grok}/sessions" -maxdepth 2 -type d -name "$GROK_SID" 2>/dev/null | head -1)"
  if [[ -n "$_sigdir" && -f "$_sigdir/signals.json" ]]; then
    # Keep the tool list around for the web-collection gate below.
    GROK_TOOLSUSED="$(jq -r '(.toolsUsed // []) | join(",")' "$_sigdir/signals.json" 2>/dev/null)" && GROK_HAVE_SIGNALS=1
    jq -r '"[grok-usage] ctxTokens=\(.contextTokensUsed // "?") "
      + "wallSec=\(.sessionDurationSeconds // "?") "
      + "toolCalls=\(.toolCallCount // "?") "
      + "tools=\((.toolsUsed // []) | join(",") | if . == "" then "-" else . end) "
      + "session='"${GROK_SID:0:8}"'"' \
      "$_sigdir/signals.json" >&2 2>/dev/null \
      || echo "[grok-usage] (signals.json unreadable; session=${GROK_SID:0:8})" >&2
  else
    # A run that dies before grok builds a session (auth failure, session-build bug,
    # transport error) leaves no signals.json at all. Say so explicitly instead of
    # skipping silently, so a courier never mistakes "no trailer" for "no cost" —
    # observed on a real fan-out where the one failed worker was the only run with
    # no usage line.
    echo "[grok-usage] (no signals.json — run likely failed before a session was built; session=${GROK_SID:0:8})" >&2
  fi
fi

if [[ $RC -ne 0 ]]; then
  echo "[grok-run] grok exited $RC." >&2
fi

# Build-error branch. On any current (0.2.98+) build the old 0.2.93 allowlist+web
# session-build bug is fixed upstream, so this stderr text is almost always a
# transient backend/rate-limit error — research already retried once above. Report
# and fail closed; never "fix" it by weakening the read-only guard.
if _is_build_error "$ERR"; then
  if [[ "$BUILD_ERROR_RETRIED" -eq 1 ]]; then
    echo "[grok-run] FAILED: grok failed to build the session twice (retried once after 3s)." >&2
  else
    echo "[grok-run] FAILED: grok could not build the session:" >&2
    printf '%s\n' "$ERR" | head -3 >&2
  fi
  echo "[grok-run]   Most likely a transient backend/rate-limit error — retry later. If it keeps" >&2
  echo "[grok-run]   recurring and your grok is old (< 0.2.98), run 'grok update' first. If it still" >&2
  echo "[grok-run]   persists, and only with the user's explicit OK to let grok hold write+shell," >&2
  echo "[grok-run]   'fix -w <name>' (isolated worktree) has web tools. Do NOT work around this by" >&2
  echo "[grok-run]   dropping the --tools allowlist or using --disallowed-tools/--permission-mode —" >&2
  echo "[grok-run]   those re-enable file writes and shell (canary-verified), which is not an" >&2
  echo "[grok-run]   acceptable substitute for the read-only sandbox." >&2
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

# Web-collection gate (research). A web-mode run that never called a
# web tool "researched" from model memory: on a real 12-worker fan-out, 4 workers
# returned exit 0 with plausible, normal-sized, entirely uncollected output — the
# usage trailer's tool list was the ONLY signal (nothing in exit code, size, or the
# text itself). Enforce the check here so every caller gets it, not just one that
# remembers to parse the trailer. The body is still printed (below) so nothing is
# lost, but the exit code says "do not use this as research". Best-effort like the
# trailer: without signals.json the gate cannot judge and stays silent. Retries of a
# gated run recover only ~1 in 4 — prefer one retry that explicitly demands web_fetch
# per claim, then collect the facts yourself. GROK_ALLOW_NOWEB=1 skips the gate for a
# deliberately memory-only run through a web mode.
#
# Tool-name matching: signals.json reports web collection under TWO naming schemes,
# and the gate must accept both or it false-fails a run that actually collected. The
# LOCAL function tools appear snake_case (web_search / web_fetch); the BACKEND-hosted
# tools — the default since backend search was enabled by default (grok 0.2.98+, which
# also fixed research building at all) — appear PascalCase (WebSearch / WebFetch),
# verified live on 0.2.99 where a real research run reported toolsUsed=["WebFetch",
# "WebSearch"] yet the old case-sensitive snake-only regex marked it "no web tool
# call". So match case-insensitively (-i) with an optional underscore (web[_]?...).
if [[ "$MODE" == "research" ]] \
   && [[ "$GROK_HAVE_SIGNALS" -eq 1 && "${GROK_ALLOW_NOWEB:-0}" != "1" ]] \
   && ! grep -qiE '(^|,)web[_]?(search|fetch)(,|$)' <<<"$GROK_TOOLSUSED"; then
  echo "[grok-run] FAILED: $MODE run made no web tool call (tools=${GROK_TOOLSUSED:--})." >&2
  echo "[grok-run]   The output was produced without any web collection — treat it as recalled" >&2
  echo "[grok-run]   from model memory, not research. It is still printed to stdout for" >&2
  echo "[grok-run]   inspection, but the non-zero exit means: do not relay it as verified fact." >&2
  echo "[grok-run]   Retry once demanding web_fetch + verbatim quote per claim, or collect" >&2
  echo "[grok-run]   directly. GROK_ALLOW_NOWEB=1 bypasses this gate on purpose." >&2
  printf '%s\n' "$OUT"
  exit $(( RC == 0 ? 1 : RC ))
fi

# Read-only tripwire (review / research). Layer 3 of the read-only guarantee: if this
# run's signals.json shows a write/shell/subagent tool was actually USED, the read-only
# sandboxes failed — turn that silent fail-open into a detected, non-zero-exit failure.
# The names are captured from REAL signals.json files plus the grok source's alias
# table (claude_alias.rs), across BOTH naming schemes the web gate already learned
# about: grok-native snake_case (run_terminal_command, search_replace, write,
# hashline_edit, spawn_subagent) and PascalCase (Bash, Write, Edit, Task…) — matched
# case-insensitively with the same token anchoring as the web gate. NOTE the real
# shell name is run_terminal_command, NOT the run_terminal_cmd that appears in grok's
# old error text. Best-effort like the trailer: no signals.json => cannot judge, stay
# silent. No bypass env on purpose — a read-only mode that ran write/shell is never
# legitimate. The body is still printed for inspection.
if [[ "$MODE" == "review" || "$MODE" == "research" ]] \
   && [[ "$GROK_HAVE_SIGNALS" -eq 1 ]] \
   && grep -qiE '(^|,)(run_terminal_command|run_terminal_cmd|bash|shell|powershell|write|write_file|search_replace|hashline_edit|edit|multiedit|task|spawn_subagent|agent)(,|$)' <<<"$GROK_TOOLSUSED"; then
  echo "[grok-run] FAILED: read-only $MODE run USED a write/shell tool (tools=${GROK_TOOLSUSED:--})." >&2
  echo "[grok-run]   The --tools allowlist and the --sandbox backstop both failed to hold — this" >&2
  echo "[grok-run]   run had write/shell despite being a read-only mode. Treat the working tree as" >&2
  echo "[grok-run]   possibly modified: inspect 'git status' before trusting it. The output is" >&2
  echo "[grok-run]   printed for inspection, but the non-zero exit means: do not treat this as a" >&2
  echo "[grok-run]   read-only run. Check grok's version/flags (allowlist names resolve? --sandbox" >&2
  echo "[grok-run]   supported?) and re-run evals/canary.sh before delegating again." >&2
  printf '%s\n' "$OUT"
  exit $(( RC == 0 ? 1 : RC ))
fi

printf '%s\n' "$OUT"
exit "$RC"
