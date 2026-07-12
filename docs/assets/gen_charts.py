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

# -------------------------------------------------- shared layout ---
# The tokens and cost charts must read as siblings: same canvas width,
# same label column, same bar-start x, same row/bar heights, same
# title/caption/axis geometry. Both charts derive their layout from
# these constants so they stay aligned by construction, not by hand.
CHART_W    = 1050          # canvas width (tokens + cost)
LABEL_END  = 210           # row labels right-aligned to end here
BAR_X0     = 220           # plot area (bars) starts here  = LABEL_END + 10
BAR_XMAX   = CHART_W - 60   # plot area right edge
CONTENT_TOP = 100          # y of the first content row
ROW_H      = 26            # data-row height
BAR_H      = 16            # bar thickness
TITLE_Y, TITLE_SIZE = 30, 15
CAP_Y1, CAP_Y2, CAP_SIZE = 48, 63, 10.5
AXIS_SIZE  = 10            # axis tick-label size
AXIS_DY    = 15            # axis tick-label baseline below the axis line

# --------------------------------------------------------------- i18n ---
# Korean row labels, keyed by the canonical English label used in the data
# tables below. Score text (numbers/%/symbols) needs no translation.
LABEL_KO = {
    "fable + grok workers":     "fable + grok 워커",
    "fable + sonnet workers":   "fable + sonnet 워커",
    "fable + deepseek workers": "fable + deepseek 워커",
    "fable solo":               "fable 단독",
    "grok solo":                "grok 단독",
    "sonnet solo":               "sonnet 단독",
    "sonnet solo (avg of 3)":   "sonnet 단독 (3회 평균)",
}

STRINGS = {
    "en": {
        "acc_title":      lambda r, denom: f"Round {r} — cells lost ({denom})",
        "acc_aria":       lambda r: f"Round {r} cells lost per configuration",
        "tokens_aria":    lambda r: f"Round {r} raw tokens per model",
        "tokens_title":   lambda r: f"Round {r} — raw tokens per model (input / output)",
        "tokens_caption1": "Input bars are fresh (non-cached) tokens; deepseek and grok cache reads live in the table's cache-read column.",
        "tokens_caption2": "haiku: the model Claude Code uses internally to digest WebSearch/WebFetch pages — "
                           "it measures the Claude-side session's web traffic.",
        "input_panel":    "Input tokens",
        "output_panel":   "Output tokens",
        "grok_ctx":       "grok (ctx)",
        "cost_aria":      lambda r: f"Round {r} potential cost per configuration",
        "cost_title":     lambda r: f"Round {r} — potential cost (USD, API-equivalent)",
        "cost_caption1":  "API-equivalent (list-price replacement cost): Claude from run.json · deepseek actual OpenRouter spend · grok from its token log at grok-4.5 rates.",
        "cost_caption2":  "Actual outlay differs — both ran on subscriptions (grok SuperGrok $30/mo, Claude Max x20 $200/mo), where marginal $/run ≈ 0; these are the API-rate equivalents.",
        "claude_label":   "Claude",
        "acc_subtitle":   "Fewer cells lost is better.",
        "hero_aria":      "Both eval rounds — cells lost and cost per configuration",
        "hero_title":     "Two eval rounds, 144 research cells — accuracy and cost per configuration",
        "hero_caption":   "Cost is API-equivalent (list price), rounds 1+2 summed; grok/deepseek segments bill an external meter, not Claude.",
        "hero_acc_panel": "Cells lost (of 144)",
        "hero_cost_panel": "Cost (USD, API-equivalent)",
        "hero_lost":      "lost",
    },
    "ko": {
        "acc_title":      lambda r, denom: f"라운드 {r} — 조합별 손실 셀 ({denom})",
        "acc_aria":       lambda r: f"라운드 {r} 조합별 손실 셀",
        "acc_subtitle":   "손실 셀이 적을수록 좋은 결과다.",
        "tokens_aria":    lambda r: f"라운드 {r} 모델별 원시 토큰",
        "tokens_title":   lambda r: f"라운드 {r} — 모델별 원시 토큰(입력/출력)",
        "tokens_caption1": "입력 막대는 신규(비캐시) 토큰이다; deepseek·grok의 캐시 적중은 표의 cache read 열에 있다.",
        "tokens_caption2": "haiku: Claude Code가 WebSearch/WebFetch로 가져온 페이지를 소화할 때 내부적으로 쓰는 모델 — "
                           "Claude 쪽 세션의 웹 조회량 계측.",
        "input_panel":    "입력 토큰",
        "output_panel":   "출력 토큰",
        "grok_ctx":       "grok (ctx)",
        "cost_aria":      lambda r: f"라운드 {r} 조합별 잠재 비용",
        "cost_title":     lambda r: f"라운드 {r} — 잠재 비용(달러, API 환산)",
        "cost_caption1":  "API 정가 환산(대체비용): Claude는 run.json · deepseek는 OpenRouter 실비 · grok은 자체 토큰 로그를 grok-4.5 단가로 환산.",
        "cost_caption2":  "실제 지출은 다름 — 둘 다 구독(grok SuperGrok 월 $30, Claude Max x20 월 $200)이라 실행당 한계비용 ≈ $0; 이 막대는 API 정가 환산값.",
        "claude_label":   "Claude",
        "hero_aria":      "두 라운드 종합 — 조합별 손실 셀과 비용",
        "hero_title":     "평가 2라운드, 리서치 144셀 — 조합별 정확도와 비용",
        "hero_caption":   "비용은 API 정가 환산, 두 라운드 합산; grok/deepseek 구간은 Claude가 아닌 외부 미터에 과금.",
        "hero_acc_panel": "손실 셀 (144개 기준)",
        "hero_cost_panel": "비용 (달러, API 환산)",
        "hero_lost":      "손실",
    },
}

