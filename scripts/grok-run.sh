#!/usr/bin/env bash
# grok-run.sh — delegate a one-shot task to the grok CLI (xAI) from Claude Code.
#
# Verified against grok 0.2.93. Key safety facts:
#   * In headless mode, `grok -p ...` runs tools without a human to approve them, so it
#     EDITS FILES unless the write tools are removed. `--permission-mode` is NOT a reliable
#     guard here — every mode (default/acceptEdits/auto/bypassPermissions/plan AND dontAsk)
#     wrote a canary file in testing. An earlier run saw dontAsk not write, but that was an
#     incidental headless refusal, not a read-only guarantee: with a permission_mode =
#     "always-approve" config present, dontAsk writes too (verified on 0.2.93). If
#     ~/.grok/config.toml sets that (or you pass --always-approve), edits happen with no
#     prompt at all. The ONLY robust read-only guard is a tool allowlist via `--tools` —
#     used by review/research.
#   * A read-only agent asked to write will loop forever, so --max-turns is always set.
#
# Usage:
#   grok-run.sh review      "<prompt>" [extra grok args...]  # read-only, no web       (default)
#   grok-run.sh research    "<prompt>" [extra grok args...]  # read-only + web_search/fetch
#   grok-run.sh research-rw "<prompt>" [extra grok args...]  # web WITHOUT the read-only
#                                    # sandbox (needs user OK) — runs like fix, pointed at a
#                                    # throwaway temp dir unless --cwd is given. For repo-less
#                                    # web research on OLD grok builds (< 0.2.98, where `research`
#                                    # fails closed) or when session-build failures persist.
#   grok-run.sh fix         "<prompt>" [extra grok args...]  # AUTONOMOUS: edits files + shell
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
#   GROK_ALLOW_NOWEB=1  skip the web-collection gate (research/research-rw runs that
#                make no web tool call normally FAIL — see the gate near the end)
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

# Version gate for the build-error branch further down. The 0.2.93 "agent building
# failed" bug (a --tools allowlist can't combine with a web tool) was fixed upstream
# in 0.2.98 (CHANGELOG 2026-07-12: "Web search and X search no longer fail when both a
# local function tool and the backend hosted tool are active"). Below 0.2.98 the same
# stderr text still means that bug; at/above it, the bug is structurally impossible, so
# the same text is almost always a transient backend/rate-limit error instead. Parsing
# is best-effort: any failure to run/parse `grok --version` leaves GROK_VERSION empty,
# and an empty version is treated like ">= 0.2.98" (i.e. do NOT assume the old bug) —
# asserting a stale diagnosis on an unknown version is worse than assuming the fix.
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
VERSION_BUG_POSSIBLE=0
if [[ -n "$GROK_VERSION" ]] && _grok_ver_lt "$GROK_VERSION" "0.2.98"; then
  VERSION_BUG_POSSIBLE=1
fi

MAXTURNS="${GROK_MAXTURNS:-30}"
COMMON=(--output-format plain)

# Web-mode prompt guard (research and research-rw). Two parts:
#   * Citation-loop guard: grok 0.2.93 can leak its internal citation sentinel
#     (`_end_of_render_inline_citation`) into the output stream and repeat the closing
#     marker forever — one observed run spewed 290k chars over 9 min before it was
#     killed. The trigger is web-search citation rendering, so it applies to any
#     web-enabled run. An explicit "no inline citation markers" rule suppresses it
#     (verified).
#   * Collection rules: no circumventing bot protection (observed on a real run: a
#     research-rw worker used run_terminal_command to get around a 403 — exactly the
#     unattended-shell behavior this skill exists to prevent), retry blocked sites via
#     domain-limited web_search instead of more fetches (a fetch-retry against a
#     blocked site cost 3x the median run), and verbatim quote + URL per claim so
#     downstream verification stays cheap.
# This is a plain prompt prefix — it does NOT touch the --tools sandbox (research) and
# is NOT a sandbox itself (research-rw). It applies to both -p and --prompt-file paths.
GUARD=""
case "$MODE" in
  research|research-rw)
    GUARD='[출력 규칙] 인라인 인용 마커나 각주 sentinel 토큰(예: _end_of_render_inline_citation)을 본문에 절대 쓰지 마라. 근거 URL은 리포트 맨 끝의 "출처" 목록에 평범한 마크다운 링크로만 모아라. 같은 문구·마커를 반복해서 출력하지 마라.
