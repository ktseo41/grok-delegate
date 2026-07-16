---
name: grok-delegate
description: Delegate a coding, review, or research task to the grok CLI (xAI, grok-4.5) from inside Claude Code, as a subagent-like offload — run it headless via Bash (`grok -p`), in read-only or autonomous mode, and in parallel via background Bash for fan-out. Use when the user wants to hand actual work TO grok: a second opinion from a different model family, offloading work so it does not consume the Claude usage quota (grok bills to a separate xAI quota), or having grok review, research, or fix code — e.g. "delegate to grok", "ask grok to…", "grok review this", "run grok in parallel", "grok subagent", "cross-check with grok". NOT for questions about grok itself (its pricing, setup/login, or what "grok" means), NOT for delegating to other tools (codex, deepseek, sonnet), and not for tasks that need this Claude session's own context — grok always starts fresh.
---

# Delegate to grok (xAI CLI)

## What is real

There is **no native Claude Code → grok integration** (nothing like a first-class subagent binding).
The real, supported path is calling the headless grok CLI from the **Bash tool**. That is what this
skill wraps. Common myths to correct if the user repeats them:

- `--no-auto-update` **does not exist**. Do not use it.
- Structured output is `--json-schema '{…}'` or `--output-format json` — there is no magic
  "review-only" output flag.
- `--permission-mode plan` does **not** make grok read-only in headless mode. It still edits files.

Why grok is worth delegating to: it is a **different model family (grok-4.5)** → genuinely
independent errors for cross-checking, and it bills to a **separate xAI quota** (logged in via
`grok login`), so offloading to it does **not** consume your Claude usage limit — it is a separate
resource pool. Unlike a *forked* Claude subagent that inherits this conversation, grok always starts
with a **fresh context** — hand it self-contained prompts; never assume it can see this conversation.

## The one safety fact that matters

In headless mode there is no human to approve tool calls, so `grok -p "…"` **runs its tools —
including file edits and shell — on its own**. `--permission-mode` is not a reliable brake:
canary-tested on grok 0.2.93, **every** mode — `default`, `acceptEdits`, `auto`, `bypassPermissions`,
`plan`, and even `dontAsk` — let grok write a file. And if `~/.grok/config.toml` has
`permission_mode = "always-approve"` (or you pass `--always-approve`), edits happen with no prompt
at all. The **only** robust read-only guard is a tool allowlist (`--tools "read_file,grep,list_dir"`),
which removes the write and shell tools entirely — verified: with it, repeated multi-vector canary
attempts (append, create, shell) all failed to touch anything. The wrapper enforces this per mode —
use it instead of hand-rolling grok flags, unless you deliberately want autonomous edits. (This
mirrors how Claude Code's own built-in Explore/Plan subagents stay read-only: Write and Edit are
denied at the tool level, not via a permission mode.)

**`research` is the normal path on current grok (0.2.98+).** A historical bug on grok < 0.2.98 made
adding a web tool to a `--tools` allowlist fail to build the session (upstream error naming
`run_terminal_cmd` / `auto_background_on_timeout`), so on those old builds `research` **fails
closed**. That was fixed upstream in grok 0.2.98 (2026-07-12) and verified fixed on 2026-07-16
against installed grok 0.2.99 and the now-open-source repo (checkout 0.2.101) — see
`docs/source-investigation-2026-07-16.md`. The wrapper still detects a build failure per-run: on
< 0.2.98 it names the old bug; on 0.2.98+ (or an unknown version) it now auto-retries `research`
once, and if that still fails it reports a likely transient backend/rate-limit error and suggests
retrying later rather than escalating straight to `research-rw`. If grok reports that `--tools` is
broken and suggests `--disallowed-tools` or a permission mode to get web working, do **not** take
it: those build fine but re-enable file writes and shell (canary-verified), so the run would no
longer be read-only. `review` is unaffected.

If `research` still fails after the retry — an old build (< 0.2.98) or a persistent session-build
failure — do **not** silently substitute something: surface it and let the user choose, because
each path spends a different quota. The web tools work fine without the allowlist, so with the
user's **explicit OK** to let grok hold write/shell for the lookup there are two grok-native
routes, both on grok's **xAI** quota:

- **`research-rw`** — legacy fallback: repo-less web research on an old grok build, or when
  `research` keeps failing to build a session after a retry. Runs like `fix` but the wrapper points
  it at a fresh throwaway temp dir, so stray writes land nowhere that matters. That isolation is
  **advisory only**: grok keeps shell and can reach outside the cwd, so this needs the same user OK
  as `fix`. The wrapper's prompt guard forbids shell-based fetch and UA spoofing, but a prompt is
  not a sandbox.