def label_for(label, lang):
    return LABEL_KO.get(label, label) if lang == "ko" else label

# ------------------------------------------------------------------- data ---
# Accuracy rows: (label, lost cells, score text). All runs rescored 2026-07-11
# with one uniform procedure (single verified key, shuffled reports, every
# quote checked against its source URL, denominator 72 for every row).
ACC_R1 = [
    ("fable + grok workers",       0,    "72/72 · 100%"),
    ("fable + sonnet workers",     0,    "72/72 · 100%"),
    ("grok solo",                  0,    "72/72 · 100%"),
    ("fable + deepseek workers",   1,    "71/72 · 98.6%"),
    ("fable solo",                 1,    "71/72 · 98.6%"),
    ("sonnet solo",                2,    "70/72 · 97.2%"),
]
NOTE_R1 = []
NOTE_R1_KO = []
ACC_R2 = [
    ("fable + grok workers",       0,    "72/72 · 100%"),
    ("fable + deepseek workers",   0,    "72/72 · 100%"),
    ("sonnet solo",                2.67, "69.3/72 · 96.3%", "*"),
    ("fable + sonnet workers",     3,    "69/72 · 95.8%"),
    ("fable solo",                 4,    "68/72 · 94.4%"),
    ("grok solo",                  5,    "67/72 · 93.1%"),
]
NOTE_R2 = ["* sonnet solo = average of 3 runs: 70/72, 69/72, 69/72."]
NOTE_R2_KO = ["* sonnet 단독 = 3회 실행 평균: 70/72, 69/72, 69/72."]

# Token rows: (label, [(model, in, out), ...]) — "in" is fresh (non-cached) input
# to match the doc tables; cache columns live there. grok's in/out come from its
# per-turn token log (unified.jsonl): fresh in = prompt − cached, out = completion.
# deepseek "in" is fresh input too (e.g. R1 18,661,070 total − 11,094,784 cached).
TOKENS_R1 = [
    ("fable + grok workers",     [("fable", 3025, 16184), ("grok", 834126, 35889)]),
    ("fable + deepseek workers", [("fable", 3176, 18750),
                                  ("deepseek", 7566286, 187377)]),
    ("fable + sonnet workers",   [("fable", 10123, 24916), ("sonnet", 116460, 52193),
                                  ("haiku", 2895427, 30475)]),
    ("sonnet solo",              [("sonnet", 18816, 31487), ("haiku", 1599289, 22395)]),
    ("fable solo",               [("fable", 8330, 49839), ("haiku", 1361978, 14115)]),
    ("grok solo",                [("grok", 200350, 11402)]),
]
TOKENS_R2 = [
    ("fable + grok workers",     [("fable", 3019, 18420), ("grok", 1281831, 60100)]),
    ("fable + deepseek workers", [("fable", 3180, 18638),
                                  ("deepseek", 13675649, 259998)]),  # 28,401,025 − 14,725,376 cached
    ("fable + sonnet workers",   [("fable", 16804, 30695), ("sonnet", 109007, 62005),
                                  ("haiku", 2363450, 34213)]),
    ("sonnet solo (avg of 3)",   [("sonnet", 19799, 40191), ("haiku", 1454400, 26202)]),
    ("fable solo",               [("fable", 4065, 50150), ("haiku", 1134678, 13843)]),
    ("grok solo",                [("grok", 248095, 11056)]),
]

