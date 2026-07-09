#!/usr/bin/env bash
# stub-regression.sh — offline regression suite for scripts/grok-run.sh.
#
# Costs ZERO xAI quota: it puts a fake `grok` on PATH and exercises the wrapper's
# argument marshalling and exit-code logic directly. Run it on every change to
# grok-run.sh; it is the cheap first gate before the live evals/canary.sh.
#
# Two kinds of check:
#   PASS/FAIL  — a contract that is supposed to hold now (H2, H1, H5, H3, install
#                wrapper present). A FAIL is a real regression and sets a non-zero
#                exit; treat it as ship-blocking.
#   XFAIL      — a KNOWN-OPEN bug/gap we deliberately reproduce so it can't be
#                forgotten (M1/B12 flag dedup, B3 positional prompt, B4 -w= detect,
#                B5 output-format passthrough). XFAIL does NOT fail the build.
#                If an XFAIL flips to XPASS the bug was fixed — update this suite
#                (turn that assertion into a PASS/FAIL contract). XPASS is loud but
#                still does not set a non-zero exit.
#
# Usage:
#   bash evals/stub-regression.sh                 # test the repo copy
#   W=~/.claude/skills/grok-delegate/scripts/grok-run.sh bash evals/stub-regression.sh
#                                                 # test the INSTALLED copy instead
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${W:-$ROOT/scripts/grok-run.sh}"

PASS=0; FAIL=0; XFAIL=0; XPASS=0
pass()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail()  { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; FAIL=$((FAIL+1)); }
xfail() { printf '  XFAIL %s%s\n' "$1" "${2:+ — $2}"; XFAIL=$((XFAIL+1)); }
xpass() { printf '  XPASS %s — bug appears fixed; promote this to a PASS/FAIL contract\n' "$1"; XPASS=$((XPASS+1)); }
info()  { printf '  info  %s\n' "$1"; }

# mkstub DIR <<'EOS' ... EOS  — write an executable fake `grok` from stdin.
mkstub() { local d="$1"; cat >"$d/grok"; chmod +x "$d/grok"; }
# run STUBDIR ARGS...  — invoke the wrapper with STUBDIR's grok first on PATH.
run() { local d="$1"; shift; PATH="$d:$PATH" bash "$W" "$@"; }

echo "wrapper under test: $W"
[[ -x "$W" ]] || { echo "FATAL: wrapper not executable at $W" >&2; exit 3; }

# An argv-dumping stub: prints each arg it received as <arg> plus a marker so
# tests can inspect exactly what the wrapper handed to grok.
argv_stub() {
  mkstub "$1" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do printf '<%s>\n' "$a"; done
echo "STUB_OK"
exit 0
EOS
}

# ---------------------------------------------------------------------------
echo "=== H2: wrapper FAILED verdict must exit non-zero (even on grok exit 0) ==="
D="$(mktemp -d)"

mkstub "$D" <<'EOS'
#!/bin/sh
exit 0
EOS
run "$D" review "x" >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && pass "empty output + grok 0 -> wrapper non-zero" \
                  || fail "empty output" "rc=$rc (expected non-zero)"

mkstub "$D" <<'EOS'
#!/bin/sh
exit 3
EOS
run "$D" review "x" >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 3 ]] && pass "empty output + grok 3 -> preserve rc 3" \
                  || fail "preserve rc" "rc=$rc (expected 3)"

mkstub "$D" <<'EOS'
#!/bin/sh
echo "ok findings"
exit 0
EOS
out="$(run "$D" review "x" 2>/dev/null)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"ok findings"* ]] && pass "non-empty output -> success 0 + relayed" \
                  || fail "success path" "rc=$rc out=$out"

mkstub "$D" <<'EOS'
#!/bin/sh
echo "agent building failed: run_terminal_cmd auto_background_on_timeout" >&2
exit 0
EOS
run "$D" research "x" >/dev/null 2>"$D/err"; rc=$?
[[ "$rc" -ne 0 ]] && grep -q 'FAILED' "$D/err" \
  && pass "research build-fail + grok 0 -> non-zero FAILED" \
  || fail "research build-fail" "rc=$rc"
rm -rf "$D"

# ---------------------------------------------------------------------------
echo "=== H1: stdin '-' prompt delivery ==="
D="$(mktemp -d)"; argv_stub "$D"

: | run "$D" review - >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 2 ]] && pass "empty stdin on '-' -> exit 2" \
                  || fail "empty stdin" "rc=$rc (expected 2)"

