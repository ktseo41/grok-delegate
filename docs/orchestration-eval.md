# Is grok delegation actually worth it? — the orchestration evals

Two controlled rounds (2026-07-09 and 2026-07-10) comparing **fable + grok fan-out** against
solo models and other orchestrations on real web-research tasks, plus solo-grok reference arms.
This document is the reusable summary: what was measured, how, what came out, and how to rerun
the same frame against a different model or delegation channel later.

Raw artifacts (prompts, harnesses, per-run `run.json`, worker outputs, blind copies, judge
scoreboards) live outside this repo in the experiment workspace
(`~/playground/grok-delegate-workspace/orchestration-eval/` and `…-eval-r2/`); this page carries
the numbers and links the structure so the results are auditable without shipping the data.

## TL;DR

| Arm | Round 1 (lookup task) | Round 2 (judgment-trap task) |
| --- | --- | --- |
| **fable + grok fan-out (c3)** | **70/70 (100%)** | **72/72 (100%)** — fastest wall-clock (12 min), fewest turns (71) |
| **fable + deepseek fan-out (c4)** | **70/70 (100%)**, slowest (22 min) | **71/71 (100%)** (post-hoc, non-blind; 1 unverifiable cell) — all traps avoided despite **42% final worker failure** |
| sonnet solo (c0) | 94–100% band | **72/72 (100%)** (n=1 — see spread note) |
| sonnet + advisor, unprompted (c5a) | — | 69/72 (95.8%), advisor fired 0 times |
| sonnet + advisor, 1-line nudge (c5b) | — | 70/72 (97.2%), advisor fired 0 times |
| fable solo (c1) | 98.6% | **68/72 (94.4%) — last**; hit both vintage traps |
| grok solo (c6, post-hoc, non-blind) | 98.5% facts-perfect, citations weak | 67/71 (94.4%) — **hit the exact same vintage traps as fable solo** |

![Round 2 — cells lost per arm](assets/r2-accuracy.svg)

Two rounds, two task shapes, and the only arms without a single wrong cell are the two fan-outs:
**c3 142/142 and c4 141/141 for the worker-collects + orchestrator-re-verifies structure.** The
headline is not "grok is smart" — solo grok landed at the bottom alongside solo fable. The value
is **procedural redundancy**: independent collection (cheap workers, external quota) followed by
the orchestrator re-verifying every number against the primary source. Two different model
families failed the *same* trap cells when run alone; the same structure aced them with grok
workers (33% first-wave failure) and again with deepseek workers (42% *final* failure) — the
structure's advantage is robust to worker model choice.

## The tasks

- **Round 1 — lookup.** Current monetary-policy settings of 12 central banks, 6 fields each
  (instrument name, value, last-change date, magnitude/direction, next meeting, verbatim
  decision-statement quote + URL). Official sources only. All arms scored 94–100%: too easy to
  discriminate; only the citation field separated arms.
- **Round 2 — judgment traps.** Real policy rate of 12 currency areas: policy rate (central
  bank) − latest YoY of the **index the bank officially targets** (national statistics office),
  computed to two decimals. Traps planted per field: official-target-index vs operational-index
  (US PCE not CPI, Sweden CPIF, Norway CPI vs CPI-ATE, Japan all-items vs ex-fresh-food),
  release **vintage** (flash vs final, most-recent-release scan), original-source attribution
  (statistics office, not the central bank), and cascade scoring — a wrong index choice re-costs
  the arithmetic cell. 12 × 6 = 72 cells, 1 point each.

## Controls that made the numbers trustworthy

- **Blind judging.** The 5 reports were shuffled to `A…E` and scored by a fable judge that never
  saw the mapping; result files were required to contain zero methodology traces (verified by
  scan). The judge session's file access was audited post-hoc from its transcript: it read
  exactly `blind/*.md` and nothing else.
- **Byte-identical prompts across paired arms.** The advisor arm (c5a) shared the baseline's
  prompt *file*; the nudged arm (c5b) differed by exactly one documented line (`diff` kept).
- **Same-day completion + drift control.** All runs and the judge finished the same day; CPI
  release calendars were checked beforehand, and any release landing between run and scoring
  would have been double-accepted (rule pre-registered; never actually needed).
- **Pre-registered hypotheses** (difficulty spread, advisor natural-fire, advisor nudge effect,
  structure advantage) written before execution, scored after.
- **Raw per-model token reporting.** Every arm reported tokens per model (fable / sonnet /
  haiku / grok) from first-party `run.json` model-usage data — no cross-model "sonnet-equivalent"
  summing, ever. grok's own spend came from the wrapper's `[grok-usage]` trailer
  (ctxTokens, wallSec, toolCalls per worker).