# Cost rows: (label, claude_usd, external). All figures are API-equivalent
# (list-price replacement cost). The external segment stacks onto the Claude bar
# (same row) like the token chart's stacked segments.
# external = ("deepseek", usd) — actual OpenRouter spend, or
#            ("grok", usd) — computed from grok's per-turn token log
#            (~/.grok/logs/unified.jsonl) at grok-4.5 rates ($2 / $0.50 cached /
#            $6 per 1M), summed over the matched eval sessions.
COST_R1 = [
    ("fable + grok workers",     2.69, ("grok", 2.74)),
    ("fable + deepseek workers", 3.11, ("deepseek", 1.71)),
    ("fable + sonnet workers",   11.05, None),
    ("sonnet solo",              5.49, None),
    ("fable solo",               8.84, None),
    ("grok solo",                0.0, ("grok", 0.79)),
]
COST_R2 = [
    ("fable + grok workers",     2.97, ("grok", 4.36)),
    ("fable + deepseek workers", 3.27, ("deepseek", 2.60)),
    ("fable + sonnet workers",   11.54, None),
    ("sonnet solo (avg of 3)",   5.99, None),
    ("fable solo",               9.95, None),
    ("grok solo",                0.0, ("grok", 1.10)),
]

# Hero rows: (label, cells lost of 144 (r1+r2), score text, marker,
#             Claude USD (r1+r2), external (model, USD r1+r2) or None).
# Sums of the per-round ACC_*/COST_* data above.
HERO = [
    ("fable + grok workers",     0,    "144/144", "",  5.66,  ("grok", 7.10)),
    ("fable + deepseek workers", 1,    "143/144", "",  6.38,  ("deepseek", 4.31)),
    ("fable + sonnet workers",   3,    "141/144", "",  22.59, None),
    ("sonnet solo",              4.67, "139.3/144", "*", 11.48, None),
    ("fable solo",               5,    "139/144", "",  18.79, None),
    ("grok solo",                5,    "139/144", "",  0.0,   ("grok", 1.89)),
]
NOTE_HERO = ["* sonnet solo round 2 = average of 3 runs."]
NOTE_HERO_KO = ["* sonnet 단독 라운드 2 = 3회 실행 평균."]

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
def chart_accuracy(round_no, rows, denom_note, extra_note=(), lang="en", vmax=5):
    st = STRINGS[lang]
    head = 58
    W = 780
    H = head + 34 * len(rows) + 34 + (10 + 15 * len(extra_note) if extra_note else 0)
    s = svg_open(W, H, st["acc_aria"](round_no))
    s += text(20, 30, st["acc_title"](round_no, denom_note), 15, INK, weight="600")
    s += text(20, 46, st["acc_subtitle"], 10.5, MUTED)
    x0, xmax = 250, W - 130
    y = head + 14
    for row in rows:
        label, lost, scoretxt = row[:3]
        marker = row[3] if len(row) > 3 else ""
        lbl = label_for(label, lang)
        if marker:
            lbl += f'<tspan dy="-4" font-size="8" fill="{MUTED}">{marker}</tspan>'
        s += text(x0 - 10, y + 12, lbl, 12, INK, anchor="end")
        bw = (xmax - x0) * (lost / vmax)
        if lost == 0:
            s += f'<circle cx="{x0 + 3}" cy="{y + 8}" r="3.5" fill="{BAR_BLUE}"/>\n'
        else:
            s += (f'<rect x="{x0}" y="{y}" width="{bw:.1f}" height="16" rx="4" '
                  f'fill="{BAR_BLUE}"/>\n')
        lost_word = "손실" if lang == "ko" else "lost"
        s += text(x0 + max(bw, 7) + 8, y + 12, f"{lost:g} {lost_word} · {scoretxt}", 11, INK2)
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
def chart_tokens(round_no, tokens, in_vmax, out_vmax, lang="en"):
    st = STRINGS[lang]
    W = CHART_W
    row_h, gap = ROW_H, 10
    panel_top = CONTENT_TOP
    n = len(tokens)
    panel_h = n * (row_h + gap)
    H = panel_top + panel_h + 96
    s = svg_open(W, H, st["tokens_aria"](round_no))
    s += text(20, TITLE_Y, st["tokens_title"](round_no), TITLE_SIZE, INK, weight="600")
    s += text(20, CAP_Y1, st["tokens_caption1"], CAP_SIZE, MUTED)
    s += text(20, CAP_Y2, st["tokens_caption2"], CAP_SIZE, MUTED)
    order = {"fable": 0, "sonnet": 1, "haiku": 2, "deepseek": 3, "grok": 4}
    legend = ("fable", "sonnet", "haiku", "deepseek", "grok")
    panels = [(st["input_panel"], 0, in_vmax, BAR_X0, 360), (st["output_panel"], 1, out_vmax, 715, 200)]
    axis_y = panel_top + 14 + panel_h
    for ptitle, idx, vmax, x0, pw in panels:
        s += text(x0, panel_top + 2, ptitle, 12, INK, weight="600")
        y = panel_top + 14
        for label, models in tokens:
            ms = sorted(models, key=lambda t: order[t[0]])
            by = y + (row_h - BAR_H) / 2  # center the bar on the label's baseline
            if idx == 0:
                s += text(x0 - 10, y + row_h - 9, label_for(label, lang), 12, INK, anchor="end", weight="600")
            x = x0
            total = 0
            for m, tin, tout in ms:
                v = (tin, tout)[idx]
                total += v
                bw = pw * v / vmax
                if bw > 0.5:
                    s += (f'<rect x="{x:.1f}" y="{by:.1f}" width="{max(bw,1.5):.1f}" height="{BAR_H}" rx="3" '
                          f'fill="{MODEL_COLOR[m]}" stroke="{SURFACE}" stroke-width="2"/>\n')
                x += bw
            parts = [fmt((tin, tout)[idx]) for m, tin, tout in ms]
            lbl = " + ".join(parts) or "—"
            s += text(x0 + pw * min(total, vmax) / vmax + 8, y + row_h - 9, lbl, 10, INK2)
            y += row_h + gap
        s += f'<line x1="{x0}" y1="{y}" x2="{x0 + pw}" y2="{y}" stroke="{BASE}"/>\n'
        s += text(x0, y + AXIS_DY, "0", AXIS_SIZE, MUTED)
        s += text(x0 + pw, y + AXIS_DY, fmt(vmax), AXIS_SIZE, MUTED, anchor="end")
    # legend (bottom)
    lx = 220; ly = axis_y + 40
    for m in legend:
        s += f'<rect x="{lx}" y="{ly - 9}" width="10" height="10" rx="2" fill="{MODEL_COLOR[m]}"/>\n'
        s += text(lx + 14, ly, m, 11, INK2)
        lx += 14 + 8 * len(m) + 26
    return s + "</svg>\n"