[수집 규칙] 사이트가 fetch를 차단하면(403·봇 방어) 우회하지 마라 — User-Agent 위장, 터미널/셸을 통한 fetch, 프록시 경유 전부 금지다. 대신 그 도메인으로 한정한 web_search로 같은 정보를 찾고, 그래도 확인이 안 되면 그 항목을 "미확인"으로 명시해서 보고하라. 사실 주장에는 원문 축자 인용과 출처 URL을 붙여라.'
    ;;
esac

# Prompt delivery: normally -p "<prompt>". If the prompt is "-", stream the whole
# thing from stdin into a temp file and hand it to grok via --prompt-file — lets a
# caller pipe instructions + a large `git diff` without hitting ARG_MAX, and grok
# receives it in full. This changes ONLY how the prompt is delivered; the --tools
# read-only guard below is untouched. In research mode the citation GUARD above is
# prepended to whichever delivery path is used.
PROMPT_FILE=""
if [[ "$PROMPT" == "-" ]]; then
  PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/grok-prompt.XXXXXX")"
  trap 'rm -f "$PROMPT_FILE"' EXIT
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
    # Read-only: only file-reading/search tools. No shell, no edits, no web.
    ARGS=(--tools "read_file,grep,list_dir" "${COMMON[@]}" "$@")
    ;;
  research)
    # Read-only + web. Still cannot edit files or run shell.
    ARGS=(--tools "read_file,grep,list_dir,web_search,web_fetch" "${COMMON[@]}" "$@")
    ;;
  research-rw)
    # Web research WITHOUT the read-only sandbox — the sanctioned fallback for OLD grok
    # builds (< 0.2.98, which cannot combine web tools with a --tools allowlist — research
    # fails closed there) or for a session-build failure that persists after the
    # automatic retry (see the build-error branch below). Runs like fix (--always-approve,
    # full toolset incl. shell), so it REQUIRES the
    # user's explicit OK, same as fix. Unless the caller passed --cwd, the run is
    # pointed at a fresh throwaway temp dir so stray writes land nowhere that matters.
    # That isolation is ADVISORY ONLY: grok keeps shell and can reach outside the cwd
    # (the canary suite's out-of-cwd vector demonstrates this class of escape). The
    # prompt GUARD above forbids shell-based fetch and UA spoofing, but a prompt is
    # not a sandbox. The temp dir is left in place after the run for inspection.
    _has_cwd=0
    for _a in "$@"; do
      case "$_a" in --cwd|--cwd=*) _has_cwd=1 ;; esac
    done
    ARGS=(--always-approve "${COMMON[@]}" "$@")
    if [[ "$_has_cwd" -eq 0 ]]; then
      RW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/grok-research-rw.XXXXXX")"
      ARGS+=(--cwd "$RW_DIR")
      echo "[grok-run] research-rw: throwaway cwd $RW_DIR (kept after the run for inspection)." >&2
    else
      echo "[grok-run] research-rw: using caller-supplied --cwd." >&2
    fi
    echo "[grok-run] research-rw is NOT read-only: grok holds write+shell; the temp-dir/cwd" >&2
    echo "[grok-run]   isolation is advisory only. Use only with the user's explicit OK." >&2
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
    echo "grok-run.sh: unknown mode '$MODE' (use review|research|research-rw|fix)" >&2
    exit 2
    ;;
esac

echo "[grok-run] mode=$MODE maxturns=$_maxturns_eff model=${GROK_MODEL:-<account-default>}" >&2

# Wrapped so the build-error retry below (research mode, >= 0.2.98/unknown version) can
# invoke the exact same grok call a second time and land its OUT/ERR/RC in the same
# variables the rest of the script already reads.
_run_grok_once() {
  local errfile
  errfile="$(mktemp)"
  OUT="$(grok "${ARGS[@]}" 2>"$errfile")"; RC=$?
  ERR="$(cat "$errfile")"; rm -f "$errfile"
}
_is_build_error() { grep -qiE 'agent building failed|auto_background_on_timeout' <<<"$1"; }

_run_grok_once

