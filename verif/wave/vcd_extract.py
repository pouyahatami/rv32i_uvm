#!/usr/bin/env python3
"""
vcd_extract.py -- turn a raw VCD dump into a per-clock-edge CSV table.

Why this exists: reading a real waveform by eye in GTKWave is the gold
standard, but this project's teaching materials also want a plain-text,
diffable, greppable record of the same data -- something that can sit in
docs/waveforms/ and be read without a GUI. This does that by decoding the
VCD itself (no simulator API, no special build), snapshotting every
requested signal's current value at each rising edge of the clock, and
writing one CSV row per cycle.

Usage:
    python3 vcd_extract.py --vcd wave.vcd --clock clk \
        --signals PCF,InstrD,SelectAE,SelectBE,StallF,FlushD,FlushE,FlushM \
        --out trace.csv

Signal matching is by NAME, not by exact hierarchical path: a requested
name like "SelectAE" matches any VCD variable whose own declared name
(the last path component) equals it, and if more than one instance in the
design happens to share that name (the same net can appear under two
scopes if a module re-exports a same-named port), the shortest/least-
nested match is preferred and every match is listed on stderr so a
mismatch is visible rather than silent.
"""

import argparse
import csv
import re
import sys
from collections import defaultdict

VAR_RE = re.compile(
    r'\$var\s+(\w+)\s+(\d+)\s+(\S+)\s+([^\s\[]+)(\s*\[[^\]]*\])?\s*\$end')
SCOPE_RE = re.compile(r'\$scope\s+\w+\s+(\S+)\s+\$end')


def parse_header(f):
    """Read the VCD header, return (symbol -> full_path, symbol -> width)."""
    scope_stack = []
    paths = {}
    widths = {}
    for line in f:
        line = line.strip()
        m = SCOPE_RE.match(line)
        if m:
            scope_stack.append(m.group(1))
            continue
        if line.startswith('$upscope'):
            scope_stack.pop()
            continue
        m = VAR_RE.match(line)
        if m:
            _, width, symbol, name, _rng = m.groups()
            full = '.'.join(scope_stack + [name])
            paths.setdefault(symbol, []).append(full)
            widths[symbol] = int(width)
            continue
        if line.startswith('$enddefinitions'):
            return paths, widths
    sys.exit("vcd_extract: hit EOF while still in the header -- "
             "no $enddefinitions found")


def pick_targets(paths, widths, wanted):
    """For each requested short name, choose the best-matching symbol(s)."""
    by_name = defaultdict(list)
    for symbol, full_paths in paths.items():
        for full in full_paths:
            short = full.rsplit('.', 1)[-1]
            by_name[short].append((full, symbol))

    chosen = {}
    for name in wanted:
        candidates = by_name.get(name)
        if not candidates:
            print(f"  WARNING: no VCD signal named '{name}' found -- skipped",
                 file=sys.stderr)
            continue
        candidates.sort(key=lambda c: c[0].count('.'))
        full, symbol = candidates[0]
        chosen[name] = (symbol, widths[symbol])
        if len(candidates) > 1:
            others = ', '.join(c[0] for c in candidates[1:])
            print(f"  NOTE: '{name}' matched {len(candidates)} places, "
                 f"using shortest path '{full}' (also seen at: {others})",
                 file=sys.stderr)
        else:
            print(f"  '{name}' -> {full}", file=sys.stderr)
    return chosen


def fmt_value(raw, width):
    """4-state aware: keep X/Z visible rather than coercing them to 0."""
    raw = raw.strip()
    if not raw:
        return ''
    if 'x' in raw or 'X' in raw:
        return 'x' * max(1, len(raw))
    if 'z' in raw or 'Z' in raw:
        return 'z' * max(1, len(raw))
    try:
        val = int(raw, 2)
    except ValueError:
        return raw
    if width <= 1:
        return str(val)
    hexw = (width + 3) // 4
    return f"0x{val:0{hexw}x}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vcd', required=True)
    ap.add_argument('--clock', default='clk')
    ap.add_argument('--signals', required=True,
                    help='comma-separated short signal names')
    ap.add_argument('--out', required=True)
    ap.add_argument('--max-rows', type=int, default=0,
                    help='stop after N clock edges (0 = no limit)')
    args = ap.parse_args()

    wanted = [s.strip() for s in args.signals.split(',') if s.strip()]

    with open(args.vcd, 'r', errors='replace') as f:
        paths, widths = parse_header(f)
        print(f"parsed {len(paths)} VCD symbols", file=sys.stderr)

        targets = pick_targets(paths, widths, wanted)
        clk_matches = pick_targets(paths, widths, [args.clock])
        if args.clock not in clk_matches:
            sys.exit(f"vcd_extract: clock signal '{args.clock}' not found in VCD")
        clk_symbol, _ = clk_matches[args.clock]

        symbol_to_col = {sym: name for name, (sym, _w) in targets.items()}
        widths_by_col = {name: w for name, (_s, w) in targets.items()}

        current = {name: '' for name in targets}
        rows = []
        clk_prev = '0'
        time_now = 0

        for line in f:
            line = line.strip()
            if not line:
                continue
            if line[0] == '#':
                time_now = int(line[1:])
                continue
            if line[0] in '01xXzZ':
                val, sym = line[0], line[1:]
                if sym == clk_symbol:
                    if clk_prev != '1' and val == '1':
                        rows.append((time_now, dict(current)))
                    clk_prev = val
                elif sym in symbol_to_col:
                    current[symbol_to_col[sym]] = val
                continue
            if line[0] == 'b':
                try:
                    val, sym = line[1:].split(' ', 1)
                except ValueError:
                    continue
                if sym in symbol_to_col:
                    current[symbol_to_col[sym]] = val
                continue
            # 'r<real> <sym>' and bare '$dumpvars'/'$end' lines: not used here

    if args.max_rows:
        rows = rows[:args.max_rows]

    cols = ['cycle', 'time_ns'] + list(targets.keys())
    with open(args.out, 'w', newline='') as out:
        w = csv.writer(out)
        w.writerow(cols)
        for i, (t, snapshot) in enumerate(rows):
            row = [i, t] + [fmt_value(snapshot.get(name, ''), widths_by_col[name])
                            for name in targets]
            w.writerow(row)

    print(f"{args.out}: {len(rows)} clock edges x {len(targets)} signals",
         file=sys.stderr)


if __name__ == '__main__':
    main()