out="$( { echo "Review this diff"; echo "+bad"; } | run "$D" review - --cwd /tmp 2>/dev/null )"
if printf '%s' "$out" | grep -q '^<--prompt-file>$' && ! printf '%s' "$out" | grep -q '^<-p>$'; then
  pass "piped '-' -> --prompt-file, no -p"
else
  fail "pipe delivery" "argv did not show --prompt-file without -p"
fi
rm -rf "$D"

# ---------------------------------------------------------------------------
echo "=== H5: fix warns only when no worktree; review/research never warn ==="
D="$(mktemp -d)"
mkstub "$D" <<'EOS'
#!/bin/sh
echo fixed
exit 0
EOS
run "$D" fix "x" --cwd /tmp >/dev/null 2>"$D/e"
grep -q WARNING "$D/e" && pass "fix without -w -> WARNING" || fail "fix no-w warning" "no WARNING"
run "$D" fix "x" --cwd /tmp -w wt1 >/dev/null 2>"$D/e"
grep -q WARNING "$D/e" && fail "fix -w should be silent" "warned anyway" || pass "fix -w -> no warning"
run "$D" fix "x" --cwd /tmp --worktree=wt2 >/dev/null 2>"$D/e"
grep -q WARNING "$D/e" && fail "fix --worktree= should be silent" "warned" || pass "fix --worktree= -> no warning"
run "$D" review "x" --cwd /tmp >/dev/null 2>"$D/e"
grep -q WARNING "$D/e" && fail "review must not warn" "warned" || pass "review -> no warning"
rm -rf "$D"

# ---------------------------------------------------------------------------
echo "=== H3: research fail-closed message points to 'fix -w', not to dropping the guard ==="
D="$(mktemp -d)"
mkstub "$D" <<'EOS'
#!/bin/sh
echo "agent building failed: auto_background_on_timeout" >&2
exit 1
EOS
run "$D" research "latest vite" --cwd /tmp >/dev/null 2>"$D/e"; rc=$?
if [[ "$rc" -ne 0 ]] \
   && grep -qi 'fix -w' "$D/e" \
   && grep -qi "user's OK" "$D/e" \
   && ! grep -qiE 'disallowed-tools|permission-mode' "$D/e"; then
  pass "research FAILED msg suggests 'fix -w' (user OK) and not a guard-dropping workaround"
else
  fail "research fail-closed message" "rc=$rc; check wording in grok-run.sh"
fi
rm -rf "$D"

# ---------------------------------------------------------------------------
echo "=== M1/B12: token-aware flag dedup (default injection) ==="
D="$(mktemp -d)"; argv_stub "$D"

# (a) equals form: --max-turns=40 must be recognized as already-set, so the wrapper
#     must NOT also inject its default -> exactly one --max-turns token in argv.
out="$(run "$D" review "x" --max-turns=40 2>/dev/null)"
n="$(printf '%s\n' "$out" | grep -c -- '--max-turns')"
[[ "$n" -eq 1 ]] && pass "equals form --max-turns=40 -> no duplicate flag" \
                 || fail "equals dedup" "found $n --max-turns tokens (expected 1)"

# (b) embedded form: '--max-turns' appearing inside another arg's value must NOT
#     suppress the default -> the read-only turn cap is still injected (<30> present).
out="$(run "$D" review "x" --system-prompt "please respect --max-turns limits" 2>/dev/null)"
printf '%s\n' "$out" | grep -q '^<30>$' && pass "embedded '--max-turns' -> default cap still injected" \
                                        || fail "embedded false-match" "default --max-turns 30 not injected"

# (c) model equals form: -m=... must be recognized so the wrapper does not inject a
#     duplicate -m default from GROK_MODEL.
out="$( export GROK_MODEL=env-default; run "$D" review "x" -m=grok-4.5 2>/dev/null )"
printf '%s\n' "$out" | grep -q '^<env-default>$' && fail "model equals dedup" "injected duplicate -m env-default" \
                                                 || pass "model form -m=grok-4.5 -> no duplicate -m"
rm -rf "$D"

# ---------------------------------------------------------------------------
echo "=== B3: a flag in the prompt position becomes the prompt (KNOWN BUG — expect XFAIL) ==="
D="$(mktemp -d)"; argv_stub "$D"
# `review --cwd /repo "real"` -> PROMPT=--cwd, so grok gets -p "--cwd".
out="$(run "$D" review --cwd /repo "real" 2>/dev/null)"
if printf '%s\n' "$out" | grep -A1 '^<-p>$' | grep -q '^<--cwd>$'; then
  xfail "flag consumed as prompt: -p value is '--cwd', real prompt lost"
