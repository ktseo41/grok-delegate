#!/usr/bin/env python3
"""Generate the static SVG charts for docs/orchestration-eval.md (+ .ko.md).

Data below is transcribed from the round-1 and round-2 eval artifacts
(run.json modelUsage, codex rollout / OpenRouter CSV totals, grok signals.json)
— see the token tables in orchestration-eval.md for provenance.
Round-2 "sonnet solo" is the average of its 3 runs.
Regenerate with:  python3 gen_charts.py
"""
import os

OUT = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- palette ---
# Validated categorical palette (dataviz reference instance, light mode).
MODEL_COLOR = {
    "fable":    "#2a78d6",  # blue
    "sonnet":   "#1baf7a",  # aqua   (sub-3:1 -> direct labels everywhere)
    "haiku":    "#eda100",  # yellow (sub-3:1 -> direct labels everywhere)
    "grok":     "#008300",  # green
    "deepseek": "#4a3aa7",  # violet
}
SURFACE = "#fcfcfb"; INK = "#0b0b0b"; INK2 = "#52514e"; MUTED = "#898781"
GRID = "#e1e0d9"; BASE = "#c3c2b7"
BAR_BLUE = "#2a78d6"; BAR_BLUE_LIGHT = "#9ec5f4"
FONT = 'font-family="system-ui,-apple-system,Segoe UI,sans-serif"'

# ------------------------------------------------------------------- data ---
# Accuracy rows: (label, lost cells, score text, non-blind?)
ACC_R1 = [
    ("fable + grok workers",       0,    "71/71 · 100%‡", True),
    ("fable solo",                 1,    "69/70 · 98.6%",  False),
    ("grok solo",                  1,    "66/67 · 98.5%†", True),
    ("sonnet solo",                2,    "68/70 · 97.1%",  False),
]
NOTE_R1 = ["Lighter bars: not blind-judged. † = scored vs the frozen answer key; unverifiable cells excluded.",
           "‡ = judged by re-verifying every cell against official pages on scoring day (the frozen key had",
           "drifted); denominator 71 — one MAS cell unscorable vs two in the blind-judged runs."]
ACC_R2 = [
    ("fable + grok workers",       0,    "72/72 · 100%",   False),
    ("sonnet solo (avg of 3)",     1.67, "70.3/72 · 97.7%", False),
    ("fable solo",                 4,    "68/72 · 94.4%",  False),
    ("grok solo",                  4,    "67/71 · 94.4%†", True),
    ("fable + sonnet workers",     4,    "66/70 · 94.3%†", True),
]
NOTE_R2 = ["Lighter bars: not blind-judged. † = scored vs the frozen answer key; unverifiable cells excluded.",
           "fable + deepseek workers is off this scale: 8/12 workers returned nothing (tool bug, fixable)",
           "→ 24/72 overall — but every cell its workers did complete was correct.",
           "sonnet solo runs: 72/72, 70/72, 69/72."]

# Token rows: (label, [(model, in, out), ...], grok_ctx_or_None) — cache columns
# live in the doc tables. grok exposes only a final-context total (no in/out
# split), drawn as a dashed segment on the input panel.
TOKENS_R1 = [
    ("fable + grok workers",     [("fable", 3025, 16184)], 735055),
    ("sonnet solo",              [("sonnet", 18816, 31487), ("haiku", 1599289, 22395)], None),
    ("fable solo",               [("fable", 8330, 49839), ("haiku", 1361978, 14115)], None),
    ("grok solo",                [], 141786),
]
TOKENS_R2 = [
    ("fable + grok workers",     [("fable", 3019, 18420)], 833433),
    ("fable + deepseek workers", [("fable", 3631, 34063),
                                  ("deepseek", 3895032, 56806)], None),
    ("fable + sonnet workers",   [("fable", 16804, 30695), ("sonnet", 109007, 62005),
                                  ("haiku", 2363450, 34213)], None),
    ("sonnet solo (avg of 3)",   [("sonnet", 19799, 40191), ("haiku", 1454400, 26202)], None),
    ("fable solo",               [("fable", 4065, 50150), ("haiku", 1134678, 13843)], None),
    ("grok solo",                [], 161675),
]

# Cost rows: (label, claude_usd, external) — external = (model, lo, hi) or None.
COST_R1 = [
    ("fable + grok workers",     2.69, ("grok", 1.60, 15.90)),
    ("sonnet solo",              5.49, None),
    ("fable solo",               8.84, None),
    ("grok solo",                0.0, ("grok", 0.31, 5.08)),
]
COST_R2 = [
    ("fable + grok workers",     2.97, ("grok", 1.86, 16.68)),
    ("fable + deepseek workers", 6.83, ("deepseek", 0.36, 0.36)),
    ("fable + sonnet workers",   11.54, None),
    ("sonnet solo (avg of 3)",   5.99, None),
    ("fable solo",               9.95, None),
    ("grok solo",                0.0, ("grok", 0.35, 5.79)),
]

