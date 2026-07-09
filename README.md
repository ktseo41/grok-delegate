# grok-delegate

A [Claude Code](https://claude.com/claude-code) skill that delegates coding, review, and research
tasks to the [grok CLI](https://x.ai) (xAI, `grok-4.5`) — as a subagent-like offload. Claude Code
calls grok headless via the Bash tool, in a **read-only** or **autonomous** mode, and can fan out
several grok workers in parallel.

## Why

- **Independent cross-check.** grok is a different model family, so it has a different set of blind
  spots than Claude — useful for second opinions and code review.
- **Separate quota.** grok bills to your xAI account, not your Claude usage limit. Offloading work
  to it does not eat into Claude's quota.
- **Safe by construction.** In headless mode grok runs tools with no human to approve them, so a
  bare `grok -p` will edit files. This skill's wrapper removes the write/shell tools for read-only
  modes via a `--tools` allowlist — `--permission-mode` is **not** a reliable guard (see below).

## Install

Clone directly into your Claude Code skills directory so the folder name matches the skill name:

```bash
git clone https://github.com/ktseo41/grok-delegate.git ~/.claude/skills/grok-delegate
```

Or use the installer (copies into `~/.claude/skills/grok-delegate` by default):

```bash
./install.sh                    # -> ~/.claude/skills/grok-delegate
./install.sh --dest /path       # -> /path/grok-delegate
./install.sh --with-subagent    # also install the 'grok' subagent (see below)
```

### Optional: use grok as a native subagent

Pass `--with-subagent` to also copy `agents/grok.md` to `~/.claude/agents/grok.md`. It is a thin
dispatcher subagent (`tools: Bash`, `model: sonnet`) that runs `grok-run.sh` in its own context and
relays only a summary — so you get `@grok` invocation, `/tasks` monitoring, and real parallel fan-out
via the Agent tool, with grok's verbose output kept out of your main conversation. The heavy
reasoning stays on grok (xAI quota); only the small courier turn bills to Claude. `model: sonnet` is
pinned so the courier does not inherit an expensive main-session model. Delegate with, e.g.,
`@grok review the diff in src/auth`. Without it, delegation still works by calling the wrapper directly.

For a large generated artifact (a translated page, a whole file), skip the subagent and call the
wrapper directly with output redirected to a file — `grok-run.sh review "…" > out.html` — since the
courier would otherwise spend tokens shuttling the whole artifact through its context. Rule of thumb:
want a summary → `@grok`; want the raw artifact → direct wrapper + `> file`.

### Requirements

- The `grok` CLI on your `PATH`. Verified against grok 0.2.93.
- Authenticated once: `grok login` (or `XAI_API_KEY` for CI).

## Usage

Claude Code invokes the skill automatically when you ask it to delegate to grok. You can also call
the wrapper directly:

```bash
scripts/grok-run.sh review   "<prompt>" [grok args...]   # read-only, no web   (default)
scripts/grok-run.sh research "<prompt>" [grok args...]   # read-only + web search/fetch
scripts/grok-run.sh fix      "<prompt>" [grok args...]   # AUTONOMOUS: edits files + shell
```

Examples — each is a user ask mapped to the delegation it triggers:

```bash
# "grok review this diff" — read-only, cannot touch files. review has no git/shell, so
# grok can't compute a diff itself: pipe it in via "-" (stdin), or name files for it to read.
{ echo "Review this staged diff for correctness and security bugs. Be concrete: file:line + why."; \
  git -C /path/to/repo diff --staged; } | scripts/grok-run.sh review - --cwd /path/to/repo

# "ask grok how <LIBRARY> handles retries" — read-only + web
scripts/grok-run.sh research \
  "How does <LIBRARY> implement retry/backoff? Cite the specific files and docs." \
  --cwd /path/to/repo

# "have grok fix the failing test" — autonomous, isolated in a git worktree
scripts/grok-run.sh fix \
  "Fix the failing test in tests/test_parser.py and run pytest until green." \
  --cwd /path/to/repo -w grok-fix

# "review these modules in parallel" — one background run per target, then collect
scripts/grok-run.sh review "Review src/a.py for concurrency bugs. file:line + why." --cwd /path/to/repo &
scripts/grok-run.sh review "Review src/b.py for concurrency bugs. file:line + why." --cwd /path/to/repo &
wait
```

Pass-through flags after the prompt: `-m grok-4.5`, `--max-turns N` (default 30), `--effort high`,
`-w/--worktree NAME` (space or `=` form both work). Env: `GROK_MODEL`, `GROK_MAXTURNS`.

**Reviewing a diff:** `review` mode has no git or shell, so grok cannot run `git diff` — pass the
prompt as `-` to stream instructions + diff from stdin (delivered to grok via `--prompt-file`, so
there is no argument-length limit and grok sees the whole diff):

```bash
{ echo "Review this staged diff for correctness/security. file:line + why."; \
  git -C /path/to/repo diff --staged; } | scripts/grok-run.sh review - --cwd /path/to/repo
```

### Modes

| Mode | Tools | Use for |
| --- | --- | --- |
| `review` (default) | `read_file`, `grep`, `list_dir` | Second opinion, code review — cannot modify the repo. |
| `research` | read-only + `web_search`, `web_fetch` | Comparisons, current docs/facts. |
| `fix` | full toolset + `--always-approve` | Autonomous implementation. Pair with `-w` for isolation. |

## The safety detail

`--permission-mode` does not make grok read-only in headless mode. Tested against grok 0.2.93 by
asking grok to append to a canary file under each mode:

| `--permission-mode` | Wrote the file? |
| --- | --- |
| `default` | yes |
| `acceptEdits` | yes |
| `auto` | yes |
| `bypassPermissions` | yes |
| `plan` | yes |
| `dontAsk` | yes |

**No permission mode blocked the write** in headless mode — there is no human to approve, so the
tools just execute. The only robust guard is removing the tools entirely with `--tools`, which is
what `review` (and, when it can build, `research`) does; `--disallowed-tools` is not a safe
substitute — it also let grok write in testing. `fix` deliberately opts back in with `--always-approve`.

**The read-only guarantee is regression-tested.** `evals/canary.sh` points `review` at a throwaway
sandbox and orders grok to write four ways — append, create, shell `touch`, and an absolute path
*outside* `--cwd` — then asserts nothing landed (detected by a full before/after tree snapshot, not a
fixed list of filenames). A `fix`-mode positive control proves grok is genuinely write-capable, and a
`git status` guard proves the test itself didn't dirty the repo; it exits non-zero if any write leaks.
`evals/stub-regression.sh` covers the wrapper's argument handling offline, at zero xAI quota. Run both
after touching the wrapper — see [`evals/README.md`](evals/README.md).

**Known bug (grok 0.2.93):** a `--tools` allowlist that includes a web tool (`web_search`/`web_fetch`)
fails to build the session, so `research` currently fails closed until grok fixes it upstream (the
wrapper re-checks each run, so a newer grok recovers automatically). It reports this clearly rather
than dropping the read-only guard to work around it. When you still need the web lookup, don't weaken
`research` — pick a path by quota: `review` for read-only code work; **with your explicit OK to let
grok write**, `fix -w <name>` (fix has web, runs isolated in a worktree, stays on grok's xAI quota);
or, if you ask first, Claude's own WebSearch/WebFetch (spends Claude's quota — the thing delegating
saves). Never silently substitute one for another.

## License

[MIT](LICENSE)
