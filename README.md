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
./install.sh                 # -> ~/.claude/skills/grok-delegate
./install.sh --dest /path    # -> /path/grok-delegate
```

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

Examples:

```bash
# Read-only code review (cannot touch files)
scripts/grok-run.sh review \
  "Review the diff in src/auth for correctness and security bugs. Be concrete: file:line + why." \
  --cwd /path/to/repo

# Autonomous fix, isolated in a git worktree
scripts/grok-run.sh fix \
  "Fix the failing test in tests/test_parser.py and run pytest until green." \
  --cwd /path/to/repo -w grok-fix
```

Pass-through flags after the prompt: `-m grok-4.5`, `--max-turns N` (default 30), `--effort high`,
`-w/--worktree NAME`. Env: `GROK_MODEL`, `GROK_MAXTURNS`.

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
| `dontAsk` | no (blocked) |

Only `dontAsk` blocked the write — because in headless mode there is no human to approve, most modes
just execute. The robust guard is removing the tools entirely with `--tools`, which is what the
`review` and `research` modes do. `fix` deliberately opts back in with `--always-approve`.

## License

[MIT](LICENSE)
