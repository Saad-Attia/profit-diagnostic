"""Chart helpers for the Profit Diagnostic: one consistent, minimal style for every figure."""
from __future__ import annotations

import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import numpy as np
import pandas as pd

# Palette (validated reference palette): diverging blue/red for gains/losses,
# neutral ink for totals, categorical slots in fixed order.
INK, INK_2, MUTED, GRID, AXIS, SURFACE = "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7", "#fcfcfb"
GAIN, LOSS, TOTAL = "#2a78d6", "#e34948", "#52514e"
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]

plt.rcParams.update({
    "font.family": ["Inter", "DejaVu Sans"], "font.size": 9.5,
    "axes.edgecolor": AXIS, "axes.labelcolor": INK_2, "axes.titlecolor": INK,
    "axes.titlesize": 11.5, "axes.titleweight": "bold", "axes.titlelocation": "left", "axes.titlepad": 12,
    "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True, "axes.grid.axis": "y",
    "grid.color": GRID, "grid.linewidth": 0.8, "xtick.color": MUTED, "ytick.color": MUTED,
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.axisbelow": True, "text.parse_math": False,
    "figure.dpi": 110, "savefig.dpi": 200, "savefig.bbox": "tight",
})


def money(x: float, decimals: int = 2) -> str:
    """$1.23M / $456K / −$7K style label."""
    sign = "−" if x < 0 else ""
    x = abs(x)
    if x >= 1e6:
        return f"{sign}${x/1e6:.{decimals}f}M"
    if x >= 1e3:
        return f"{sign}${x/1e3:.0f}K"
    return f"{sign}${x:,.0f}"


def _money_axis(ax, axis="y"):
    fmt = mtick.FuncFormatter(lambda v, _: money(v, 1) if v else "0")
    (ax.yaxis if axis == "y" else ax.xaxis).set_major_formatter(fmt)


def bridge(series: pd.Series, title: str, subtitle: str | None = None, ax=None, fmt=money):
    """Waterfall: first and last items are totals; the rest are signed steps."""
    ax = ax or plt.subplots(figsize=(9, 4.6))[1]
    labels, vals = list(series.index), series.values.astype(float)
    running, bottoms, heights, colors = 0.0, [], [], []
    for i, v in enumerate(vals):
        if i == 0 or i == len(vals) - 1:
            bottoms.append(0); heights.append(v); colors.append(TOTAL); running = v
        else:
            bottoms.append(running if v >= 0 else running + v); heights.append(abs(v))
            colors.append(GAIN if v >= 0 else LOSS); running += v
    x = np.arange(len(vals))
    ax.bar(x, heights, bottom=bottoms, color=colors, width=0.62, edgecolor=SURFACE, linewidth=2)
    for i, v in enumerate(vals):
        top = bottoms[i] + heights[i]
        y = top if v >= 0 or i in (0, len(vals) - 1) else bottoms[i]
        va = "bottom" if (v >= 0) else "top"
        ax.annotate(fmt(v) if i in (0, len(vals) - 1) else ("+" if v >= 0 else "") + fmt(v),
                    (i, y), xytext=(0, 3 if va == "bottom" else -3), textcoords="offset points",
                    ha="center", va=va, fontsize=8.5, color=INK)
    ax.axhline(0, color=AXIS, linewidth=1)
    ax.set_xticks(x, [l.replace(" products", "\nproducts").replace(" (", "\n(") for l in labels])
    ax.tick_params(axis="x", colors=INK_2, length=0)
    _money_axis(ax)
    ax.set_title(title, pad=24 if subtitle else 12)
    if subtitle:
        ax.text(0, 1.02, subtitle, transform=ax.transAxes, fontsize=9, color=INK_2, va="bottom")
    lo = min(min(bottoms), 0); hi = max(b + h for b, h in zip(bottoms, heights))
    pad = (hi - lo) * 0.12
    ax.set_ylim(lo - pad, hi + pad)
    return ax


def hbar(values: pd.Series, title: str, fmt=money, ax=None, sort=True, color_by_sign=True):
    """Horizontal bars, signed colors, direct value labels."""
    s = values.sort_values() if sort else values
    ax = ax or plt.subplots(figsize=(9, max(2.4, 0.38 * len(s) + 1)))[1]
    colors = [GAIN if v >= 0 else LOSS for v in s] if color_by_sign else GAIN
    ax.barh(s.index, s.values, color=colors, height=0.62, edgecolor=SURFACE, linewidth=2)
    ax.grid(axis="y", visible=False); ax.grid(axis="x", visible=True)
    ax.axvline(0, color=AXIS, linewidth=1)
    span = s.abs().max()
    for i, v in enumerate(s.values):
        ax.text(v + (span * 0.01 if v >= 0 else -span * 0.01), i, fmt(v), va="center",
                ha="left" if v >= 0 else "right", fontsize=8.5, color=INK)
    ax.set_xlim(min(s.min(), 0) - span * 0.18, max(s.max(), 0) + span * 0.18)
    _money_axis(ax, "x") if fmt is money else None
    ax.tick_params(axis="y", colors=INK_2, length=0)
    ax.set_title(title)
    return ax
