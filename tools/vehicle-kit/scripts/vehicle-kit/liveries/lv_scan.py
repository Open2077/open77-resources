"""No-vanilla-bytes scan of the livery pack, against a baseline of known shared blocks.

    python lv_scan.py plan  <work> <scan-plan.json>       every game file the build read: the
                                                          cached extractions (<work>/game/raw) and
                                                          the stock panel meshes (composite-inputs.json)
    python lv_scan.py check <scan-plan.json> <baseline.json>

plates.cjs scan (run by build-liveries.ps1 between the two) reports every 64-byte aligned block
a cooked file shares with a game file the build read. `check` explains each one, as
st_ocook.py scan-names does for the sticker pack: inside the CR2W names table of its game
file, or inside a verified vertex format descriptor. The livery pack also shares blocks that
are neither: the 224 of revision 8c50ead76bc6 (122 in game mlsetups, 94 in meshes, 5 in
material instances, 3 in textures), reviewed by hand (docs/liveries.md, "No vanilla bytes").
They are the baseline (specs/no-vanilla-bytes-baseline.json), keyed by the game side of the
hit (`<file name>@<offset>`), which does not depend on the revision; the cooked side does
(which of our files hits first). A shared block outside the names tables, the vertex formats
and the baseline fails the build.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'stickers'))
from lv_common import read_json  # noqa: E402
from st_ocook import layout_regions, name_region  # noqa: E402  (read-only reuse)


def fail(msg):
    raise SystemExit(f'lv_scan: {msg}')


def plan(work, out):
    work = Path(work)
    files = set()
    for root, _, names in os.walk(work / 'game' / 'raw'):
        files.update(str(Path(root) / n) for n in names)
    inputs = read_json(work / 'composite-inputs.json')
    files.update(str(p) for p in inputs['meshes'].values() if Path(p).is_file())
    if not files:
        fail(f'no game file under {work}')
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({'vanillaFiles': sorted(files), 'reportDir': str(out.parent)}, indent=1) + '\n',
                   encoding='utf-8', newline='\n')
    print(f'LV_SCAN_PLAN_OK vanilla={len(files)}')


def classify(plan_doc, scan):
    """(kinds, unexplained): the binary hits inside a names table or a vertex format
    descriptor of every game file of that name are counted, the others returned."""
    by_name = {}
    for v in plan_doc['vanillaFiles']:
        by_name.setdefault(Path(v).name, []).append(v)
    regions, kinds, rest = {}, {'names': 0, 'format': 0}, []
    window = scan['window']
    for hit in scan['binary']:
        name, off = hit.split(' = ')[0].rsplit('@', 1)
        off = int(off)
        paths = by_name.get(name) or fail(f'{name} is not a file the build read')
        for p in paths:
            if p not in regions:
                data = Path(p).read_bytes()
                regions[p] = (name_region(data), layout_regions(data))
        if all(regions[p][0] and regions[p][0][0] <= off and off + window <= regions[p][0][1] for p in paths):
            kinds['names'] += 1
        elif all(any(a <= off and off + window <= b for a, b in regions[p][1]) for p in paths):
            kinds['format'] += 1
        else:
            rest.append(hit)
    return kinds, rest


def check(plan_path, baseline_path):
    plan_doc = read_json(plan_path)
    scan = read_json(Path(plan_doc['reportDir']) / 'scan.json')
    baseline = read_json(baseline_path)
    if baseline.get('window') != scan['window']:
        fail(f'baseline window {baseline.get("window")} != scan window {scan["window"]}')
    known = set(baseline['blocks'])
    kinds, rest = classify(plan_doc, scan)
    new = [h for h in rest if h.split(' = ')[0] not in known]
    if new:
        fail(f'{len(new)} shared 64-byte blocks of game files are neither a names table, a vertex format '
             f'descriptor nor one of the {len(known)} known blocks of {baseline["revision"]}: {"; ".join(new[:8])}')
    seen = {h.split(' = ')[0] for h in rest}
    print(f'LV_SCAN_OK ours={len(scan["ourFiles"])} vanilla={scan["vanillaFiles"]} new shared blocks=0, '
          f'known blocks={len(rest)} of {len(known)} ({baseline["revision"]}, {len(known - seen)} no longer shared), '
          f'names-table blocks={kinds["names"]}, vertex-format blocks={kinds["format"]}')


if __name__ == '__main__':
    commands = {'plan': plan, 'check': check}
    if len(sys.argv) != 4 or sys.argv[1] not in commands:
        fail('usage: lv_scan.py plan <work> <scan-plan.json>  |  lv_scan.py check <scan-plan.json> <baseline.json>')
    commands[sys.argv[1]](sys.argv[2], sys.argv[3])
