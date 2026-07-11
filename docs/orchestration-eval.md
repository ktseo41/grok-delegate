# Is grok delegation actually worth it? — the orchestration evals

Two rounds of controlled experiments on real web-research tasks, testing whether **fable
orchestrating grok workers** actually beats the alternatives. The lineup: the same structure
with other workers (fable + sonnet workers, fable + deepseek workers) and three solo runs
(fable solo, sonnet solo, grok solo).

Raw artifacts (prompts, harnesses, per-run `run.json`, worker outputs, blind copies, judge
scoreboards) are kept outside this repo in a private experiment workspace. This page uses
configuration names throughout and transcribes every number, so the results are readable
without the raw data.

## TL;DR

**Verdict: yes.** fable + one grok worker per topic beat every alternative tested — a
perfect score on both task shapes (72/72 lookup, 72/72 judgment traps), at the lowest
Claude-side spend of each round ($2.69 / $2.97 API-equivalent, no web usage on the Claude
meter at all) and the fastest wall-clock. In this configuration the orchestrator only
splits the task and assembles what workers report — no re-verification pass; a variant
that adds one scored the same with grok workers and only multiplied the Claude bill
(raw runs in the workspace, summary in lesson #8).

![Round 1 — cells lost per configuration](assets/r1-accuracy.svg)

![Round 2 — cells lost per configuration](assets/r2-accuracy.svg)

| Configuration | Round 1 (lookup task) | Round 2 (judgment-trap task) |
| --- | --- | --- |
| **fable + grok workers** | **72/72 (100%)** — 7.4 min, 12/12 workers on the first wave, zero retries; cheapest Claude-side run of the whole eval ($2.69) | **72/72 (100%)** — 9.5 min, cheapest Claude-side run of round 2 ($2.97) |
| fable + deepseek workers | 71/72 (98.6%) — 47 min (slowest); 12/12 workers completed (3 retries, all output-format slips, zero collection failures); the only loss was writing the effective date as the Fed's decision date | 24/72 — 8/12 workers returned nothing (channel defect; pre-dates the round-1 channel fix); every completed cell correct (24/24) |
| fable + sonnet workers | **72/72 (100%)** — 7.6 min, 12/12 workers; heaviest Claude spend ($11.05) | 69/72 (95.8%) — a wrong index choice passed through uncaught (3-cell cascade) |
| sonnet solo | 70/72 (97.2%) | 69.3/72 (96.3%) — average of 3 runs (70·69·69) |
| fable solo | 71/72 (98.6%) | 66/72 (91.7%); hit both release-timing traps |
| grok solo | **72/72 (100%)** | 65/72 (90.3%) — hit the exact same traps as fable solo |

Every score above comes from one scoring procedure. Each round was judged blind — the
reports were scored without knowing which came from which configuration.

<sub>*A variant workflow where the orchestrator (fable) re-verifies and corrects every worker
result was also run, but the goal here is testing grok delegation, not workflows, so it is
excluded. In short: with grok workers it scored the same perfect marks and only cost 2–3×
more Claude-side ($6.09–7.66) — raw runs in the experiment workspace.*</sub>

The perfect scores came from narrowing the scope. Each worker handled exactly one central
bank, and the worker prompts required that every claim come from a page actually fetched in
that session — answers from memory were declared invalid. Those two things alone kept grok
workers perfect on both task shapes with nothing double-checking them, and sonnet workers
matched them on the lookup task — but a sonnet worker's wrong index choice went straight
into the round-2 result. For deepseek workers the variable was the execution channel
(via the codex CLI): with the channel defective in round 2, 8/12 workers returned nothing;
with the channel repaired for round 1, all 12 completed and scored 71/72 — when they
finish, their accuracy is in the top tier (95/96 completed cells across both rounds).

Why sonnet solo is "3 runs": two of round 2's three runs carried advisor(fable), a
stronger-model consultation tool, and it **never fired** (the plumbing was verified with
forced probe calls — non-firing was the model's choice, and a one-line "feel free to
consult the advisor" hint changed nothing). Since the treatment never arrived, all three
runs are repeats of sonnet solo, and their score spread (70/72, 69/72, 69/72) is our
estimate of sonnet's run-to-run variance; tables and charts show the average (69.3/72).
Since this eval is not about whether the advisor feature works, no further advisor runs
were made — the three sonnet runs are simply recorded as their average.

## The tasks

- **Round 1 — lookup.** Current monetary-policy settings of 12 central banks, 6 fields each
  (instrument name, value, last-change date, magnitude/direction, next meeting, verbatim
  decision-statement quote + URL). Official sources only. 12 × 6 = 72 cells. The Singapore
  (MAS) website was down for maintenance throughout, but domain-limited search still let
  every cell be scored. Every configuration scored 97–100% — the task was
  easy enough that everyone bunched up near the ceiling, so it could not discriminate; only
  one detail slip and the citation field separated configurations.
- **Round 2 — judgment traps.** Real policy rate of 12 currency areas: policy rate (central
  bank) − latest YoY of the index the bank **officially targets** (national statistics
  office), computed to two decimals. Traps planted per field:
  - **Index choice**: countries where the official target index differs from the commonly
    quoted one (US targets PCE not CPI, Sweden CPIF, Norway CPI vs CPI-ATE, Japan all-items
    vs ex-fresh-food).
  - **Release timing**: inflation statistics come out as a preliminary (flash) figure first
    and are finalized later. Does the run respect a label the source itself marks
    "preliminary", and does it catch a release published just days before the run?
  - **Source attribution**: the primary source for a price index is the statistics office,
    not the central bank.
  - **Cascade scoring**: a wrong index choice also costs the arithmetic cell computed from
    it.

  12 × 6 = 72 cells, 1 point each.

> A "trap" here is a deliberately-planted easy-to-get-wrong spot — the point is not what the
> model knows but whether it actually slips where slipping is easy.

## Controls that made the numbers trustworthy

- **Unified judging.** Each round's reports were shuffled together and scored by a single
  fable judge session that never saw the mapping, against one shared answer key. Result
  files were verified by scan to contain zero methodology traces (anything hinting which
  configuration produced them), and the judge session's file access was audited post-run
  from its transcript: it read exactly the shuffled copies and the key. Round 1 happened to
  be judged by three independent sessions with different shuffles — their verdicts on the
  same reports matched cell for cell.
- **Identical prompts.** Paired configurations shared the same prompt file; the two
  advisor(fable) runs differ by exactly one documented line, byte-identical otherwise
  (`diff` kept).
- **Narrow execution window + answer-drift control.** All runs sat inside 2026-07-10–11,
  and release calendars plus the judging records confirm no answer-changing release or rate
  decision landed inside that window. A both-accepted rule for releases landing on an
  execution day was fixed in advance (no report ended up needing it). Judging finished the
  same day for all configurations.
- **Predictions written down first.** Expectations — which configuration would win, whether
  the advisor(fable) would fire on its own — were written to a file before execution and
  compared against the results afterwards. This guards against fitting the interpretation to
  the outcome. Worker-failure handling (one retry, then orchestrator collects directly) was
  also pre-declared in the harness prompts.
- **Raw per-model token reporting.** Tokens are reported per model (fable / sonnet / haiku /
  grok / deepseek) as raw values; models with different prices are never summed into one
  number. (haiku-4.5 is not a tested configuration — it is the model Claude Code's WebSearch
  uses automatically to summarize fetched pages, so it shows up in every Claude-side run.)
  Claude-side figures come from `run.json` model-usage data; grok's own spend from the
  wrapper's `[grok-usage]` trailer (ctxTokens, wall seconds, tool calls per worker). The
  wrapper is this repo's `scripts/grok-run.sh`, the launch script every grok run here goes
  through: the grok CLI reports no usage on its own, so the wrapper appends this trailer
  after each session, and it also enforces the run-mode guardrails (tool allowlists, the
  web-collection gate described below).
- **Tool discipline.** All configurations: no skills, no MCP; subagents only where they
  *are* the configuration's worker channel (the sonnet-worker configuration spawns its
  workers via the Agent tool; grok and deepseek workers run through their external CLIs),
  never as an extra helper on top; web = WebSearch/WebFetch only (or grok's
  `web_search`/`web_fetch`); no curl; bot-blocked sites
  (403) handled by domain-limited search, never circumvention.

## Tokens and potential cost (raw per model)

### Round 1

![Round 1 — raw tokens per model](assets/r1-tokens.svg)

| Configuration | Model | in | out | cache write | cache read | ctxTokens³ |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| fable + grok workers | fable-5 | 3,025 | 16,184 | 73,594 | 375,824 | — |
| | grok-4.5 (12 worker sessions) | — | — | — | — | 735,055 |
| fable + deepseek workers | fable-5 | 3,176 | 18,750 | 68,874 | 760,200 | — |
| | deepseek-v4-flash (15 sessions) | 18,661,070¹ | 187,377² | — | — | — |
| fable + sonnet workers | fable-5 | 10,123 | 24,916 | 89,685 | 787,448 | — |
| | sonnet-5 | 116,460 | 52,193 | 409,152 | 2,567,989 | — |
| | haiku-4.5⁴ | 2,895,427 | 30,475 | 0 | 0 | — |
| sonnet solo | sonnet-5 | 18,816 | 31,487 | 153,605 | 5,962,593 | — |
| | haiku-4.5 | 1,599,289 | 22,395 | 0 | 0 | — |
| fable solo | fable-5 | 8,330 | 49,839 | 133,803 | 1,939,729 | — |
| | haiku-4.5 | 1,361,978 | 14,115 | 0 | 0 | — |
| grok solo | grok-4.5 (1 session) | — | — | — | — | 141,786 |

¹ includes 11,094,784 cached input — deepseek's meter counts cache hits *inside* its input
total, unlike Claude's separate cache columns, so it is a footnote here rather than a value
in those columns. The unusually large input is because deepseek workers collect via shell
fetches, reading raw page sources whole. ² includes 72,599 reasoning tokens. ³ the grok CLI exposes no billable
in/out split, only the session's final context size (ctxTokens) — a separate meter, not
summable with the other columns. ⁴ **why haiku appears at all**: haiku is not run by the
eval — it is the model Claude Code's WebSearch/WebFetch tooling uses internally to digest
fetched pages, so its row measures how much web traffic the *Claude-side session itself*
generated. In the grok- and deepseek-worker configurations the orchestrator had web tools
disabled and did no web traffic of its own, so haiku is exactly zero — the collection all
happened on the external meter. The sonnet-worker haiku row is the *workers'* web traffic
(they run inside the same Claude session).

![Round 1 — potential cost per configuration](assets/r1-cost.svg)

| Configuration | Claude-side (measured, API-equivalent) | External spend |
| --- | ---: | :-- |
| fable + grok workers | $2.69 | grok: ≈5%p of weekly SuperGrok quota (scaled by ctxTokens) |
| fable + deepseek workers | $3.11 | deepseek ≈ $1.71 (OpenRouter rates, no cache discount) |
| fable + sonnet workers | $11.05 | — |
| sonnet solo | $5.49 | — |
| fable solo | $8.84 | — |
| grok solo | $0 | grok: ≈1%p of weekly SuperGrok quota (scaled by ctxTokens) |

### Round 2

![Round 2 — raw tokens per model](assets/r2-tokens.svg)

| Configuration | Model | in | out | cache write | cache read | ctxTokens³ |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| fable + grok workers | fable-5 | 3,019 | 18,420 | 75,322 | 511,531 | — |
| | grok-4.5 (21 worker sessions) | — | — | — | — | 833,433 |
| fable + deepseek workers | fable-5 | 3,631 | 34,063 | 91,662 | 3,253,122 | — |
| | deepseek-v4-flash (23 metered runs) | 3,895,032¹ | 56,806² | — | — | — |
| fable + sonnet workers | fable-5 | 16,804 | 30,695 | 98,534 | 707,014 | — |
| | sonnet-5 | 109,007 | 62,005 | 422,890 | 3,642,666 | — |
| | haiku-4.5⁴ | 2,363,450 | 34,213 | 0 | 0 | — |
| sonnet solo (avg of 3 runs) | sonnet-5 | 19,799 | 40,191 | 176,709 | 7,067,494 | — |
| | haiku-4.5 | 1,454,400 | 26,202 | 0 | 0 | — |
| fable solo | fable-5 | 4,065 | 50,150 | 200,396 | 1,927,217 | — |
| | haiku-4.5 | 1,134,678 | 13,843 | 0 | 0 | — |
| grok solo | grok-4.5 (1 session) | — | — | — | — | 161,675 |

¹ includes 2,095,104 cached input — deepseek's meter counts cache hits *inside* its input
total, unlike Claude's separate cache columns, so it is a footnote here rather than a value
in those columns. ² includes reasoning tokens. ³ ⁴ same footnotes as the round-1 table.

![Round 2 — potential cost per configuration](assets/r2-cost.svg)

| Configuration | Claude-side (measured, API-equivalent) | External spend |
| --- | ---: | :-- |
| **fable + grok workers** | **$2.97** | grok: ≈5%p of weekly SuperGrok quota (scaled by ctxTokens; 21 sessions incl. 9 gate-blocked cheap retries) |
| fable + deepseek workers | $6.83 | deepseek ≈ $0.36 (OpenRouter rates, no cache discount) |
| fable + sonnet workers | $11.54 | — |
| sonnet solo (avg of 3 runs) | $5.99 | — |
| fable solo | $9.95 | — |
| grok solo | $0 | grok: ≈1%p of weekly SuperGrok quota (measured) |

Cost shape in one line: the grok-worker configuration undercuts everything (even sonnet
solo) because the orchestrator does no web work at all; the deepseek configuration's $6.83
is orchestrator turns spent wrangling worker failures; the sonnet-worker configuration is
the most expensive because its workers bill the Claude meter.

### Where each number comes from — and the grok caveat

- **Claude models**: `run.json` → `modelUsage`, per model, per run. First-party and exact.
  The cost column is `run.json total_cost_usd` — what the run would cost at API list prices;
  subscription users spend quota, not cash.
- **deepseek (via codex CLI)**: exact per-session `total_token_usage` (input / cached input /
  output / reasoning) is in the codex rollout logs at
  `$HOME/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl` — sum the sessions in the run's
  time window. Cross-checkable against the OpenRouter activity CSV export (round 1 uses the
  CSV figures directly).
- **grok (via grok CLI)**: every grok run here used a SuperGrok subscription — no dollars
  are billed; runs consume a weekly usage limit. grok cost is therefore reported in
  **percentage points of the weekly quota**, not dollars. Measurement: each CLI start logs
  the weekly-limit percentage (`creditUsagePercent`, 1-point granularity) to
  `$HOME/.grok/logs/unified.jsonl`, and round 2's grok-solo run (ctxTokens 161,675) moved it
  by exactly one point — that is the measured anchor. The other runs share time windows with
  each other, so they cannot be separated at 1-point granularity; their figures are scaled
  from the anchor by each run's ctxTokens (the session's final context size from
  `signals.json`, the value the wrapper's trailer prints). For reference, the grok CLI
  records no billable in/out split anywhere local, and the console Usage Explorer covers
  API-key billing only — ctxTokens is the only first-party meter available client-side.

Charts regenerate via `assets/gen_charts.py`.

## What the evals taught (and what changed in this repo because of them)

1. **The dangerous failure is silent no-collection, not crashes.** In round 2, 9 of 12
   first-wave grok workers exited 0 with plausible, normal-sized output **written from model
   memory with zero web calls** — invisible in exit code, size, or text; the usage trailer's
   tool list was the only signal. The wrapper's **web-collection gate** (a
   `research`/`research-rw` run with no web tool call exits non-zero — `FAILED: … no web
   tool call`) caught all 9, and a retry carrying a "real `web_fetch` for every claim"
   prompt line recovered all of them. In round 1 that line was in the worker prompts from
   the start and the gate never fired. See `scripts/grok-run.sh`; regression-tested in
   `evals/stub-regression.sh` (H6).
