#!/usr/bin/env python3
"""Draws the article's disk-runway chart from DiskRunway's own trace.

    RUNWAY_TRACE_OUT=$PWD/docs/runway-trace.json swift test --filter testExportRunwayTraceWhenAsked
    python3 docs/make_runway_chart.py docs/runway-trace.json docs/runway.svg

The SVG is what the article's PNG was rendered from (headless Chromium, 2x).
Every number on the chart comes from the JSON; nothing is recomputed here.
JSONEncoder leaves out nil values, so absent keys mean "never happened".
"""
import json
import sys

COLORS = {"none": "#F87171", "bigger-disk": "#FB923C", "quota": "#A78BFA", "envelope": "#34D399"}
W, H = 800, 500
L, R, T, B = 70, 30, 104, 92
PW, PH = W - L - R, H - T - B
XMAX, YMAX = 12, 1100


def x(h):
    return L + h / XMAX * PW


def y(gb):
    return T + (1 - gb / YMAX) * PH


def outcome(s):
    if s.get("floorBreachHour") is not None:
        return f"floor at {s['floorBreachHour']:.1f} h"
    if s.get("firstFailedHour") is not None:
        return f"agents stop from {s['firstFailedHour']:.1f} h"
    return f"bottoms out at {s['minimumFreeGB']:.1f} GB"


def main(src, dst):
    series = json.load(open(src))
    parts = []
    for g in range(0, 1101, 100):
        parts.append(f'<line x1="{L}" x2="{W - R}" y1="{y(g):.1f}" y2="{y(g):.1f}" stroke="#1E2A44"/>')
        if g % 200 == 0:
            parts.append(f'<text x="{L - 10}" y="{y(g) + 4:.1f}" text-anchor="end" class="tick">{g}</text>')
    for h in range(0, 13, 2):
        parts.append(f'<text x="{x(h):.1f}" y="{H - B + 20}" text-anchor="middle" class="tick">{h}</text>')
    parts.append(f'<line x1="{L}" x2="{W - R}" y1="{y(50):.1f}" y2="{y(50):.1f}" stroke="#F87171" stroke-dasharray="5 4" stroke-width="1.4"/>')
    parts.append(f'<text x="{L + 6}" y="{y(50) - 7:.1f}" class="ann" fill="#F87171">50 GB floor for macOS</text>')

    for i, s in enumerate(series):
        color = COLORS.get(s["id"], "#93C5FD")
        pts = [(h, g) for h, g in zip(s["hours"], s["freeGB"]) if h <= XMAX]
        d = "M" + " L".join(f"{x(h):.1f},{y(g):.1f}" for h, g in pts)
        parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2.4" stroke-linejoin="round"/>')
        lx, ly = L - 40 + (i % 2) * 372, 60 + (i // 2) * 22
        parts.append(f'<line x1="{lx}" x2="{lx + 22}" y1="{ly - 4}" y2="{ly - 4}" stroke="{color}" stroke-width="3"/>')
        parts.append(f'<text x="{lx + 30}" y="{ly}" class="leg">{s["title"]}: {outcome(s)}</text>')
        if s.get("floorBreachHour") is not None:
            parts.append(f'<circle cx="{x(s["floorBreachHour"]):.1f}" cy="{y(50):.1f}" r="4.5" fill="{color}"/>')
        elif s.get("firstFailedHour") is not None:
            # Mark where the line first reaches its minimum: every agent is at its cap.
            g = s["minimumFreeGB"]
            h = next(hh for hh, gg in zip(s["hours"], s["freeGB"]) if gg == g)
            parts.append(f'<circle cx="{x(h):.1f}" cy="{y(g):.1f}" r="4.5" fill="{color}"/>')
            parts.append(f'<text x="{x(h) + 10:.1f}" y="{y(g) - 10:.1f}" class="ann" fill="{color}">Mac bottoms out at {g:.0f} GB free</text>')

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<style>
 .title {{ font: 800 21px Inter, sans-serif; fill:#E8EEF9; }}
 .sub {{ font: 500 12.5px Inter, sans-serif; fill:#8EA0BF; }}
 .tick {{ font: 500 12px Inter, sans-serif; fill:#8EA0BF; }}
 .leg {{ font: 600 12px Inter, sans-serif; fill:#D6E0F2; }}
 .ann {{ font: 700 12px Inter, sans-serif; }}
 .axis {{ font: 600 12px Inter, sans-serif; fill:#8EA0BF; }}
</style>
<rect width="{W}" height="{H}" fill="#0B1220"/>
<text x="{L - 40}" y="30" class="title">Free disk space with four agents leaking 5.7 GB per QA run</text>
{"".join(parts)}
<text x="{L - 46}" y="{T + PH / 2:.0f}" class="axis" transform="rotate(-90 {L - 46} {T + PH / 2:.0f})" text-anchor="middle">Free GB</text>
<text x="{L + PW / 2:.0f}" y="{H - B + 40}" class="axis" text-anchor="middle">Hours</text>
<text x="{L - 40}" y="{H - 26}" class="sub">Constructed scenario: 550 GB free (Fatbobman kept 500-600 GB), each agent runs QA every 15 minutes,</text>
<text x="{L - 40}" y="{H - 10}" class="sub">teardown after 4 runs, 50 GB kept for macOS. Drawn from DiskRunway's trace in the AgentEnvelope repo.</text>
</svg>'''
    open(dst, "w").write(svg)
    print(f"wrote {dst}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: make_runway_chart.py runway-trace.json runway.svg")
    main(sys.argv[1], sys.argv[2])
