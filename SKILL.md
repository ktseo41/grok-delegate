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
resource pool. It always starts with a **fresh context**, so hand it self-contained prompts; never
assume it can see this conversation.

## The one safety fact that matters

In headless mode there is no human to approve tool calls, so `grok -p "…"` **runs its tools —
including file edits and shell — on its own**. `--permission-mode` is not a reliable brake: in
testing, `default`, `acceptEdits`, `auto`, `bypassPermissions`, and `plan` all let grok modify a
canary file; only `dontAsk` blocked it. And if `~/.grok/config.toml` has
`permission_mode = "always-approve"` (or you pass `--always-approve`), edits happen with no prompt
at all. The **only** robust read-only guard is a tool allowlist (`--tools "read_file,grep,list_dir"`),
which removes the write and shell tools entirely. The wrapper enforces this per mode — use it
instead of hand-rolling grok flags, unless you deliberately want autonomous edits.

## How to run it

Always go through the wrapper. It lives at `scripts/grok-run.sh` inside this skill's directory —
when installed that is `~/.claude/skills/grok-delegate/scripts/grok-run.sh`. If you are unsure where
the skill is, find it first: `ls ~/.claude/skills/grok-delegate/scripts/grok-run.sh` (or search your
skills dir). Use that absolute path everywhere the examples below write `$SKILL_DIR`; set it once so
the commands are copy-pasteable, e.g. `SKILL_DIR=~/.claude/skills/grok-delegate`.

```bash
# 1. Read-only second opinion / code review (safe default — cannot touch files)
"$SKILL_DIR/scripts/grok-run.sh" review \
  "Review the diff in src/auth for correctness and security bugs only. Be concrete: file:line + why." \
  --cwd /path/to/repo

# 2. Read-only + web research
"$SKILL_DIR/scripts/grok-run.sh" research \
  "Compare Postgres vs SQLite for a single-node analytics cache. Cite sources." --cwd /path/to/repo

# 3. AUTONOMOUS fix (grok edits files + runs shell). Isolate with a worktree:
"$SKILL_DIR/scripts/grok-run.sh" fix \
  "Fix the failing test in tests/test_parser.py and run pytest until green." \
  --cwd /path/to/repo -w grok-fix
```

Pass-through args go after the prompt: `-m grok-4.5` (frontier; default is account-set),
`--max-turns N` (wrapper defaults to 30), `-w/--worktree NAME` (isolated git worktree for `fix`),
`--effort high`. Env: `GROK_MODEL`, `GROK_MAXTURNS`.

### Parallel / subagent-like fan-out

grok has no in-Claude subagent binding, so parallelism = **multiple background Bash calls**, one
`grok-run.sh` each, then collect. In Claude Code, launch several Bash tool calls with
`run_in_background: true` in one message; you are re-invoked as each finishes. Use this for: review
the same diff from N angles, or split independent files across N grok workers. Each call is a fresh
grok context — make every prompt self-contained. (grok also has its own `--best-of-n` and internal
`task` subagents, but cross-Claude parallelism is background Bash.)

## Choosing mode

| Situation | Mode | Why |
| --- | --- | --- |
| Second opinion, code review, "is this right?" | `review` | Cannot modify the repo. Safe by construction. |
| Needs current web facts, comparisons, docs | `research` | Read-only + `web_search`/`web_fetch`. |
| Autonomous implementation, "have grok fix it" | `fix` | Full toolset + auto-approve. **Always pair with `-w`** so edits are isolated and reviewable. |

Default to `review` when the user is ambiguous. Only use `fix` when the user clearly wants grok to
change files, and prefer running it in a worktree.

## Handling the output

The wrapper prints grok's final text to stdout (plain). Relay the substance to the user — do not
dump the whole transcript verbatim; summarize findings and quote the specific lines that matter.
For `review`/`research`, then **independently verify** grok's claims against the actual code before
presenting them as fact — a different model is a different set of blind spots, not an oracle.
Empty output or a non-zero exit → the wrapper reports failure (usually an expired `grok login` or a
network error); tell the user to run `grok login` rather than silently retrying.

## When NOT to use grok

- The task needs what only this Claude session knows (prior decisions this turn, uncommitted reasoning). grok starts fresh.
- A trivial edit you can do faster inline.
- Anything where you would not let an autonomous agent with shell access run unattended — use `review`, not `fix`.

## Requirements

- The `grok` CLI on `PATH` (xAI). Verified against grok 0.2.93.
- Authenticated: run `grok login` once (or set `XAI_API_KEY` for CI). Uses a separate xAI quota, not your Claude usage.