def fmt(n):
    if n >= 1_000_000: return f"{n/1e6:.2f}M"
    if n >= 1_000: return f"{n/1e3:.0f}k"
    return str(n)

def svg_open(w, h, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'width="{w}" height="{h}" role="img" aria-label="{title}">\n'
            f'<rect width="{w}" height="{h}" rx="8" fill="{SURFACE}"/>\n')

def text(x, y, s, size=12, fill=INK, anchor="start", weight="normal"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
            f'text-anchor="{anchor}" font-weight="{weight}" {FONT}>{s}</text>\n')

# ----------------------------------------------------- chart 1: accuracy ----
def chart_accuracy(round_no, rows, denom_note, extra_note=()):
    head = 44
    W = 780
    H = head + 34 * len(rows) + 34 + (10 + 15 * len(extra_note) if extra_note else 0)
    s = svg_open(W, H, f"Round {round_no} cells lost per configuration")
    s += text(20, 30, f"Round {round_no} — cells lost ({denom_note})", 15, INK, weight="600")
    x0, xmax, vmax = 250, W - 130, 5
    y = head + 14
    for label, lost, scoretxt, frozen in rows:
        color = BAR_BLUE_LIGHT if frozen else BAR_BLUE
        s += text(x0 - 10, y + 12, label, 12, INK, anchor="end")
        bw = (xmax - x0) * (lost / vmax)
        if lost == 0:
            s += f'<circle cx="{x0 + 3}" cy="{y + 8}" r="3.5" fill="{color}"/>\n'
        else:
            s += (f'<rect x="{x0}" y="{y}" width="{bw:.1f}" height="16" rx="4" '
                  f'fill="{color}"/>\n')
        s += text(x0 + max(bw, 7) + 8, y + 12, f"{lost:g} lost · {scoretxt}", 11, INK2)
        y += 34
    s += f'<line x1="{x0}" y1="{y}" x2="{xmax}" y2="{y}" stroke="{BASE}" stroke-width="1"/>\n'
    for v in range(0, vmax + 1):
        x = x0 + (xmax - x0) * v / vmax
        s += text(x, y + 16, str(v), 10, MUTED, anchor="middle")
    ny = y + 34
    for i, line in enumerate(extra_note):
        s += text(20, ny + 15 * i, line, 10.5, MUTED)
    return s + "</svg>\n"

# ------------------------------------------------------- chart 2: tokens ----
def chart_tokens(round_no, tokens, in_vmax, out_vmax):
    W = 1050
    row_h, gap = 26, 10
    panel_top = 78
    n = len(tokens)
    panel_h = n * (row_h + gap)
    H = panel_top + panel_h + 88
    s = svg_open(W, H, f"Round {round_no} raw tokens per model")
    s += text(20, 30, f"Round {round_no} — raw tokens per model (input / output)", 15, INK, weight="600")
    s += text(20, 48, "Bars stacked by model; cache tokens in the doc table. Dashed green: grok's final-context "
                      "total — its own meter, no in/out split.", 11, INK2)
    # legend
    lx = 20; ly = panel_top - 12
    for m in ("fable", "sonnet", "haiku", "deepseek"):
        s += f'<rect x="{lx}" y="{ly - 9}" width="10" height="10" rx="2" fill="{MODEL_COLOR[m]}"/>\n'
        s += text(lx + 14, ly, m, 11, INK2)
        lx += 14 + 8 * len(m) + 26
    s += (f'<rect x="{lx}" y="{ly - 9}" width="10" height="10" rx="2" fill="{MODEL_COLOR["grok"]}" '
          f'fill-opacity="0.25" stroke="{MODEL_COLOR["grok"]}" stroke-dasharray="3,2"/>\n')
    s += text(lx + 14, ly, "grok (ctx)", 11, INK2)
    order = {"fable": 0, "sonnet": 1, "haiku": 2, "deepseek": 3}
    panels = [("Input tokens", 0, in_vmax, 250, 330), ("Output tokens", 1, out_vmax, 745, 200)]
    for ptitle, idx, vmax, x0, pw in panels:
        s += text(x0, panel_top + 2, ptitle, 12, INK, weight="600")
        y = panel_top + 14
        for label, models, gctx in tokens:
            ms = sorted(models, key=lambda t: order[t[0]])
            if idx == 0:
                s += text(x0 - 10, y + row_h - 9, label, 12, INK, anchor="end")
            x = x0
            total = 0
            for m, tin, tout in ms:
                v = (tin, tout)[idx]
                total += v
                bw = pw * v / vmax
                if bw > 0.5:
                    s += (f'<rect x="{x:.1f}" y="{y}" width="{max(bw,1.5):.1f}" height="{row_h - 10}" rx="3" '
                          f'fill="{MODEL_COLOR[m]}" stroke="{SURFACE}" stroke-width="2"/>\n')
                x += bw
            parts = [fmt((tin, tout)[idx]) for m, tin, tout in ms]
            if idx == 0 and gctx:
                bw = pw * gctx / vmax
                s += (f'<rect x="{x:.1f}" y="{y}" width="{bw:.1f}" height="{row_h - 10}" rx="3" '
                      f'fill="{MODEL_COLOR["grok"]}" fill-opacity="0.25" '
                      f'stroke="{MODEL_COLOR["grok"]}" stroke-dasharray="3,2"/>\n')
                x += bw
                total += gctx
                parts.append(f"ctx {fmt(gctx)}")
            lbl = " + ".join(parts) or "—"
            s += text(x0 + pw * min(total, vmax) / vmax + 8, y + row_h - 9, lbl, 10, INK2)
            y += row_h + gap
        s += f'<line x1="{x0}" y1="{y}" x2="{x0 + pw}" y2="{y}" stroke="{BASE}"/>\n'
        s += text(x0, y + 14, "0", 10, MUTED)
        s += text(x0 + pw, y + 14, fmt(vmax), 10, MUTED, anchor="end")
    return s + "</svg>\n"

