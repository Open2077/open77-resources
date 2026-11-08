"""Per-appearance survey of the factory parts a body-kit part replaces (offline).

A kit part hides the stock component it replaces (a factory wing under a kit wing, a roof
rack under a basket). The client skips a name the car's current appearance lacks, so a
record's hide list names every appearance's variant: a trim often carries the same part
under another component name (the rim lesson: `wheel_01_*_a` on the default appearance,
`wheel_*_01` on the Suburban trim, so the stock rims stayed visible under the kit's).

For every car body of the component inventory (dealer_components.py or
player_body_components.py), this reads the .app definition of EVERY entity appearance from the
serialized JSON in the inventory scratch folder, sorts the component names by the body-kit
group they clash with (RULES), and writes specs/lightrp-bodykit-hides.json:

    cars.<key>.hide.<group>          the names to hide (shadow twins included), the union
                                     over every appearance of the entity;
    cars.<key>.found.<group>.<name>  how many appearances carry the name, and whether the
                                     record's own appearance does;
    cars.<key>.kept                  matched names deliberately left visible, with why.

body_fit.py applies `hide` to the cars beyond the first 14 and only compares it for the
first 14, whose hide rows stay in its HIDE table.

Usage (repository root):
    python -I scripts/vehicle-kit/inventory/body_hides.py --inventory <player inventory json> \\
        --scratch <inventory scratch>/extract --cache <inventory scratch> [--out specs/lightrp-bodykit-hides.json]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cr2w_json as cj  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
OUT = os.path.join(REPO, "scripts", "vehicle-kit", "specs", "lightrp-bodykit-hides.json")

# Component names (lowercase, `_shadow` stripped) a kit group replaces.
RULES = OrderedDict([
    ("spoiler", r"^(wing_[a-c](_\d+)?|wing_\d+|trunk_spoiler(_\d+)?|spoiler(_\w+)?|deathrace_spoiler(_\d+)?|"
                r".*__ext\d+_spoiler_\w+|.*_spoiler_(gt|rear|b)(_\d+)?)$"),
    ("roofrack", r"^(roof_rack(_\d+)?|v_common_suitcase_\d+|junk_solar(_\d+)?|body_rack(_\d+)?|roof_basket\w*|roof_cargo\w*)$"),
    ("lip", r"^(bumper_lip_f(_\d+)?|lip_f(_\d+)?|front_lip\w*|splitter(_\d+)?)$"),
    ("skirt", r"^(jammer_skirts_\d+|\w*side_skirts?(_\d+)?)$"),
    ("hood", r"^(\w*_hood_scoop(_\d+)?)$"),
])
# The mesh every appearance puts under a matched name must look like that group's part too:
# a name is per appearance, and one trim's `spoiler_01` can carry a trunk panel (the Shion
# nomad's missile build). Hiding such a name would open a hole, so it is kept and reported.
MESH_RULES = {
    "spoiler": r"spoiler|wing",
    "roofrack": r"rack|suitcase|solar|basket|cargo",
    "lip": r"lip|splitter",
    "skirt": r"skirt",
    "hood": r"scoop",
}
# Matched names left visible on purpose, per car key: (name, reason).
HOZUKI_LIP = ("the player trim's lip spoiler is moulded on the hatch (bound to body_01), under where a kit wing "
              "stands; left visible until seen in game")
KEEP = {
    "hozuki": {"spoiler_player_01": HOZUKI_LIP},
    "hozuki_gt": {"spoiler_player_01": HOZUKI_LIP},
}


def group_of(name: str) -> str | None:
    n = name.lower()
    if n.endswith("_shadow"):
        n = n[: -len("_shadow")]
    for group, rx in RULES.items():
        if re.match(rx, n):
            return group
    return None


def appearance_components(doc: cj.Doc, appearance_name: str) -> list[dict] | None:
    defs = [doc.deref(x) for x in doc.root.get("appearances") or []]
    d = next((x for x in defs if x and cj.val(x.get("name")) == appearance_name), None)
    if d is None:
        return None
    return cj.component_list(doc, d)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inventory", required=True, help="dealer_components.py or player_body_components.py JSON")
    ap.add_argument("--cache", required=True, help="inventory scratch dir holding archive-lists/")
    ap.add_argument("--scratch", required=True, help="inventory scratch dir holding json/ (serialized .app files)")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--game", default=os.environ.get("OP77_GAME_DIR") or "")
    ap.add_argument("--cp77tools", default=os.path.expanduser(r"~\.dotnet\tools\cp77tools.exe"))
    a = ap.parse_args(argv)
    inv = json.load(open(a.inventory, encoding="utf-8"))
    index = cj.archive_index(os.path.join(a.cache, "archive-lists"))
    docs: dict[str, cj.Doc | None] = {}
    cars = OrderedDict()
    for m in inv["models"]:
        if m["tweakdb"]["vehicleType"] == "Bike":
            continue
        apps = sorted({x["app"] for x in m.get("appearances", []) if x.get("app")})
        info = cj.extract(a.game, a.cp77tools, a.scratch, apps, index)
        found: dict[str, dict[str, dict]] = {}
        unread = []
        for x in m.get("appearances", []):
            p = (x.get("app") or "").lower()
            if p not in docs:
                j = (info.get(p) or {}).get("json")
                docs[p] = cj.Doc(j) if j and os.path.exists(j) else None
            doc = docs[p]
            comps = appearance_components(doc, x["appearanceName"]) if doc else None
            if comps is None:
                unread.append(x["name"])
                continue
            names = {}
            for c in comps:
                mesh = cj.val(c.get("mesh")) if c.get("mesh") else ""
                names.setdefault(cj.val(c.get("name")) or "", set()).add((mesh or "").lower())
            for name, meshes in names.items():
                g = group_of(name)
                if not g:
                    continue
                row = found.setdefault(g, {}).setdefault(name, {"appearances": 0, "player": False})
                row["appearances"] += 1
                if x["name"] == m.get("playerAppearance"):
                    row["player"] = True
                odd = sorted(ms.rsplit("\\", 1)[-1] for ms in meshes
                             if ms and not re.search(MESH_RULES[g], ms.rsplit("\\", 1)[-1]))
                if odd:
                    row.setdefault("otherMeshes", [])
                    row["otherMeshes"] = sorted(set(row["otherMeshes"]) | set(odd))
        keep = KEEP.get(m["key"], {})
        hide, kept = {}, {}
        for g, names in found.items():
            for name in sorted(names):
                base = name[:-len("_shadow")] if name.endswith("_shadow") else name
                if base in keep:
                    kept[name] = keep[base]
                    continue
                other = found[g][name].get("otherMeshes") or found[g].get(base, {}).get("otherMeshes")
                if other:
                    kept[name] = f"ambiguous name: some appearances put {', '.join(other)} under it, not a {g} part"
                    continue
                hide.setdefault(g, []).append(name)
        cars[m["key"]] = OrderedDict([
            ("record", m["record"]),
            ("appearances", len(m.get("appearances", []))),
            ("hide", {g: hide[g] for g in RULES if g in hide}),
            ("found", {g: {n: found[g][n] for n in sorted(found[g])} for g in RULES if g in found}),
        ])
        if kept:
            cars[m["key"]]["kept"] = kept
        if unread:
            cars[m["key"]]["unread"] = unread
        print(f"{m['key']:24} {len(m.get('appearances', [])):3} appearances  "
              + "  ".join(f"{g}: {', '.join(v)}" for g, v in cars[m['key']]['hide'].items())
              + (f"  (unread: {len(unread)})" if unread else ""), flush=True)
    out = OrderedDict([
        ("schema", "open77.vehicle-kit.body-hides/1"),
        ("generatedBy", "scripts/vehicle-kit/inventory/body_hides.py"),
        ("rules", dict(RULES)),
        ("note", "hide: the union over every entity appearance (a name an appearance lacks is skipped by the "
                 "client); found: appearances carrying each name, player = the record's own appearance"),
        ("cars", cars),
    ])
    with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(out, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(f"wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
