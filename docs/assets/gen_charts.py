#!/usr/bin/env python3
"""Generate the three static SVG charts for docs/orchestration-eval.md.

Data below is transcribed from the round-2 eval artifacts (run.json modelUsage,
codex rollout total_token_usage, grok signals.json) — see the token table in
orchestration-eval.md for provenance. Regenerate with:  python3 gen_charts.py
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
# (arm, label, lost cells, denominator, score text, post-hoc?)
ACCURACY = [
    ("c3",  "fable + grok fan-out",      0, 72, "72/72 · 100%",   False),
    ("c0",  "sonnet solo",               0, 72, "72/72 · 100%",   False),
    ("c4",  "fable + deepseek (post-hoc)", 0, 71, "71/71 · 100%*", True),
    ("c5b", "sonnet + advisor (nudged)",  2, 72, "70/72 · 97.2%",  False),
    ("c5a", "sonnet + advisor",           3, 72, "69/72 · 95.8%",  False),
    ("c1",  "fable solo",                 4, 72, "68/72 · 94.4%",  False),
    ("c6",  "grok solo (post-hoc)",       4, 71, "67/71 · 94.4%*", True),
]
# * post-hoc arms: 1 unverifiable citation cell excluded from the denominator

# per-arm, per-model raw tokens: (in, out) — cache columns live in the doc table
TOKENS = [  # (arm, [(model, in, out), ...])
    ("c0",  [("sonnet", 19093, 44878), ("haiku", 1354379, 24771)]),
    ("c5a", [("sonnet", 22330, 33209), ("haiku", 1265412, 23478)]),
    ("c5b", [("sonnet", 17973, 42486), ("haiku", 1743408, 30356)]),
    ("c1",  [("fable", 4065, 50150), ("haiku", 1134678, 13843)]),
    ("c3",  [("fable", 5490, 41540), ("haiku", 532540, 6558)]),
    ("c4",  [("fable", 4436, 61922), ("haiku", 776230, 12144),
             ("deepseek", 2175635, 38361)]),
    ("c6",  []),
]
# external wallet, not in/out-metered: grok context-token totals
GROK_CTX = {"c3": 615004, "c6": 161675}

# cost: (arm, claude_usd_measured, ext_label, ext_lo, ext_hi)  ext = API-equivalent estimate
COST = [
    ("c3",  7.66, "grok est.",     1.41, 11.99),
    ("c0",  6.40, None,            None, None),
    ("c5b", 6.65, None,            None, None),
    ("c5a", 4.92, None,            None, None),
    ("c1",  9.95, None,            None, None),
    ("c4",  9.81, "deepseek",      0.20, 0.20),
    ("c6",  0.0,  "grok est.",     0.35, 5.78),
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
def chart_accuracy():
    rows = [r for r in ACCURACY if r[2] is not None]
    W, H = 720, 60 + 34 * len(rows) + 34
    s = svg_open(W, H, "Round 2 lost cells per arm")
    s += text(20, 30, "Round 2 — cells lost (of 72 fields)", 15, INK, weight="600")
    s += text(20, 48, "Lower is better. Lighter bars: post-hoc arms, scored vs the frozen key, non-blind; "
                      "* = 1 unverifiable cell excluded.", 11, INK2)
    x0, xmax, vmax = 250, W - 130, 5
    y = 74
    for _, label, lost, denom, scoretxt, posthoc in rows:
        color = BAR_BLUE_LIGHT if posthoc else BAR_BLUE
        s += text(x0 - 10, y + 12, label, 12, INK, anchor="end")
        bw = (xmax - x0) * (lost / vmax)
        if lost == 0:
            s += f'<circle cx="{x0 + 3}" cy="{y + 8}" r="3.5" fill="{color}"/>\n'
        else:
            s += (f'<rect x="{x0}" y="{y}" width="{bw:.1f}" height="16" rx="4" '
                  f'fill="{color}"/>\n')
        s += text(x0 + max(bw, 7) + 8, y + 12, f"{lost} lost · {scoretxt}", 11, INK2)
        y += 34
    s += f'<line x1="{x0}" y1="{y}" x2="{xmax}" y2="{y}" stroke="{BASE}" stroke-width="1"/>\n'
    for v in range(0, vmax + 1):
        x = x0 + (xmax - x0) * v / vmax
        s += text(x, y + 16, str(v), 10, MUTED, anchor="middle")
    return s + "</svg>\n"

# ------------------------------------------------------- chart 2: tokens ----
def chart_tokens():
    arms = [a for a, m in TOKENS]
    W = 930
    row_h, gap = 26, 10
    panel_top = 78
    n = len(arms)
    panel_h = n * (row_h + gap)
    H = panel_top + panel_h + 104
    s = svg_open(W, H, "Round 2 raw tokens per model")
    s += text(20, 30, "Round 2 — raw tokens per model (input / output)", 15, INK, weight="600")
    s += text(20, 48, "Bars stacked by model, in legend order; labels give each segment. Cache tokens in the doc table.", 11, INK2)
    # legend
    lx = 20; ly = panel_top - 12
    for m in ("fable", "sonnet", "haiku", "deepseek"):
        s += f'<rect x="{lx}" y="{ly - 9}" width="10" height="10" rx="2" fill="{MODEL_COLOR[m]}"/>\n'
        s += text(lx + 14, ly, m, 11, INK2)
        lx += 14 + 8 * len(m) + 26
    order = {"fable": 0, "sonnet": 1, "haiku": 2, "deepseek": 3}
    panels = [("Input tokens", 0, 3_000_000, 140, 330), ("Output tokens", 1, 130_000, 640, 160)]
    for ptitle, idx, vmax, x0, pw in panels:
        s += text(x0, panel_top + 2, ptitle, 12, INK, weight="600")
        y = panel_top + 14
        for arm, models in TOKENS:
            ms = sorted(models, key=lambda t: order[t[0]])
            if idx == 0:
                s += text(x0 - 10, y + row_h - 9, arm, 12, INK, anchor="end")
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
            label = " + ".join(fmt((tin, tout)[idx]) for m, tin, tout in ms) or "— (grok only)"
            s += text(x0 + pw * min(total, vmax) / vmax + 8, y + row_h - 9, label, 10, INK2)
            y += row_h + gap
        s += f'<line x1="{x0}" y1="{y}" x2="{x0 + pw}" y2="{y}" stroke="{BASE}"/>\n'
        s += text(x0, y + 14, "0", 10, MUTED)
        s += text(x0 + pw, y + 14, fmt(vmax), 10, MUTED, anchor="end")
    # external wallet note rows
    fy = panel_top + panel_h + 52
    s += text(20, fy, f'External wallet (not in/out-metered): grok ctxTokens — c3 {fmt(GROK_CTX["c3"])} (16 workers), '
                      f'c6 {fmt(GROK_CTX["c6"])} (1 session).', 11, INK2)
    s += text(20, fy + 16, "Exact grok in/out is not exposed for subscription CLI use — see the method note in the doc.", 11, INK2)
    return s + "</svg>\n"

# --------------------------------------------------------- chart 3: cost ----
def chart_cost():
    n_whisk = sum(1 for *_, e, lo, hi in COST if e)
    W, H = 800, 60 + 36 * len(COST) + 14 * n_whisk + 56
    s = svg_open(W, H, "Round 2 potential cost per arm")
    s += text(20, 30, "Round 2 — potential cost per arm (USD, API-equivalent)", 15, INK, weight="600")
    s += text(20, 48, "Solid: measured Claude-side cost (run.json). Whisker: external-wallet estimate range (see method note).", 11, INK2)
    x0, xmax, vmax = 250, W - 60, 22.0
    y = 76
    labels = dict((a, l) for a, l, *_ in ACCURACY)
    for arm, usd, elab, lo, hi in COST:
        s += text(x0 - 10, y + 12, labels.get(arm, arm), 12, INK, anchor="end")
        bw = (xmax - x0) * usd / vmax
        if usd > 0:
            s += f'<rect x="{x0}" y="{y}" width="{bw:.1f}" height="16" rx="4" fill="{BAR_BLUE}"/>\n'
            s += text(x0 + bw + 8, y + 12, f"${usd:.2f}", 11, INK2)
        else:
            s += f'<circle cx="{x0 + 3}" cy="{y + 8}" r="3.5" fill="{BAR_BLUE}"/>\n'
            s += text(x0 + 14, y + 12, "$0 Claude-side", 11, INK2)
        if elab:
            wx1 = x0 + (xmax - x0) * lo / vmax
            wx2 = x0 + (xmax - x0) * hi / vmax
            wy = y + 24
            s += (f'<line x1="{wx1:.1f}" y1="{wy}" x2="{wx2:.1f}" y2="{wy}" '
                  f'stroke="{MODEL_COLOR["grok" if "grok" in elab else "deepseek"]}" stroke-width="2"/>\n')
            for wx in (wx1, wx2):
                s += (f'<line x1="{wx:.1f}" y1="{wy - 4}" x2="{wx:.1f}" y2="{wy + 4}" '
                      f'stroke="{MODEL_COLOR["grok" if "grok" in elab else "deepseek"]}" stroke-width="2"/>\n')
            rng = f"${lo:.2f}" if lo == hi else f"${lo:.2f}–${hi:.2f}"
            s += text(wx2 + 8, wy + 4, f"+ {elab} {rng}", 10, INK2)
            y += 14
        y += 36
    s += f'<line x1="{x0}" y1="{y}" x2="{xmax}" y2="{y}" stroke="{BASE}"/>\n'
    for v in (0, 5, 10, 15, 20):
        x = x0 + (xmax - x0) * v / vmax
        s += f'<line x1="{x:.1f}" y1="{y}" x2="{x:.1f}" y2="{y + 4}" stroke="{BASE}"/>\n'
        s += text(x, y + 16, f"${v}", 10, MUTED, anchor="middle")
    return s + "</svg>\n"

if __name__ == "__main__":
    for name, fn in (("r2-accuracy.svg", chart_accuracy),
                     ("r2-tokens.svg", chart_tokens),
                     ("r2-cost.svg", chart_cost)):
        p = os.path.join(OUT, name)
        with open(p, "w") as f:
            f.write(fn())
        print("wrote", p)