# --------------------------------------------------------- chart 3: cost ----
def chart_cost(round_no, cost, lang="en"):
    st = STRINGS[lang]
    # Same system as the tokens chart: shared canvas / label column / bar-start /
    # row + bar heights, one row per config, cost sources drawn as stacked
    # segments (Claude $, then deepseek or grok $), colored to match a bottom
    # legend. All figures are API-equivalent.
    x0, xmax, W = BAR_X0, BAR_XMAX, CHART_W
    row_h, gap = ROW_H, 10
    vmax = 22.0
    n = len(cost)
    H = CONTENT_TOP + n * (row_h + gap) + 96
    s = svg_open(W, H, st["cost_aria"](round_no))
    s += text(20, TITLE_Y, st["cost_title"](round_no), TITLE_SIZE, INK, weight="600")
    s += text(20, CAP_Y1, st["cost_caption1"], CAP_SIZE, MUTED)
    s += text(20, CAP_Y2, st["cost_caption2"], CAP_SIZE, MUTED)

    y = CONTENT_TOP + 14
    for label, usd, ext in cost:
        by = y + (row_h - BAR_H) / 2
        base = y + row_h - 9
        s += text(x0 - 10, base, label_for(label, lang), 12, INK, anchor="end", weight="600")
        x = x0
        parts = []
        if usd > 0:  # Claude segment
            bw = (xmax - x0) * usd / vmax
            s += (f'<rect x="{x:.1f}" y="{by:.1f}" width="{bw:.1f}" height="{BAR_H}" rx="3" '
                  f'fill="{BAR_BLUE}" stroke="{SURFACE}" stroke-width="2"/>\n')
            x += bw
            parts.append(f"${usd:.2f}")
        if ext:  # external segment (deepseek or grok $) stacked on top of Claude
            model, val = ext
            bw = (xmax - x0) * val / vmax
            s += (f'<rect x="{x:.1f}" y="{by:.1f}" width="{max(bw, 3):.1f}" height="{BAR_H}" rx="3" '
                  f'fill="{MODEL_COLOR[model]}" stroke="{SURFACE}" stroke-width="2"/>\n')
            x += bw
            parts.append(f"${val:.2f}")
        s += text(x + 8, base, " + ".join(parts) or "$0", AXIS_SIZE, INK2)
        y += row_h + gap

    s += f'<line x1="{x0}" y1="{y}" x2="{xmax}" y2="{y}" stroke="{BASE}"/>\n'
    for v in (0, 5, 10, 15, 20):
        x = x0 + (xmax - x0) * v / vmax
        s += text(x, y + AXIS_DY, f"${v}", AXIS_SIZE, MUTED, anchor="middle")
    # legend (bottom) — same format as the tokens chart
    lx = BAR_X0; ly = y + 40
    for name, fill in ((st["claude_label"], BAR_BLUE), ("deepseek", MODEL_COLOR["deepseek"]),
                       ("grok", MODEL_COLOR["grok"])):
        s += f'<rect x="{lx}" y="{ly - 9}" width="10" height="10" rx="2" fill="{fill}"/>\n'
        s += text(lx + 14, ly, name, 11, INK2)
        lx += 14 + 8 * len(name) + 26
    return s + "</svg>\n"

