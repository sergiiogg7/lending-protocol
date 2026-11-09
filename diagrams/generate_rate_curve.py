"""Draws diagrams/interest-rate-curve.svg from the constants of src/LendingProtocol.sol.

Run from the repository root:  python diagrams/generate_rate_curve.py

The curve is read from the contract (OPTIMAL_UTILIZATION, BASE_BORROW_RATE, RATE_SLOPE_1, RATE_SLOPE_2) so that the
picture cannot drift from the code. The SVG adapts to GitHub's light and dark themes with prefers-color-scheme.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "src" / "LendingProtocol.sol").read_text(encoding="utf-8")


def constant(name: str) -> float:
    match = re.search(rf"constant {name}\s*=\s*([0-9.]+)(e18)?", SOURCE)
    if not match:
        raise SystemExit(f"constant {name} not found in src/LendingProtocol.sol")
    value = float(match.group(1))
    return value if match.group(2) else value / 1e18  # 0 is written without the e18 suffix


OPT = constant("OPTIMAL_UTILIZATION")
BASE = constant("BASE_BORROW_RATE")
SLOPE1 = constant("RATE_SLOPE_1")
SLOPE2 = constant("RATE_SLOPE_2")


def borrow_rate(u: float) -> float:
    if u <= OPT:
        return BASE + SLOPE1 * u / OPT
    return BASE + SLOPE1 + SLOPE2 * (u - OPT) / (1 - OPT)


def supply_rate(u: float) -> float:
    return borrow_rate(u) * u


W, H = 760, 430
L, R, T, B = 66, 28, 64, 58
PW, PH = W - L - R, H - T - B
Y_MAX = 0.8


def x(u: float) -> float:
    return L + u * PW


def y(r: float) -> float:
    return T + PH * (1 - r / Y_MAX)


def path(fn) -> str:
    return " ".join(f"{'M' if i == 0 else 'L'}{x(i / 100):.1f} {y(fn(i / 100)):.1f}" for i in range(101))


def fmt(v: float) -> str:
    """Rate as a percentage with at most two decimals and no trailing zeros: 0.0320 -> '3.2 %'."""
    return f"{v * 100:.2f}".rstrip("0").rstrip(".") + " %"


parts = []
add = parts.append
add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
    f'aria-labelledby="t d">')
add("<title id=\"t\">Interest rate by utilization</title>")
add(f"<desc id=\"d\">Borrow rate rises slowly up to {OPT * 100:.0f} % utilization ({SLOPE1 * 100:.0f} %) and steeply "
    f"after it, reaching {borrow_rate(1) * 100:.0f} % at 100 %. The supply rate is the borrow rate times the "
    f"utilization and meets it at 100 %.</desc>")
add("""<style>
  text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
  .ink { fill: #1f2328; } .mut { fill: #59636e; }
  .grid { stroke: #d1d9e0; stroke-width: 1; } .axis { stroke: #8c959f; stroke-width: 1; }
  .kink { stroke: #8c959f; stroke-width: 1; stroke-dasharray: 5 4; }
  .b { stroke: #2a78d6; } .s { stroke: #eb6834; } .bf { fill: #2a78d6; } .sf { fill: #eb6834; }
  .line { fill: none; stroke-width: 2.5; stroke-linecap: round; stroke-linejoin: round; }
  @media (prefers-color-scheme: dark) {
    .ink { fill: #e6edf3; } .mut { fill: #9198a1; }
    .grid { stroke: #30363d; } .axis { stroke: #6e7681; } .kink { stroke: #6e7681; }
    .b { stroke: #3987e5; } .s { stroke: #d95926; } .bf { fill: #3987e5; } .sf { fill: #d95926; }
  }
</style>""")

add(f'<text class="ink" x="{L}" y="26" font-size="16" font-weight="600">Interest rate by utilization</text>')
add(f'<text class="mut" x="{L}" y="46" font-size="12.5">annual rates, as computed by getBorrowRate and getSupplyRate</text>')
# legend (top right)
lx = W - R - 250
add(f'<line class="line b" x1="{lx}" x2="{lx + 22}" y1="20" y2="20"/><text class="ink" x="{lx + 30}" y="24" font-size="12.5">Borrowers pay (borrow)</text>')
add(f'<line class="line s" x1="{lx}" x2="{lx + 22}" y1="40" y2="40"/><text class="ink" x="{lx + 30}" y="44" font-size="12.5">Depositors earn (supply = borrow × U)</text>')

for r in (0, 0.2, 0.4, 0.6, 0.8):
    add(f'<line class="grid" x1="{L}" x2="{W - R}" y1="{y(r):.1f}" y2="{y(r):.1f}"/>'
        f'<text class="mut" x="{L - 10}" y="{y(r) + 4:.1f}" font-size="12" text-anchor="end">{r * 100:.0f} %</text>')
for i in range(0, 11):
    u = i / 10
    anchor = "start" if i == 0 else "end" if i == 10 else "middle"
    add(f'<text class="mut" x="{x(u):.1f}" y="{T + PH + 18}" font-size="12" text-anchor="{anchor}">{u * 100:.0f} %</text>')
add(f'<line class="axis" x1="{L}" x2="{W - R}" y1="{T + PH}" y2="{T + PH}"/>')
add(f'<text class="ink" x="{L + PW / 2:.1f}" y="{H - 10}" font-size="13" text-anchor="middle">Utilization = borrowed ÷ supplied</text>')

# kink
add(f'<line class="kink" x1="{x(OPT):.1f}" x2="{x(OPT):.1f}" y1="{T}" y2="{T + PH}"/>')
add(f'<text class="mut" x="{x(OPT) - 8:.1f}" y="{T + 14}" font-size="12" text-anchor="end">gentle slope up to the {OPT * 100:.0f} % kink</text>')
add(f'<text class="mut" x="{x(OPT) + 8:.1f}" y="{T + 14}" font-size="12">steep after it</text>')

add(f'<path class="line b" d="{path(borrow_rate)}"/>')
add(f'<path class="line s" d="{path(supply_rate)}"/>')

# points on the curves: the numbers used in the tests
EXAMPLES = (0.4, OPT, 0.9, 1.0)
for u in EXAMPLES:
    add(f'<circle class="bf" cx="{x(u):.1f}" cy="{y(borrow_rate(u)):.1f}" r="4.5"/>')
    if u < 1:
        add(f'<circle class="sf" cx="{x(u):.1f}" cy="{y(supply_rate(u)):.1f}" r="4.5"/>')

bx, by = L + 18, T + 26
add(f'<text class="ink" x="{bx}" y="{by}" font-size="13" font-weight="600">Marked points</text>')
add(f'<text class="mut" x="{bx + 118}" y="{by}" font-size="12">borrow pays · supply earns</text>')
for i, u in enumerate(EXAMPLES):
    row = by + 22 * (i + 1)
    note = "  (kink)" if u == OPT else ""
    add(f'<text class="ink" x="{bx}" y="{row}" font-size="13">U = {u * 100:.0f} %{note}</text>')
    add(f'<text class="ink" x="{bx + 118}" y="{row}" font-size="13">{fmt(borrow_rate(u))} · {fmt(supply_rate(u))}</text>')
add("</svg>")

out = ROOT / "diagrams" / "interest-rate-curve.svg"
out.write_text("\n".join(parts) + "\n", encoding="utf-8")
print(f"wrote {out.relative_to(ROOT)} from OPT={OPT} BASE={BASE} SLOPE1={SLOPE1} SLOPE2={SLOPE2}")
