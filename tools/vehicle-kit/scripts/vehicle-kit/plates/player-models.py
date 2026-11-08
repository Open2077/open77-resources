"""Extend the plate spec's `models` to every vanilla player vehicle (metadata only).

Reads docs/generated/vehicle-components-player-<ver>.json (inventory/player_components.py)
and rewrites the generated tail of specs/plates.json `models`: one entry per
Vehicle.*_player* record the hand-written entries do not name, with its entity, every .app
its entity appearances use, its player entry (the appearance a spawned car wears) and no
curated trims. Hand-written entries (the dealer models and the Caliburn) are kept as they
are, first and in their order; generated entries carry `"generated": "player-models.py"` and
are replaced on every run, sorted by record. A record whose entity has no appearance at all
is left out with a line on the console, and so is a quest variant (Vehicle.q<digits>_*, out
of the extension by the owner's decision of 2026-11-07; the inventory already leaves them out).

The pack patches each .app as a whole (every definition with a plate, or a mount), so a new
entry only adds .app files the hand-written models do not already patch; the rest is
coverage reporting (player entry) and the lab command table.

    python -I scripts/vehicle-kit/plates/player-models.py [--inventory <json>] [--spec <json>]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
MARK = "player-models.py"
CLASS = re.compile(r"^v_(standard\d*|sport\d*|sportbike\d*|utility\d*|special)_")
QUEST = re.compile(r"^Vehicle\.q\d+_")


def label_of(record: str) -> str:
    key = record.split(".", 1)[1]
    key = CLASS.sub("", key)
    words = [w for w in key.split("_") if w and w != "player"]
    return " ".join(w if re.search(r"\d", w) and not w.isalpha() and w[0].isalpha() is False else w.capitalize() for w in words)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--inventory", default=os.path.join(REPO, "docs", "generated", "vehicle-components-player-2.50.json"))
    ap.add_argument("--spec", default=os.path.join(HERE, "specs", "plates.json"))
    a = ap.parse_args(argv)
    with open(a.inventory, encoding="utf-8") as fh:
        inv = json.load(fh)
    with open(a.spec, encoding="utf-8-sig") as fh:
        raw = fh.read()
    spec = json.loads(raw)
    hand = [m for m in spec["models"] if m.get("generated") != MARK]
    named = {m["record"] for m in hand}
    keys = {m["key"] for m in hand}
    generated = []
    for m in sorted(inv["models"], key=lambda x: x["record"]):
        if m["record"] in named:
            continue
        if QUEST.match(m["record"]):
            print(f"skip {m['record']}: quest variant, out of the extension")
            continue
        if not m["appearances"] or not m["apps"]:
            print(f"skip {m['record']}: no entity appearance")
            continue
        key = m["record"].split(".", 1)[1]
        if not key.isidentifier() or key in keys:
            raise SystemExit(f"{m['record']}: key {key!r} is not a free Lua identifier")
        keys.add(key)
        generated.append({
            "key": key, "label": label_of(m["record"]), "type": m["vehicleType"], "record": m["record"],
            "entity": m["entity"], "apps": sorted(m["apps"], key=str.lower), "playerEntry": m["playerAppearance"],
            "trims": [], "generated": MARK,
        })
    # Text splice, so the hand-written part of the file keeps its layout byte for byte: the
    # models array is one chunk per entry, each starting with `    { "key"`.
    head, sep, rest = raw.partition('  "models": [\n')
    body, tail_sep, tail = rest.rpartition("\n  ]\n")
    if not sep or not tail_sep:
        raise SystemExit(f"{a.spec}: models array not found where expected")
    chunks, current = [], []
    for line in body.split("\n"):
        if line.startswith('    { "key"') and current:
            chunks.append(current)
            current = []
        current.append(line)
    if current:
        chunks.append(current)
    kept = ["\n".join(c).rstrip().rstrip(",") for c in chunks if f'"generated": "{MARK}"' not in "\n".join(c)]
    if len(kept) != len(hand):
        raise SystemExit(f"{a.spec}: {len(kept)} hand-written chunks for {len(hand)} hand-written models")
    dump = lambda v: json.dumps(v, ensure_ascii=False)  # noqa: E731
    for g in generated:
        first = ", ".join(f"{dump(k)}: {dump(g[k])}" for k in ("key", "label", "type", "record", "entity", "apps", "playerEntry"))
        kept.append(f"    {{ {first},\n      \"trims\": [], \"generated\": {dump(MARK)} }}")
    text = head + sep + ",\n".join(kept) + tail_sep + tail
    check = json.loads(text)
    if [m["record"] for m in check["models"]] != [m["record"] for m in hand + generated]:
        raise SystemExit("spliced models do not round-trip")
    with open(a.spec, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(("﻿" if raw.startswith("﻿") else "") + text)
    apps_before = {x.lower() for m in hand for x in m["apps"]}
    new_apps = sorted({x for m in generated for x in m["apps"] if x.lower() not in apps_before}, key=str.lower)
    print(f"plates spec: {len(hand)} hand-written models, {len(generated)} generated, {len(new_apps)} new .app files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