# ---------------------------------------------------------- chart 4: hero ----
def chart_hero(lang="en"):
    """Both rounds on one canvas: cells lost (of 144) + API-equivalent cost."""
    st = STRINGS[lang]
    extra_note = NOTE_HERO if lang == "en" else NOTE_HERO_KO
    W = CHART_W
    row_h = 34
    rows_top = 92
    n = len(HERO)
    axis_y = rows_top + n * row_h
    H = axis_y + 44 + 15 * len(extra_note) + 24
    acc_x0, acc_w = BAR_X0, 290
    cost_x0, cost_w = 630, 330
    acc_vmax, cost_vmax = 6, 24.0
    s = svg_open(W, H, st["hero_aria"])
    s += text(20, TITLE_Y, st["hero_title"], TITLE_SIZE, INK, weight="600")
    s += text(20, CAP_Y1, st["hero_caption"], CAP_SIZE, MUTED)
    s += text(acc_x0, 78, st["hero_acc_panel"], 12, INK, weight="600")
    s += text(cost_x0, 78, st["hero_cost_panel"], 12, INK, weight="600")
    y = rows_top
    for label, lost, scoretxt, marker, usd, ext in HERO:
        base = y + 12
        by = y + 2
        lbl = label_for(label, lang)
        if marker:
            lbl += f'<tspan dy="-4" font-size="8" fill="{MUTED}">{marker}</tspan>'
        s += text(acc_x0 - 10, base, lbl, 12, INK, anchor="end", weight="600")
        # accuracy panel — same idiom as the per-round accuracy charts
        bw = acc_w * (lost / acc_vmax)
        if lost == 0:
            s += f'<circle cx="{acc_x0 + 3}" cy="{y + 8}" r="3.5" fill="{BAR_BLUE}"/>\n'
        else:
            s += (f'<rect x="{acc_x0}" y="{by}" width="{bw:.1f}" height="{BAR_H}" rx="4" '
                  f'fill="{BAR_BLUE}"/>\n')
        s += text(acc_x0 + max(bw, 7) + 8, base,
                  f'{lost:g} {st["hero_lost"]} · {scoretxt}', 11, INK2)
        # cost panel — same stacked idiom as the cost charts
        x = cost_x0
        parts = []
        if usd > 0:
            bw = cost_w * usd / cost_vmax
            s += (f'<rect x="{x:.1f}" y="{by}" width="{bw:.1f}" height="{BAR_H}" rx="3" '
                  f'fill="{BAR_BLUE}" stroke="{SURFACE}" stroke-width="2"/>\n')
            x += bw
            parts.append(f"${usd:.2f}")
        if ext:
            model, val = ext
            bw = cost_w * val / cost_vmax
            s += (f'<rect x="{x:.1f}" y="{by}" width="{max(bw, 3):.1f}" height="{BAR_H}" rx="3" '
                  f'fill="{MODEL_COLOR[model]}" stroke="{SURFACE}" stroke-width="2"/>\n')
            x += bw
            parts.append(f"${val:.2f}")
        s += text(x + 8, base, " + ".join(parts) or "$0", AXIS_SIZE, INK2)
        y += row_h
    # axes
    s += f'<line x1="{acc_x0}" y1="{axis_y}" x2="{acc_x0 + acc_w}" y2="{axis_y}" stroke="{BASE}"/>\n'
    for v in range(0, acc_vmax + 1, 2):
        x = acc_x0 + acc_w * v / acc_vmax
        s += text(x, axis_y + AXIS_DY, str(v), AXIS_SIZE, MUTED, anchor="middle")
    s += f'<line x1="{cost_x0}" y1="{axis_y}" x2="{cost_x0 + cost_w}" y2="{axis_y}" stroke="{BASE}"/>\n'
    for v in (0, 5, 10, 15, 20):
        x = cost_x0 + cost_w * v / cost_vmax
        s += text(x, axis_y + AXIS_DY, f"${v}", AXIS_SIZE, MUTED, anchor="middle")
    # cost legend + footnote
    lx, ly = cost_x0, axis_y + 38
    for name, fill in ((st["claude_label"], BAR_BLUE), ("grok", MODEL_COLOR["grok"]),
                       ("deepseek", MODEL_COLOR["deepseek"])):
        s += f'<rect x="{lx}" y="{ly - 9}" width="10" height="10" rx="2" fill="{fill}"/>\n'
        s += text(lx + 14, ly, name, 11, INK2)
        lx += 14 + 8 * len(name) + 26
    for i, line in enumerate(extra_note):
        s += text(20, axis_y + 38 + 15 * i, line, 10.5, MUTED)
    return s + "</svg>\n"

