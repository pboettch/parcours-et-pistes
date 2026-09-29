#!/usr/bin/env python3
"""Markdown line-coverage summary per package from an LCOV file.

Usage: coverage_summary.py lcov.info [--min PERCENT]
Exits with status 1 if total coverage is below --min.
"""
import argparse
import collections
import re

ap = argparse.ArgumentParser()
ap.add_argument('lcov')
ap.add_argument('--min', type=float, default=0.0)
args = ap.parse_args()

per_pkg = collections.defaultdict(lambda: [0, 0])  # package -> [hit, total]
files = []  # (path, hit, total)
path = None
hit = total = 0
for line in open(args.lcov):
    line = line.strip()
    if line.startswith('SF:'):
        path, hit, total = line[3:], 0, 0
    elif line.startswith('DA:'):
        total += 1
        if int(line[3:].split(',')[1]) > 0:
            hit += 1
    elif line == 'end_of_record' and path:
        m = re.match(r'(?:.*/)?packages/([^/]+)/', path)
        pkg = m.group(1) if m else '(other)'
        per_pkg[pkg][0] += hit
        per_pkg[pkg][1] += total
        files.append((path, hit, total))
        path = None

pct = lambda h, t: 100.0 * h / t if t else 100.0
all_hit = sum(h for h, _ in per_pkg.values())
all_total = sum(t for _, t in per_pkg.values())
total_pct = pct(all_hit, all_total)

print('## Line coverage\n')
print('| Package | Lines | Coverage |')
print('|---|---:|---:|')
for pkg in sorted(per_pkg):
    h, t = per_pkg[pkg]
    print(f'| `{pkg}` | {h} / {t} | {pct(h, t):.1f} % |')
print(f'| **Total** | **{all_hit} / {all_total}** | **{total_pct:.1f} %** |')

low = sorted((pct(h, t), p) for p, h, t in files if t and pct(h, t) < 80)
if low:
    print('\n<details><summary>Files below 80 %</summary>\n')
    for c, p in low:
        print(f'- `{p}`: {c:.1f} %')
    print('\n</details>')

if total_pct < args.min:
    print(f'\n**Coverage {total_pct:.1f} % is below the required {args.min:.1f} %.**')
    raise SystemExit(1)