else
  xpass "wrapper now rejects/handles a flag in the prompt slot"
fi
rm -rf "$D"

# ---------------------------------------------------------------------------
echo "=== B4: -w=name worktree form not detected (KNOWN GAP — expect XFAIL) ==="
D="$(mktemp -d)"
mkstub "$D" <<'EOS'
#!/bin/sh
echo fixed
exit 0
EOS
# fix with -w=feat is a worktree request, but the case pattern misses -w=* so it warns.
run "$D" fix "x" --cwd /tmp -w=feat >/dev/null 2>"$D/e"
if grep -q WARNING "$D/e"; then
  xfail "fix -w=feat still warns (short equals form not recognized as a worktree)"
else
  xpass "fix -w=feat recognized as a worktree (no false warning)"
fi
rm -rf "$D"

# ---------------------------------------------------------------------------
echo "=== B5: extra --output-format overrides the plain-stdout contract (KNOWN GAP — expect XFAIL) ==="
D="$(mktemp -d)"
mkstub "$D" <<'EOS'
#!/usr/bin/env bash
fmt=plain; args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  [ "${args[$i]}" = "--output-format" ] && fmt="${args[$((i+1))]}"
  i=$((i+1))
done
if [ "$fmt" = json ]; then echo '{"ok":true}'; else echo PLAIN; fi
exit 0
EOS
out="$(run "$D" review "hello" --output-format json 2>/dev/null || true)"
if [[ "$out" == '{"ok":true}' ]]; then
  xfail "caller's --output-format json wins -> non-plain body relayed as success"
else
  xpass "wrapper now protects the plain-stdout contract"
fi
rm -rf "$D"

# ---------------------------------------------------------------------------
echo "=== install: wrapper installs; evals are NOT shipped (current policy) ==="
DEST="$(mktemp -d)"
if CLAUDE_SKILLS_DIR="$DEST" bash "$ROOT/install.sh" >/dev/null 2>&1; then
  [[ -x "$DEST/grok-delegate/scripts/grok-run.sh" ]] \
    && pass "install places an executable grok-run.sh" \
    || fail "install wrapper" "grok-run.sh missing or not executable"
  if [[ -e "$DEST/grok-delegate/evals/canary.sh" ]]; then
    info "evals/ IS present in the install tree — policy changed; update B14 expectation"
  else
    info "evals/ not shipped by install.sh (canary runs from the source tree only)"
  fi
else
  fail "install.sh" "non-zero exit"
fi
rm -rf "$DEST"

# ---------------------------------------------------------------------------
echo "=== docs / drift (informational) ==="
info "canary call-count header: $(grep -oiE 'up to [0-9]+ real|[0-9]+ real .?grok.? calls' "$ROOT/evals/canary.sh" | head -1)"
info "evals/README call-count:  $(grep -oiE 'Makes [0-9]+ real|[0-9]+ real .?grok.? calls' "$ROOT/evals/README.md" | head -1)"
if grep -qiE 'only .?dontAsk.? blocked' "$ROOT/scripts/grok-run.sh"; then
  info "grok-run.sh still says 'only dontAsk blocked' (stale H4 wording)"
else
  info "grok-run.sh H4 wording clean (guard = --tools allowlist)"
fi

# ---------------------------------------------------------------------------
echo "=== OPS0: installed copy vs repo (informational) ==="
inst="$HOME/.claude/skills/grok-delegate/scripts/grok-run.sh"
if [[ -f "$inst" ]]; then
  if diff -q "$inst" "$ROOT/scripts/grok-run.sh" >/dev/null; then
    info "installed grok-run.sh in sync with repo"
  else
    info "installed grok-run.sh DIFFERS from repo — run: (cd $ROOT && ./install.sh --with-subagent)"
  fi
else
  info "no installed copy at $inst"
fi

# ---------------------------------------------------------------------------
echo
echo "summary: PASS=$PASS FAIL=$FAIL XFAIL=$XFAIL XPASS=$XPASS"
[[ "$XFAIL" -gt 0 ]] && echo "  (XFAIL = known-open bugs reproduced: B3, B4, B5 — see the backlog docs)"
[[ "$XPASS" -gt 0 ]] && echo "  ACTION: $XPASS known bug(s) look fixed — promote the XPASS assertions to PASS/FAIL contracts"
echo "exit status reflects FAIL (real regressions) only; XFAIL/XPASS do not fail the build."
exit "$FAIL"