if __name__ == "__main__":
    charts = {
        "hero.svg":        lambda lang: chart_hero(lang=lang),
        "r1-accuracy.svg": lambda lang: chart_accuracy(1, ACC_R1,
            "of 72 fields" if lang == "en" else "72개 필드 기준",
            NOTE_R1 if lang == "en" else NOTE_R1_KO, lang=lang, vmax=5),
        "r2-accuracy.svg": lambda lang: chart_accuracy(2, ACC_R2,
            "of 72 fields" if lang == "en" else "72개 필드 기준",
            NOTE_R2 if lang == "en" else NOTE_R2_KO, lang=lang, vmax=8),
        "r1-tokens.svg":   lambda lang: chart_tokens(1, TOKENS_R1, 8_000_000, 200_000, lang=lang),
        "r2-tokens.svg":   lambda lang: chart_tokens(2, TOKENS_R2, 15_000_000, 280_000, lang=lang),
        "r1-cost.svg":     lambda lang: chart_cost(1, COST_R1, lang=lang),
        "r2-cost.svg":     lambda lang: chart_cost(2, COST_R2, lang=lang),
    }
    for name, fn in charts.items():
        p = os.path.join(OUT, name)
        with open(p, "w") as f:
            f.write(fn("en"))
        print("wrote", p)
        ko_name = name.replace(".svg", ".ko.svg")
        p_ko = os.path.join(OUT, ko_name)
        with open(p_ko, "w") as f:
            f.write(fn("ko"))
        print("wrote", p_ko)
