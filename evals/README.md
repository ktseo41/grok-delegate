# Evals

## Triggering eval — `trigger-eval.json`

Does the skill's `description` make Claude invoke grok-delegate when it should, and stay out of
the way when it shouldn't? Each entry is `{ "query": "...", "should_trigger": true | false }`.
20 cases, balanced (10 should-trigger, 10 should-not), mixing English and Korean, with
near-miss negatives — e.g. "review this PR yourself", "delegate to codex" — that must **not**
trigger.

### Run it

Uses Anthropic's `skill-creator` description optimizer (not bundled here). From the skill-creator
directory:

```bash
python -m scripts.run_loop \
  --eval-set /path/to/grok-delegate/evals/trigger-eval.json \
  --skill-path /path/to/grok-delegate \
  --model <your-session-model-id> \
  --max-iterations 5 --verbose
```

It splits the set into train/test, runs each query 3x for a stable trigger rate, proposes
`description` edits, and selects the best by held-out **test** score.

### Baseline

As of commit `7b09856` (the current description), a 5-iteration run scored **best_train 7/13,
best_test 4/7** (holdout 0.4). That is low: in the headless `claude -p` harness the skill
under-triggered on several clear should-trigger queries (e.g. "offload this codebase review to
grok", "spin up grok as a subagent"), even though it triggers reliably in interactive use. Worth
revisiting — re-run against the current description and dig into which should-trigger cases fail.

### Adding cases

Append `{ "query": "...", "should_trigger": true | false }`. Keep the trigger/no-trigger split
roughly balanced, prefer realistic phrasings (file paths, casual speech, typos, Korean), and make
negatives near-misses rather than obviously unrelated.

## Run outputs are not versioned

Run artifacts (`results.json`, `report.html`, `loop.log`, `opt-run/<timestamp>/`) are generated,
not committed — they land in the sibling `grok-delegate-workspace/` (outside this repo) and are
gitignored. The Baseline section above is the lightweight record kept in-repo.

## Behavior evals — not here yet

This only tests *triggering*. When the skill gains behavior worth asserting (correct mode
selection between `review`/`research`/`fix`, going through the wrapper, using `> file` for large
output), add `behavior-evals.json` with assertions alongside this file.