- **`fix -w <name>`** — for research anchored in a repo, with edits isolated in a worktree.

If the user needs a strictly read-only answer and `research` won't build, either upgrade grok
(< 0.2.98 is the known-bad range) or offer your own WebSearch/WebFetch — but that burns **Claude's**
quota (the very thing delegating to grok saves), so ask first rather than defaulting to it. Never
weaken `research` itself to get web.

## How to run it

Always go through the wrapper. It lives at `scripts/grok-run.sh` inside this skill's directory —
when installed that is `~/.claude/skills/grok-delegate/scripts/grok-run.sh` (or, installed as a
plugin, `${CLAUDE_PLUGIN_ROOT}/scripts/grok-run.sh`). If you are unsure where the skill is, find it
first: `ls ~/.claude/skills/grok-delegate/scripts/grok-run.sh` (or search your skills/plugins dirs).
Use that absolute path everywhere the examples below write `$SKILL_DIR`; set it once so
the commands are copy-pasteable, e.g. `SKILL_DIR=~/.claude/skills/grok-delegate`.

```bash
# 1. Read-only second opinion / code review (safe default — cannot touch files).
#    review mode has NO git/shell, so grok CANNOT compute a diff itself. To review
#    a change, pipe the diff in via "-" (stdin); to review code as-is, name files.
{ echo "Review this staged diff for correctness and security bugs only. Be concrete: file:line + why."; \
  git -C /path/to/repo diff --staged; } \
  | "$SKILL_DIR/scripts/grok-run.sh" review - --cwd /path/to/repo

# 2. Read-only + web research
"$SKILL_DIR/scripts/grok-run.sh" research \
  "Compare Postgres vs SQLite for a single-node analytics cache. Cite sources." --cwd /path/to/repo

# 2b. Legacy fallback if `research` still fails to build a session (old grok < 0.2.98,
#     or a persistent build failure even after the wrapper's auto-retry) — ONLY with the
#     user's explicit OK (grok holds write+shell; the wrapper isolates it in a throwaway
#     temp dir, but that isolation is advisory, not a sandbox). No --cwd needed.
"$SKILL_DIR/scripts/grok-run.sh" research-rw \
  "What is the current ECB deposit facility rate? Quote the official page verbatim with the URL."

# 3. AUTONOMOUS fix (grok edits files + runs shell). Isolate with a worktree:
"$SKILL_DIR/scripts/grok-run.sh" fix \
  "Fix the failing test in tests/test_parser.py and run pytest until green." \
  --cwd /path/to/repo -w grok-fix
```

Pass-through args go after the prompt: `-m grok-4.5` (frontier; default is account-set),
`--max-turns N` (wrapper defaults to 30), `-w/--worktree NAME` (isolated git worktree for `fix`),
`--effort high`. Space or `=` form both work (`--max-turns=40`). Env: `GROK_MODEL`, `GROK_MAXTURNS`.

**Reviewing a diff (important).** `review` has no git or shell, so grok cannot run
`git diff` — it can only `read_file` the current working tree. Never tell it to "review
the diff"; instead compute the diff yourself and feed it in. For a large diff, pass `-`
as the prompt to stream instructions + diff from **stdin** (goes to grok via
`--prompt-file`, so no ARG_MAX limit and grok sees it in full), keeping the diff out of
your own context — it flows git → pipe → grok, billing xAI only:

```bash
{ echo "Review this staged diff for correctness/security only. file:line + why."; \
  git -C /path/to/repo diff --staged; } | "$SKILL_DIR/scripts/grok-run.sh" review - --cwd /path/to/repo
```

### Parallel / subagent-like fan-out

grok has no in-Claude subagent binding, so parallelism = **multiple background Bash calls**, one
`grok-run.sh` each, then collect. In Claude Code, launch several Bash tool calls with
`run_in_background: true` in one message; you are re-invoked as each finishes. Use this for: review
the same diff from N angles, or split independent files across N grok workers. Each call is a fresh
grok context — make every prompt self-contained. (grok also has its own `--best-of-n` and internal
`task` subagents, but cross-Claude parallelism is background Bash.) These background runs show up in
`/tasks`. Claude Code's sanctioned way to make a non-Claude tool a first-class agent is an MCP server;
grok ships none today, so background Bash is the supported route.

**The two consumption patterns.** How grok's output gets back to you decides whether the courier
subagent (next section) belongs in the loop:

- **Conversational one-shot** — the user asks for a review/answer and the deliverable is a summary
  *in the conversation*. Use the courier (`@grok`): it isolates grok's verbose output in its own
  context and relays only the substance.