# --------------------------------------------------------- chart 3: cost ----
def chart_cost(round_no, cost):
    row_h, cfg_gap = 20, 16
    x0, W = 310, 940
    header = 76
    n_rows = sum(2 if ext else 1 for _, _, ext in cost)
    H = header + n_rows * row_h + len(cost) * cfg_gap + 44
    s = svg_open(W, H, f"Round {round_no} potential cost per configuration")
    s += text(20, 30, f"Round {round_no} — potential cost (USD, API-equivalent)", 15, INK, weight="600")
    s += text(20, 46, "Claude: measured (run.json, API list prices) · grok/deepseek: the delegate's own wallet, "
                      "estimated low–high bounds.", 11, INK2)
    xmax, vmax = W - 60, 22.0
    y = header
    for label, usd, ext in cost:
        block_h = (2 if ext else 1) * row_h
        s += text(20, y + block_h / 2 + 4, label, 12, INK, weight="600")
        s += text(x0 - 10, y + 12, "Claude", 10, INK2, anchor="end")
        bw = (xmax - x0) * usd / vmax
        if usd > 0:
            s += f'<rect x="{x0}" y="{y + 2}" width="{bw:.1f}" height="12" rx="3" fill="{BAR_BLUE}"/>\n'
            s += text(x0 + bw + 8, y + 12, f"${usd:.2f}", 10, INK2)
        else:
            s += f'<circle cx="{x0 + 3}" cy="{y + 8}" r="3" fill="{BAR_BLUE}"/>\n'
            s += text(x0 + 12, y + 12, "$0", 10, INK2)
        y += row_h
        if ext:
            model, lo, hi = ext
            s += text(x0 - 10, y + 12, model, 10, MODEL_COLOR[model], anchor="end")
            bw_lo = (xmax - x0) * lo / vmax
            bw_hi = (xmax - x0) * hi / vmax
            s += (f'<rect x="{x0}" y="{y + 2}" width="{max(bw_lo, 2):.1f}" height="12" rx="3" '
                  f'fill="{MODEL_COLOR[model]}"/>\n')
            if hi > lo:
                s += (f'<rect x="{x0 + bw_lo:.1f}" y="{y + 2}" width="{bw_hi - bw_lo:.1f}" height="12" '
                      f'rx="3" fill="{MODEL_COLOR[model]}" opacity="0.3"/>\n')
                s += text(x0 + bw_hi + 8, y + 12, f"est. ${lo:.2f}–${hi:.2f}", 10, INK2)
            else:
                s += text(x0 + max(bw_lo, 2) + 8, y + 12, f"${lo:.2f}", 10, INK2)
            y += row_h
        y += cfg_gap
    s += f'<line x1="{x0}" y1="{y}" x2="{xmax}" y2="{y}" stroke="{BASE}"/>\n'
    for v in (0, 5, 10, 15, 20):
        x = x0 + (xmax - x0) * v / vmax
        s += f'<line x1="{x:.1f}" y1="{y}" x2="{x:.1f}" y2="{y + 4}" stroke="{BASE}"/>\n'
        s += text(x, y + 16, f"${v}", 10, MUTED, anchor="middle")
    return s + "</svg>\n"

if __name__ == "__main__":
    charts = {
        "r1-accuracy.svg": lambda: chart_accuracy(1, ACC_R1, "of 70 fields; ‡ of 71", NOTE_R1),
        "r2-accuracy.svg": lambda: chart_accuracy(2, ACC_R2, "of 72 fields", NOTE_R2),
        "r1-tokens.svg":   lambda: chart_tokens(1, TOKENS_R1, 1_800_000, 70_000),
        "r2-tokens.svg":   lambda: chart_tokens(2, TOKENS_R2, 4_200_000, 130_000),
        "r1-cost.svg":     lambda: chart_cost(1, COST_R1),
        "r2-cost.svg":     lambda: chart_cost(2, COST_R2),
    }
    for name, fn in charts.items():
        p = os.path.join(OUT, name)
        with open(p, "w") as f:
            f.write(fn())
        print("wrote", p)