# One automatic retry, research mode only, and only when the 0.2.93 allowlist+web bug
# is NOT a plausible cause (version >= 0.2.98, confirmed fixed upstream, or unknown —
# see the version gate above). On an old (< 0.2.98) build the bug is still the likely
# cause and retrying just burns another turn on a deterministic failure, so that case
# skips straight to the fail-closed branch below. A short sleep gives a transient
# backend/rate-limit blip a chance to clear before the retry.
BUILD_ERROR_RETRIED=0
if _is_build_error "$ERR" && [[ "$MODE" == "research" && "$VERSION_BUG_POSSIBLE" -eq 0 ]]; then
  echo "[grok-run] research hit a session-build error; on this grok build the 0.2.93" >&2
  echo "[grok-run]   allowlist+web bug is fixed, so retrying once after a short wait..." >&2
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
  _sigdir="$(find "$HOME/.grok/sessions" -maxdepth 2 -type d -name "$GROK_SID" 2>/dev/null | head -1)"
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

# Build-error branch, version-gated (see the version gate above the run). Below 0.2.98
# this stderr text ("agent building failed: ... run_terminal_cmd ... auto_background_on_timeout")
# is the known bug: a web tool can't be added to a --tools allowlist, which breaks research
# mode. Do NOT "fix" it by dropping the allowlist or switching to --disallowed-tools /
# --permission-mode: those build fine but re-enable file writes and shell (canary-verified), so
# the run would no longer be read-only. Fail closed instead. At/above 0.2.98 (or when the
# version is unknown) that bug is structurally fixed upstream, so the same text is far more
# likely a transient backend/rate-limit error — research mode already retried once above; here
# we just report whichever diagnosis actually fits this install.
if _is_build_error "$ERR"; then
  if [[ "$VERSION_BUG_POSSIBLE" -eq 1 ]]; then
    if [[ "$MODE" == "research" ]]; then
      echo "[grok-run] FAILED: research mode is unavailable on this grok build ($GROK_VERSION)." >&2
      echo "[grok-run]   grok can't combine web tools with a read-only --tools allowlist" >&2
      echo "[grok-run]   (upstream session-build bug, fixed in 0.2.98). Not worked around on" >&2
      echo "[grok-run]   purpose: dropping the allowlist would re-enable writes/shell. Use 'review'" >&2
      echo "[grok-run]   for read-only code work. With the user's explicit OK to let grok hold" >&2
      echo "[grok-run]   write+shell: 'research-rw' (repo-less web research, throwaway temp dir)" >&2
      echo "[grok-run]   or 'fix -w <name>' (repo work, isolated worktree) — both have web." >&2
    else
      echo "[grok-run] FAILED: grok could not build the session:" >&2
      printf '%s\n' "$ERR" | head -3 >&2
    fi
  else
    if [[ "$BUILD_ERROR_RETRIED" -eq 1 ]]; then
      echo "[grok-run] FAILED: grok failed to build the session twice (retried once after 3s)." >&2
    else
      echo "[grok-run] FAILED: grok could not build the session:" >&2
      printf '%s\n' "$ERR" | head -3 >&2
    fi
    echo "[grok-run]   On this grok build (${GROK_VERSION:+detected $GROK_VERSION, }>= 0.2.98 or unknown) the old" >&2
    echo "[grok-run]   0.2.93 allowlist+web session-build bug is fixed upstream, so this is most" >&2
    echo "[grok-run]   likely a transient backend/rate-limit error — retry again later. Only if it" >&2
    echo "[grok-run]   keeps recurring, and with the user's explicit OK to let grok hold write+shell," >&2
    echo "[grok-run]   consider 'research-rw' (repo-less web research) or 'fix -w <name>' (repo work," >&2
    echo "[grok-run]   isolated worktree). Do NOT work around this by dropping the --tools allowlist" >&2
    echo "[grok-run]   or using --disallowed-tools/--permission-mode — those re-enable file writes" >&2
    echo "[grok-run]   and shell (canary-verified), which is not an acceptable substitute for the" >&2
    echo "[grok-run]   read-only sandbox." >&2
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

# Web-collection gate (research / research-rw). A web-mode run that never called a
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
if [[ "$MODE" == "research" || "$MODE" == "research-rw" ]] \
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

printf '%s\n' "$OUT"
exit "$RC"