2. **Solo runs of strong models miss mechanical diligence, not reasoning.** Round 2's
   decisive cells were "respect the source's own *preliminary* label" and "scan for a release
   published two days ago". Solo fable and solo grok both missed exactly these; every
   arithmetic error in the whole eval was zero. If the task has trap-shaped
   freshness/labeling cells, buy **narrow scope** — one topic per worker, forced to fetch
   real pages — before buying a bigger model (see #8).
3. **Splitting across workers also wins on turn budget.** A single grok session doing 12
   topics blew the default `--max-turns 30` and died mid-task (round 1 grok solo, first
   attempt); per-topic workers each used 3–17 tool calls and finished in about one worker's
   elapsed time. The wrapper now logs the *effective* turn cap, and SKILL.md documents the
   sizing rule.
4. **An idle advisor is not a safety net.** The advisor(fable) tool exposed to sonnet fired
   **0 times across 4 runs in both rounds** — including with a neutral one-line hint, and
   including on a cell where sonnet wrote down the correct official wording and then chose
   the wrong index anyway. The plumbing was verified live by forced probes, so non-firing was
   the model's choice. To make an advisor fire you must escalate the instruction to the point
   where you are measuring obedience, not judgment.
5. **Measurement can contaminate behavior.** Asking the child session to *report advisor
   availability* caused it to make a test call to the advisor (caught in smoke, fixed to
   "observe the tool list only"). Pre-write instrumentation wording and smoke-test it before
   the main runs.
6. **Where the money went.** In the grok-worker configuration the orchestrator (fable)
   spent its tokens on splitting and assembly while the grok workers burned their ctxTokens
   on xAI's meter; with the orchestrator's web tools disabled its Claude-side haiku/web
   usage was exactly zero. Delegation moved the heavy, parallelizable part of the task onto
   the separate wallet without costing accuracy — that, plus finding #2, is the case for
   this skill.
7. **Fix worker completion at the channel layer; compare worker models on completed-work
   accuracy.** A worker that cannot finish is a channel/tooling problem to fix at the
   worker layer, not something to paper over with orchestrator effort — and fixing the
   deepseek channel proved it: a minimal `CODEX_HOME` (its default config's MCP/plugin
   tools serialize as a `namespace` tool type OpenRouter rejects with a 400), a
   collection gate, a bigger retry budget, and a final-message format rule took round-1
   completion to 12/12. The metric that actually compares worker *models* is
   **completed-work accuracy**: grok 144/144, deepseek 95/96 (the single loss wrote the
   effective date as the Fed's decision date), sonnet 141/144 with all three losses on
   one judgment trap's cascade. Since the score alone cannot distinguish completion
   failure from judgment error, always report the failure rate next to the score (as the
   TL;DR table does).
8. **Re-verification is worker insurance — with grok workers you can skip it.** A variant
   where the orchestrator re-checks every worker number against the primary source (runs
   kept in the workspace) scored exactly the same as the main table with grok workers and
   cost 2–3× more Claude-side ($6.09–7.66 vs $2.69–2.97), because the re-checking runs on
   the Claude web meter. The only place the insurance actually paid out was sonnet
   workers on the judgment task, where the uninsured run let a wrong index choice through
   (69/72). One more note for the next round: the traps now catch almost nobody — this
   task's discriminative power is spent, so a rematch needs harder judgment-layer traps.

## Reusing the frame for the next model / channel

To compare a new delegate (a different CLI, a different model family, a new mode) against
these numbers, keep the frame and swap the configuration:

1. **Pick the task shape by what you want to discriminate.** Plain lookup tasks cannot
   discriminate — every model bunches up near a perfect score (round 1). If you want spread,
   plant judgment traps (official-vs-commonly-quoted definitions, release timing, source
   attribution, cascades). Re-check the trap answers on execution day — they shift with
   release calendars.
2. **Always run three reference configurations**: the candidate structure (orchestrator +
   delegate workers), the orchestrator model solo, and the delegate model solo. The finding
   is *structure beats both solos*; candidate-vs-one-solo confounds model and procedure.
3. **Blind-shuffle results before judging; ban methodology traces in result files; audit the
   judge's file access afterwards.** The judge verifies against primary sources, verbatim,
   and may not resolve a cell from background knowledge.
4. **Report tokens per model, raw, from each channel's first-party metering** — never sum
   across models. For an external delegate, capture its own meter (this repo's wrapper prints
   the `[grok-usage]` trailer for exactly this reason).
5. **Gate worker outputs on collection evidence (tool-call counts / tool lists), not exit
   codes.** Pre-declare the retry budget and the fallback after it (whether the orchestrator
   may collect directly) in the harness, and **always report how often the fallback fired
   next to the score** — the score alone cannot distinguish a configuration whose workers did
   the work from one whose orchestrator filled the gaps.
6. **Fix the run order cheapest-first, complete all configurations plus judging inside the
   narrowest window you can, verify with release calendars that nothing answer-changing
   landed inside it, and log CLI and model versions** (these runs: claude CLI 2.1.206,
   grok 0.2.93, grok-4.5, claude-sonnet-5 / claude-fable-5).

## Open caveats and follow-ups

- **n=1 per configuration.** The three round-2 sonnet runs spread across 1 cell
  (70·69·69), so 1–2-cell gaps between configurations are inside noise. What survives n=1
  is the *streak* (grok workers at 144/144 across both task shapes) and the *matched
  failure fingerprints* of the solo runs.
- **Scores are from a unified re-judging on 2026-07-11.** During the original experiment
  the scoring method varied per run (those records stay in the workspace); every report was
  then re-scored with one shared key and one procedure, removing the method differences.
  A few configurations moved by 1–2 cells in absolute terms; the ranking and conclusions
  are unchanged. Two accuracy cross-checks: before unification, two judge sessions once
  disagreed on the same cell (an RBA meeting-calendar misread — overturned against the
  official page, adjudication record in the workspace), and in the unified re-judging three
  independent sessions with different shuffles matched cell for cell on the same five
  reports. A single judge session has its own error rate; cross-run verdict comparison is
  a cheap error detector.
- **Follow-up candidates.** ① fable + sonnet workers plus a re-verification pass on a
  judgment-trap task: whether the verification layer catches the wrong index choice
  (69/72) is the test of sonnet workers' insurance case. ② A haiku-worker configuration
  would add one more data point to "pick workers by failure rate × external price".
  ③ Re-measure round 2 with the repaired deepseek channel — the round-1 fix (minimal
  `CODEX_HOME` baked into the harness, collection gate, bigger retry budget) took
  completion from 8/12-unanswered to 12/12, so it is worth checking that the same recovery
  holds on the judgment-trap task; its price is 1–2% of sonnet's.
  ④ Any rematch needs a harder task — these traps no longer separate configurations.
- **grok 0.2.93's `research` mode fails closed** (upstream bug combining web tools with the
  read-only allowlist), so the eval workers ran `research-rw` with the user's explicit OK.
  When xAI ships the fix, the same frame can compare `research` (read-only) workers directly.