- **Tool discipline.** All arms: no skills, no MCP, no subagents; web = WebSearch/WebFetch only
  (or grok's `web_search`/`web_fetch`); no curl; bot-blocked sites (403) handled by
  domain-limited search, never circumvention.

## Tokens and potential cost (round 2, raw per model)

![Round 2 — raw tokens per model](assets/r2-tokens.svg)

| Arm | Model | in | out | cache write | cache read |
| --- | --- | ---: | ---: | ---: | ---: |
| c0 | sonnet-5 | 19,093 | 44,878 | 219,746 | 7,826,668 |
| c0 | haiku-4.5 | 1,354,379 | 24,771 | 0 | 0 |
| c5a | sonnet-5 | 22,330 | 33,209 | 142,280 | 5,368,222 |
| c5a | haiku-4.5 | 1,265,412 | 23,478 | 0 | 0 |
| c5b | sonnet-5 | 17,973 | 42,486 | 168,100 | 8,007,593 |
| c5b | haiku-4.5 | 1,743,408 | 30,356 | 0 | 0 |
| c1 | fable-5 | 4,065 | 50,150 | 200,396 | 1,927,217 |
| c1 | haiku-4.5 | 1,134,678 | 13,843 | 0 | 0 |
| c3 | fable-5 | 5,490 | 41,540 | 139,750 | 2,051,132 |
| c3 | haiku-4.5 | 532,540 | 6,558 | 0 | 0 |
| c3 | grok-4.5 (16 workers) | — | — | — | ctxTokens 615,004 |
| c4 | fable-5 | 4,436 | 61,922 | 170,222 | 2,196,121 |
| c4 | haiku-4.5 | 776,230 | 12,144 | 0 | 0 |
| c4 | deepseek-v4-flash (19 runs) | 2,175,635¹ | 38,361² | — | — |
| c6 | grok-4.5 (1 session) | — | — | — | ctxTokens 161,675 |

¹ includes 913,792 cached input. ² includes 18,178 reasoning tokens. haiku rows are the
WebSearch summarizer's automatic usage on the Claude side.

**Where each number comes from — and the grok caveat.**

- **Claude models**: `run.json` → `modelUsage`, per model, per run. First-party and exact.
- **deepseek (via codex CLI)**: exact per-session `total_token_usage` (input / cached input /
  output / reasoning) is in the codex rollout logs at
  `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl` — sum the sessions in the run's time
  window. Cross-checkable against the OpenRouter activity CSV export.
- **grok (via grok CLI)**: the CLI does **not** record billable in/out splits anywhere local.
  A session's files (`~/.grok/sessions/<cwd-encoded>/<session-id>/`) expose only
  `signals.json → contextTokensUsed` (final context size — what the wrapper's trailer prints)
  and the same cumulative figure in `updates.jsonl`. The console **Usage Explorer** covers
  API-key billing only; these runs used a **SuperGrok subscription**, which is not itemized
  there. So grok in/out is *estimated*, bounded from session data:
  - lower bound ≈ final context × input price + estimated output (as if one fully-cached pass);
  - upper bound ≈ Σ(context size at each inference step, from the `updates.jsonl` token
    progression) × input price + estimated output (as if nothing was cached);
  - output tokens ≈ assistant + reasoning + tool-call text length / 4.
  A secondary real-world meter: the CLI's weekly-limit percentage (logged as
  `creditUsagePercent` in `~/.grok/logs/unified.jsonl` every run) — the r2-c6 run moved it by
  about one percentage point of the weekly SuperGrok quota.

![Round 2 — potential cost per arm](assets/r2-cost.svg)

| Arm | Claude-side (measured, API-equivalent) | External wallet (estimate) |
| --- | ---: | :-- |
| c3 | $7.66 | grok $1.41–11.99 (API-equivalent bounds; run on SuperGrok subscription) |
| c0 | $6.40 | — |
| c5b | $6.65 | — |
| c5a | $4.92 | — |
| c1 | $9.95 | — |
| c4 | $9.81 | deepseek ≈ $0.20 (OpenRouter rates, no cache discount) |
| c6 | $0 | grok $0.35–5.78 (same method; single session) |

Claude-side figures are `run.json total_cost_usd` (what the run would cost at API list prices —
subscription users spend quota, not cash). The grok range is wide because caching behavior is
invisible to the client; the true figure sits between the bounds, and on subscription it is
"about 1% of the weekly quota" rather than dollars. Charts regenerate via
`assets/gen_charts.py`.

## What the evals taught (and what changed in this repo because of them)

1. **The dangerous failure is silent no-collection, not crashes.** On the round-2 fan-out,
   4 of 12 grok workers exited 0 with plausible, normal-sized output **written from model memory
   with zero web calls** — invisible in exit code, size, or text. The usage trailer's tool list
   was the only signal, and retries recovered only 1 of 4. The wrapper now enforces this as the
   **web-collection gate**: a `research`/`research-rw` run with no web tool call exits non-zero
   (`FAILED: … no web tool call`). See `scripts/grok-run.sh`; regression-tested in
   `evals/stub-regression.sh` (H6).
2. **Solo runs of strong models miss mechanical diligence, not reasoning.** Round 2's decisive
   cells were "respect the source's own *preliminary* label" and "scan for a release published
   two days ago". Solo fable and solo grok both missed exactly these; every arithmetic error in
   the whole eval was zero. If the task has trap-shaped freshness/labeling cells, buy procedure
   (collect → re-verify), not a bigger model.
3. **Fan-out also wins on turn budget.** A single grok session doing 12 topics blew the default
   `--max-turns 30` and died mid-task (round 1 c6, first attempt); per-topic workers each used
   3–17 tool calls and finished in about one worker's wall-clock. The wrapper now logs the
   *effective* turn cap, and SKILL.md documents the sizing rule.
4. **An idle advisor is not a safety net.** A stronger-model advisor tool exposed to sonnet fired
   **0 times in 4 arms across both rounds** — including with a neutral one-line nudge, and
   including on a cell where sonnet wrote down the correct official wording and then chose the
   wrong index anyway. Plumbing was verified live by forced probes, so non-firing was the model's
   choice. To make an advisor fire you must escalate the instruction to the point where you are
   measuring obedience, not judgment.
5. **Measurement can contaminate behavior.** Asking the child session to *report advisor
   availability* caused it to make a test call to the advisor (caught in smoke, fixed to
   "observe the tool list only"). Pre-register instrumentation wording and smoke-test it.
6. **Where the money went.** Round 2 c3: the orchestrator (fable) spent its tokens on
   verification and synthesis while 16 grok workers (12 + 4 retries) burned 615k ctxTokens on
   xAI's meter; c3 also had the *lowest* Claude-side haiku/web usage of all arms because
   collection was pushed off-quota. Delegation moved the heavy, parallelizable part of the task
   onto the separate wallet without costing accuracy — that, plus finding #2, is the case for
   this skill.
7. **Worker quality is a cost knob, not an accuracy knob.** With deepseek workers (c4), 5 of 12
   currency areas ultimately came back unusable and the orchestrator collected them itself —
   accuracy stayed at 100%, but the Claude-side bill rose to $9.81 vs c3's $7.66 and fable's
   output tokens were the highest of any arm. The structure absorbs worker failure by spending
   orchestrator effort; a better worker (grok: 3 of 12 unusable) keeps more of the work on the
   cheap meter. Pick workers by failure rate × external price, not by benchmark IQ.

## Reusing the frame for the next model / channel

To compare a new delegate (a different CLI, a different model family, a new mode) against these
numbers, keep the frame and swap the arm:

1. **Pick the task shape by what you want to discriminate.** Lookup tasks saturate (round 1);
   plant judgment traps (official-vs-operational definitions, vintage/freshness, source
   attribution, cascades) if you want spread. Re-check the trap answers on execution day —
   they drift with release calendars.
2. **Always run three reference arms**: the candidate structure (orchestrator + delegate
   workers), the orchestrator model solo, and the delegate model solo. The delta
   *structure vs both solos* is the finding; candidate-vs-solo alone confounds model and
   procedure.
3. **Blind-shuffle results before judging; ban methodology traces in result files; audit the
   judge's file access afterwards.** Judge verifies against primary sources, verbatim, and may
   not resolve a cell from background knowledge.
4. **Report tokens per model, raw, from first-party metering** — never sum across models. For an
   external delegate, capture its own meter (this repo's wrapper prints the `[grok-usage]`
   trailer for exactly this reason).
5. **Gate worker outputs on collection evidence, not exit codes** (tool-call counts / tool
   lists). Budget one retry with strengthened wording, then fall back to direct collection.
6. **Fix the run order cheapest-first, complete all arms plus judging in one day, and log CLI
   and model versions** (these runs: claude CLI 2.1.206, grok 0.2.93, grok-4.5,
   claude-sonnet-5 / claude-fable-5).

## Open caveats

- **n=1 per arm.** The three sonnet-family runs in round 2 spread across 3 cells
  (95.8–100%), so single-run ties at the top (c0 vs c3) are inside noise. What survives n=1 is
  the *streak* (c3's 142/142 across two rounds and two task shapes) and the *matched failure
  fingerprints* of the solo arms.
- **The post-hoc arms (round-2 solo grok c6, fable + deepseek c4) were scored against the frozen
  key, not blind** — comparable in method to each other, directionally comparable to A–E. Round
  1's c4 was a full blind arm.
- **grok 0.2.93's `research` mode fails closed** (upstream bug combining web tools with the
  read-only allowlist), so the eval workers ran `research-rw` with the user's explicit OK. When
  xAI ships the fix, the same eval frame can compare `research` (read-only) workers directly.