- **Orchestrated fan-out + file drop** — you (the orchestrator) fan out N workers whose deliverable
  is a *file* each worker writes in its own working dir (summaries, reports, transformed artifacts),
  which you then read, verify, and synthesize yourself. Call the wrapper **directly** via background
  Bash and have each prompt end with "write the result to `<file>`"; skip the courier — a relay
  agent per worker adds a full Claude-side turn per worker and shuttles content you were going to
  read from disk anyway. Verified on a real 6-worker run (yt-dlp caption collection + per-video
  summaries, `fix` mode with per-worker scratch cwds): identical grok-side behavior to the courier
  path (modes, isolation, usage trailer), zero courier overhead. Verification stays with the
  orchestrator: spot-check a sample of outputs against the on-disk source material (e.g. the
  downloaded transcripts) before synthesizing.

**Turn-budget sizing.** The wrapper's default `--max-turns 30` fits a **single-topic** worker
comfortably (observed: 3–17 tool calls per topic). A monolithic run covering many topics does not:
a real 12-topic solo research run died mid-task at the default cap and needed `--max-turns 120` to
finish. Prefer fan-out (one worker per topic) — each stays within the default cap, failures and
retries are per-topic instead of all-or-nothing, and the whole wave finishes in roughly one
worker's wall-clock.

### Optional: the `grok` dispatcher subagent

For native subagent ergonomics — `@grok` invocation, `/tasks` monitoring, real Agent-tool
parallelism, and grok's output kept **out of the main context** (only a summary returns) — install
the bundled dispatcher: `./install.sh --with-subagent` copies `agents/grok.md` to
`~/.claude/agents/grok.md`. It is a thin courier (`tools: Bash`, `model: sonnet`) whose only job is
to run `grok-run.sh` once and relay the findings; the heavy reasoning stays on grok (xAI quota), so
only the small courier turn is Claude's. `model: sonnet` is pinned so it does not `inherit` an
expensive main-session model — override per-invocation or via `CLAUDE_CODE_SUBAGENT_MODEL`. Then just
`@grok review the diff in src/auth`, or spawn several in one turn to fan out. Without it, delegation
still works through the Bash wrapper above.

