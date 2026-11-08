"""Offline inventory of the visual-customization data of every gamedataVehicle_Record.

Reads r6/cache/tweakdb.bin + tweakdb_ep1.bin (ep1 layered on top, as the game does) with
the pure-Python reader in tdb.py and writes docs/generated/vehicle-customization-<ver>.csv:
one row per Vehicle record, TwinTone colour profiles as a compact JSON column.

Usage (from the repository root):
    python -I scripts/vehicle-kit/inventory/vehicle_inventory.py \
        --game "C:/Program Files (x86)/Steam/steamapps/common/Cyberpunk 2077" \
        --names <tweakdbstr.kark> --cache <scratch dir> [--vehicles-txt vehicles.txt]

See README.md in this folder.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tdb  # noqa: E402

DEFAULT_CP77TOOLS = os.path.expanduser(r"~\.dotnet\tools\cp77tools.exe")


class Ctx:
    def __init__(self, db: tdb.LayeredTweakDB, names: dict[int, str], paths: dict[int, str]):
        self.db = db
        self.names = names
        self.paths = paths
        self.unresolved_ids: set[int] = set()
        self.unresolved_paths: set[int] = set()

    def name(self, rid: int | None) -> str:
        if not rid:
            return ""
        n = self.names.get(rid & tdb.ID_MASK)
        if n is None:
            self.unresolved_ids.add(rid)
            return f"<0x{rid & tdb.ID_MASK:010X}>"
        return n

    def path(self, h: int | None) -> str:
        if not h:
            return ""
        p = self.paths.get(h)
        if p is None:
            self.unresolved_paths.add(h)
            return f"<0x{h:016X}>"
        return p

    def prop(self, rid: int, prop: str, default=None):
        return self.db.prop(rid, prop, default)


def rgb(v) -> list | None:
    return list(v) if isinstance(v, list) and v else None


def color_template(ctx: Ctx, tid: int, detail: bool = False) -> dict:
    p = lambda k, d=None: ctx.prop(tid, k, d)  # noqa: E731
    decals = p("customDecals", []) or []
    layers = p("customMultilayers", []) or []
    # Compact form: defaults are omitted (hue -1 = no light hue, pattern false, no decals,
    # no multilayers, no colour variant).
    out = {"id": ctx.name(tid), "main": rgb(p("mainColor")), "sec": rgb(p("secondaryColor"))}
    hue = p("lightsHue")
    if isinstance(hue, float) and hue >= 0:
        out["hue"] = round(hue, 4)
    if p("hasCustomPattern", False):
        out["pattern"] = True
    if decals:
        out["decals"] = len(decals)
    if layers:
        out["multilayers"] = len(layers)
    out["match"] = list(p("matchingAppearances", []) or [])
    variant = p("matchingColorVariant", []) or []
    if variant:
        out["variant"] = list(variant)
    if p("isOneTimeReward", False):
        out["oneTimeReward"] = True
    if detail:
        out["decalDetails"] = [{
            "id": ctx.name(d),
            "component": ctx.prop(d, "componentToAttachTo"),
            "resource": ctx.path(ctx.prop(d, "decalResource")),
            "onlyFor": list(ctx.prop(d, "onlyForPlayerVehicleAppearances", []) or []),
        } for d in decals]
        out["multilayerDetails"] = [{
            "id": ctx.name(m),
            "mlsetup": ctx.path(ctx.prop(m, "customMlSetup")),
            "mlmask": ctx.path(ctx.prop(m, "customMlMask")),
            "affected": list(ctx.prop(m, "affectedComponents", []) or []),
            "excluded": list(ctx.prop(m, "excludedComponents", []) or []),
            "onlyFor": list(ctx.prop(m, "onlyForPlayerVehicleAppearances", []) or []),
        } for m in layers]
        g = p("globalClearCoatOverrides")
        out["globalClearCoat"] = ctx.name(g) if g else ""
        parts = p("partsClearCoatOverrides", []) or []
        out["partsClearCoat"] = [ctx.name(x) for x in parts]
    return out


def wheel_preset(ctx: Ctx, pid: int | None) -> dict:
    if not pid:
        return {}
    return {k: ctx.prop(pid, k) for k in ("rimRadius", "tireRadius", "tireWidth", "wheelOffset")}


def enum_name(ctx: Ctx, rid: int | None) -> str:
    if not rid:
        return ""
    v = ctx.prop(rid, "enumName")
    return v if v else ctx.name(rid)


def vehicle_row(ctx: Ctx, rid: int, listed: set[str], detail: bool = False) -> dict:
    p = lambda k, d=None: ctx.prop(rid, k, d)  # noqa: E731
    wheels = p("vehWheelDimensionsSetup")
    front = wheel_preset(ctx, ctx.prop(wheels, "frontPreset")) if wheels else {}
    back = wheel_preset(ctx, ctx.prop(wheels, "backPreset")) if wheels else {}
    atct = p("appearancesToColorTemplate")
    templates = (ctx.prop(atct, "colorTemplates", []) or []) if atct else []
    profiles = [color_template(ctx, t, detail) for t in templates]
    name = ctx.name(rid)

    def f(v):
        return "" if v is None else (round(v, 4) if isinstance(v, float) else v)

    row = {
        "record": name,
        "recordId": f"0x{rid & tdb.ID_MASK:010X}",
        "inVehiclesTxt": name in listed,
        "vehicleType": enum_name(ctx, p("type")),
        "manufacturer": enum_name(ctx, p("manufacturer")),
        "model": enum_name(ctx, p("model")),
        "twintoneModelName": p("twintoneModelName", "") or "",
        "displayName": p("displayName", "") or "",
        "hasVisualCustomization": bool(p("hasVisualCustomization", False)),
        "customizableAppearance": p("customizableAppearance", "") or "",
        "customizeCarRims": bool(p("customizeCarRims", False)),
        "customizeLights": bool(p("customizeLights", False)),
        "hasUniqueCustomization": bool(p("hasUniqueCustomization", False)),
        "colorProfilesRestricted": bool(p("colorProfilesRestricted", False)),
        "canDeleteUniqueTemplates": bool(p("canDeleteUniqueTemplates", False)),
        "visualCustomizationTeaser": bool(p("visualCustomizationTeaser", False)),
        "customizationMenuType": p("customizationMenuType", "") or "",
        "genericCustomizationMask": ctx.path(p("genericCustomizationMask")),
        "excludedComponentsCustomization": ";".join(p("excludedComponentsCustomization", []) or []),
        "excludedComponentsGeneric": ";".join(p("excludedComponentsGeneric", []) or []),
        "entityTemplatePath": ctx.path(p("entityTemplatePath")),
        "appearanceName": p("appearanceName", "") or "",
        "destroyedAppearance": p("destroyedAppearance", "") or "",
        "wheelSetup": ctx.name(wheels) if wheels else "",
        "frontRimRadius": f(front.get("rimRadius")),
        "frontTireRadius": f(front.get("tireRadius")),
        "frontTireWidth": f(front.get("tireWidth")),
        "frontWheelOffset": f(front.get("wheelOffset")),
        "backRimRadius": f(back.get("rimRadius")),
        "backTireRadius": f(back.get("tireRadius")),
        "backTireWidth": f(back.get("tireWidth")),
        "backWheelOffset": f(back.get("wheelOffset")),
        "attachmentSlots": ";".join(ctx.name(x) for x in (p("attachmentSlots", []) or [])),
        "tags": ";".join(p("tags", []) or []),
        "visualTags": ";".join(p("visualTags", []) or []),
        "headlightColor": json.dumps(p("headlightColor", []) or [], separators=(",", ":")),
        "appearancesToColorTemplate": ctx.name(atct) if atct else "",
        "profileCount": len(profiles),
        "profiles": json.dumps(profiles, separators=(",", ":"), ensure_ascii=False),
    }
    if detail:
        row["_profiles"] = profiles
    return row


def read_listed(path: str | None) -> set[str]:
    if not path or not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as fh:
        return set(re.findall(r"\bVehicle\.[A-Za-z0-9_]+", fh.read()))


def open_context(game: str, names_path: str | None, cache: str, cp77tools: str) -> Ctx:
    cache_tdb = os.path.join(game, "r6", "cache")
    layers = [os.path.join(cache_tdb, "tweakdb.bin")]
    ep1 = os.path.join(cache_tdb, "tweakdb_ep1.bin")
    if os.path.exists(ep1):
        layers.append(ep1)
    db = tdb.LayeredTweakDB(layers)
    names = tdb.load_names(names_path, os.path.join(cache, "names"), cp77tools) if names_path else {}
    arch = os.path.join(game, "archive", "pc")
    paths = tdb.load_resource_paths([os.path.join(arch, "content"), os.path.join(arch, "ep1")],
                                    os.path.join(cache, "archive-lists"), cp77tools)
    return Ctx(db, names, paths)


def vehicle_record_ids(ctx: Ctx, extra_names: set[str]) -> list[int]:
    key = tdb.record_type_key("gamedataVehicle_Record")
    ids = {rid for rid in ctx.db.record_ids() if ctx.db.record_type(rid) == key}
    for n in extra_names:  # vehicles.txt names fill holes in the string table
        rid = tdb.tdbid(n)
        if ctx.db.record_type(rid) == key:
            ctx.names.setdefault(rid, n)
            ids.add(rid)
    return sorted(ids, key=lambda r: ctx.name(r))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=os.environ.get("OP77_GAME_DIR"), help="Cyberpunk 2077 install")
    ap.add_argument("--names", help="WolvenKit tweakdbstr.kark (or its decompressed .bin)")
    ap.add_argument("--vehicles-txt", help="optional list of known Vehicle.* names (vehicles.txt)")
    ap.add_argument("--cache", required=True, help="scratch dir for archive listings / names (outside the repo)")
    ap.add_argument("--cp77tools", default=DEFAULT_CP77TOOLS)
    ap.add_argument("--out", default=None, help="CSV output (default docs/generated/vehicle-customization-<ver>.csv)")
    ap.add_argument("--version", default="2.50")
    a = ap.parse_args(argv)
    if not a.game:
        ap.error("--game or OP77_GAME_DIR is required")

    repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
    out = a.out or os.path.join(repo, "docs", "generated", f"vehicle-customization-{a.version}.csv")

    ctx = open_context(a.game, a.names, a.cache, a.cp77tools)
    listed = read_listed(a.vehicles_txt)
    ids = vehicle_record_ids(ctx, listed)
    rows = [vehicle_row(ctx, rid, listed) for rid in ids]

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    real = [r for r in rows if r["entityTemplatePath"]]
    print(f"records: {len(rows)} Vehicle_Record ({len(real)} with an entity template)")
    print(f"  names from vehicles.txt: {sum(r['inVehiclesTxt'] for r in rows)} / {len(listed)} listed")
    for k in ("hasVisualCustomization", "customizeCarRims", "customizeLights", "hasUniqueCustomization",
              "colorProfilesRestricted"):
        print(f"  {k}: {sum(1 for r in rows if r[k])} (with template: {sum(1 for r in real if r[k])})")
    print(f"  twintoneModelName set: {sum(1 for r in rows if r['twintoneModelName'] not in ('', 'None'))}")
    print(f"  with >=1 colour profile: {sum(1 for r in rows if r['profileCount'])}"
          f"; distinct profiles: {len({p['id'] for r in rows for p in json.loads(r['profiles'])})}")
    print(f"  unresolved ids: {len(ctx.unresolved_ids)}, unresolved resource hashes: {len(ctx.unresolved_paths)}")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