**When not to use the courier.** It reads grok's output and re-emits it, so for a large *generated
artifact* (a translated page, a whole file) that pass-through is wasted tokens. Prefer calling the
wrapper directly and redirecting to a file — `grok-run.sh review "…translate, output the full HTML" >
out.html` — so neither the courier nor the main context pays to shuttle it; then check only the part
you need (a `diff`/`grep`). Rule of thumb: **want a summary in the conversation → `@grok`; want a
raw artifact or a file-drop fan-out → direct wrapper + `> file`** (see "The two consumption
patterns" above). The courier earns its cost on analysis (review/research), where summarizing and
isolating grok's output is the point.

## Examples

Each example is a real user ask → the delegation it maps to. `$SKILL_DIR` is set as in
"How to run it"; `<LIBRARY>`/paths are placeholders. Keep prompts self-contained — grok starts fresh.

**Review / second opinion** — "grok review this diff", "cross-check with grok"

```bash
# review has no git/shell — pipe the diff in via "-" (stdin) rather than asking grok to compute it
{ echo "Review this staged diff for correctness and security bugs only. Be concrete: file:line + why."; \
  git -C /path/to/repo diff --staged; } | "$SKILL_DIR/scripts/grok-run.sh" review - --cwd /path/to/repo
```

**Current-facts research** — "ask grok how `<LIBRARY>` handles retries", "have grok compare X vs Y"

```bash
"$SKILL_DIR/scripts/grok-run.sh" research \
  "How does <LIBRARY> implement retry/backoff? Cite the specific files and docs." --cwd /path/to/repo
```

**Offload an autonomous fix** — "have grok fix the failing auth test"

```bash
"$SKILL_DIR/scripts/grok-run.sh" fix \
  "Fix the failing test in tests/auth_test.py and run pytest until green." \
  --cwd /path/to/repo -w grok-fix
```

**Parallel fan-out** — "have grok review these modules in parallel". One background Bash call per
target (each a fresh grok context), then collect — see "Parallel / subagent-like fan-out" above.

```bash
# launch each with run_in_background: true, then relay findings as each returns
"$SKILL_DIR/scripts/grok-run.sh" review "Review src/a.py for concurrency bugs. file:line + why." --cwd /path/to/repo
"$SKILL_DIR/scripts/grok-run.sh" review "Review src/b.py for concurrency bugs. file:line + why." --cwd /path/to/repo
```

## Choosing mode

| Situation | Mode | Why |
| --- | --- | --- |
| Second opinion, code review, "is this right?" | `review` | Cannot modify the repo. Safe by construction. |
| Needs current web facts, comparisons, docs | `research` | Read-only + `web_search`/`web_fetch`. |
| Legacy fallback: `research` won't build a session (old grok < 0.2.98, or a persistent failure), user OK'd write/shell | `research-rw` | Like `fix` with web, pointed at a throwaway temp dir. Isolation is advisory — requires the user's explicit OK. |
| Autonomous implementation, "have grok fix it" | `fix` | Full toolset + auto-approve. **Always pair with `-w`** so edits are isolated and reviewable. |

Default to `review` when the user is ambiguous. Only use `fix` when the user clearly wants grok to
change files, and prefer running it in a worktree. Two `fix -w` caveats (both general git-worktree
behavior, not grok-specific): a worktree branches from **HEAD**, so commit or stash uncommitted work
first or grok won't see it; and when it finishes, the edits sit in that worktree — surface the diff
(`git -C <worktree> diff`) and let the user decide how to integrate (merge / PR / discard) rather
than assuming.

## Handling the output

The wrapper prints grok's final text to stdout (plain). Relay the substance to the user — do not
dump the whole transcript verbatim; summarize findings and quote the specific lines that matter.
For `review`, then **independently verify** grok's claims against the actual code before presenting
them as fact — a different model is a different set of blind spots, not an oracle.
Empty output or a non-zero exit → the wrapper reports failure (usually an expired `grok login` or a
network error); tell the user to run `grok login` rather than silently retrying.

**The no-collection failure mode (wrapper-gated).** The worst research failure is not a crash but a
**plausible answer produced without any collection**: on a real 12-worker fan-out, 4 workers exited
0 with normal-sized, entirely made-from-memory output — indistinguishable from success except in
grok's own usage signals. The wrapper now enforces this: a `research`/`research-rw` run whose
signals show **no `web_search`/`web_fetch` call exits non-zero** with a `FAILED: … no web tool call`
verdict (body still printed for inspection). Treat that exit as "not research": retry **once** with
the prompt strengthened to demand `web_fetch` + a verbatim quote per claim — observed recovery is
only ~1 in 4, and the failure tends to recur on the same prompts — then collect the facts yourself
instead of retrying further. `GROK_ALLOW_NOWEB=1` bypasses the gate for a deliberately memory-only
run. The gate is best-effort (needs `uuidgen`/`jq`/grok's `signals.json`, like the usage trailer).

**Verifying research output.** For web research the same verify-not-oracle rule applies, but
verification spends **Claude's** quota — the thing delegation saves — so budget it instead of
re-collecting everything:

- **Spot-check, don't re-fetch all**: verify every claim that looks off or diverges from what you
  expect, plus a small sample of the rest — not a full second collection pass.
- **Make verification cheap upstream**: have the research prompt demand a verbatim quote + source
  URL per claim (the wrapper's web-mode prompt guard asks for this too). Checking a quote is far
  cheaper than re-deriving a fact, and WebFetch's small summary model is known to misread years and
  numbers in tables — a verbatim quote is what you check it against.
- **When an official site 403s direct fetch**: use a domain-limited WebSearch (`allowed_domains`
  pinned to the official domain) — verified to work on sites that block fetch (central-bank sites,
  Cloudflare/Akamai fronts). Never spoof a User-Agent or otherwise circumvent bot protection, on
  either the Claude side or the grok side.
- **Retrying a grok worker that failed on a blocked site**: change the strategy, not just the run —
  tell the retry to use domain-limited `web_search` instead of `web_fetch` (a fetch-heavy retry
  against a blocked site cost 3x the median worker on a real fan-out).

## When NOT to use grok

- The task needs what only this Claude session knows (prior decisions this turn, uncommitted reasoning). grok starts fresh.
- A trivial edit you can do faster inline.
- Anything where you would not let an autonomous agent with shell access run unattended — use `review`, not `fix`.

## Requirements

- The `grok` CLI on `PATH` (xAI). The read-only permission-mode canary was last re-run on grok 0.2.93
  (2026-07-12) and those facts still hold. Separately, the 0.2.93 research-build bug described above
  is fixed as of grok 0.2.98 — verified 2026-07-16 against installed grok 0.2.99 and the
  now-open-source repo (checkout 0.2.101); see `docs/source-investigation-2026-07-16.md`.
- Authenticated: run `grok login` once (or set `XAI_API_KEY` for CI). Uses a separate xAI quota, not your Claude usage.
