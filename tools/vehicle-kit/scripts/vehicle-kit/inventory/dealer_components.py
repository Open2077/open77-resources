"""Component inventory of the Light RP dealership models (offline, from the game files).

For each public stock entry of Light RP's dealership (server/config/dealerships.lua, keys
mapped to records by LightRpConfig.vehicles.catalog in shared/config.lua), plus any catalogue
key given with --extra (a staff-only car the Auto Studio also fits, such as the Caliburn;
appended after the stock, with price null and publicStock false):

  * TweakDB customization flags, wheel dimensions and TwinTone profiles (vehicle_inventory.py);
  * the record's .ent and every .app it references, unbundled and serialized with WolvenKit
    CLI into a SCRATCH folder (never the repository);
  * appearance names, slot components (wheel slots), and the union of the appearance
    components with their mesh, mesh appearances and parent binding, flagged by role
    (rim, tire, spoiler, bumper, plate, glass, light, widget, decal...).

Also surveys the shared license-plate meshes (task: do vanilla vehicles have plates, and how
are they textured).

Writes metadata only: docs/generated/vehicle-components-dealer-<ver>.json and .md.

Usage (repository root):
    python -I scripts/vehicle-kit/inventory/dealer_components.py --game <install> \
        --names <tweakdbstr.kark> --cache <scratch> --scratch <scratch> --light-rp <light-rp checkout>         [--extra caliburn]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cr2w_json as cj  # noqa: E402
import tdb  # noqa: E402
import vehicle_inventory as vi  # noqa: E402

PLATE_MESH_DIR = "base\\vehicles\\common\\parts\\v_common_licenseplate\\"


# ---- Light RP configuration (read-only) -------------------------------------------------

def read_light_rp(light_rp: str, extra: list[str] | None = None) -> list[dict]:
    gm = os.path.join(light_rp, "resources", "gamemodes", "op77_lightrp")
    with open(os.path.join(gm, "shared", "config.lua"), encoding="utf-8") as fh:
        config = fh.read()
    with open(os.path.join(gm, "server", "config", "dealerships.lua"), encoding="utf-8") as fh:
        dealers = fh.read()
    catalog = {}
    for m in re.finditer(r"\{\s*key\s*=\s*\"(\w+)\"[^{}]*?record\s*=\s*\"(Vehicle\.[\w]+)\"[^{}]*\}", config):
        body = m.group(0)
        label = re.search(r"label\s*=\s*\"([^\"]*)\"", body)
        cat = re.search(r"category\s*=\s*\"([^\"]*)\"", body)
        catalog[m.group(1)] = {"key": m.group(1), "record": m.group(2),
                               "label": label.group(1) if label else "",
                               "category": cat.group(1) if cat else "",
                               "staffOnly": "staffOnly = true" in body}
    stock_block = re.search(r"local\s+publicStock\s*=\s*\{(.*?)\n\}", dealers, re.S)
    out = []
    for m in re.finditer(r"\{\s*key\s*=\s*\"(\w+)\",\s*price\s*=\s*(\d+)", stock_block.group(1)):
        entry = dict(catalog[m.group(1)])
        entry["price"] = int(m.group(2))
        out.append(entry)
    stocked = {e["key"] for e in out}
    # extra = ["*"]: every catalogue key, the unsold ones (staff only) after the stock.
    for key in (list(catalog) if extra == ["*"] else extra or []):
        if key not in catalog:
            raise SystemExit(f"--extra {key}: not a key of LightRpConfig.vehicles.catalog")
        if key in stocked:
            continue
        entry = dict(catalog[key])
        entry["price"] = None  # not sold at the dealership
        entry["publicStock"] = False
        out.append(entry)
        stocked.add(key)
    return out


# ---- classification ---------------------------------------------------------------------

def flags_for(name: str, ctype: str, mesh: str, parent: dict | None, ctx: dict) -> list[str]:
    n = (name or "").lower()
    m = (mesh or "").lower()
    mb = m.rsplit("\\", 1)[-1]
    slot = ((parent or {}).get("slotName") or "").lower()
    bind = ((parent or {}).get("bindName") or "").lower()
    text = n + " " + mb
    f = []
    if slot.startswith("wheel_") or bind in ctx["wheel_components"]:
        f.append("wheel")
    if "steering" not in text and (re.search(r"(^|[_ ])wheel", n) or re.search(r"__ext\d+_wheel|_rim(_|\.)|(^|_)rim_", mb)):
        if "tire" not in text and "tyre" not in text and ctype != "WorldWidgetComponent":
            f.append("rim")
    if "tire" in text or "tyre" in text:
        f.append("tire")
    if slot.startswith("brake_") or re.search(r"caliper|brake_disc|disc_brake", text):
        f.append("brake")
    if "spoiler" in text or re.search(r"(^|_)wing(_|\.|$)", n) or re.search(r"__ext\d+_wing", mb):
        f.append("spoiler")
    if "bumper" in text:
        f.append("bumper")
    if re.search(r"licen[cs]e|(^|_)(id_|med_)?plate(_|\.|$)", text) or m.startswith(PLATE_MESH_DIR):
        f.append("plate")
    if re.search(r"window|glass|windshield|windscreen", text):
        f.append("glass")
    if ctype in ("vehicleLightComponent", "gameLightComponent", "entLightComponent", "entSpotLightComponent") \
            or re.search(r"light|lamp", text):
        f.append("light")
    if ctype == "WorldWidgetComponent":
        f.append("widget")
    if n.startswith("visual_customization"):
        f.append("visualCustomizationWidget")
    if ctype == "entDecalComponent" or "decal" in text or "sticker" in text:
        f.append("decal")
    if name in ctx["decal_targets"]:
        f.append("twintoneDecalTarget")
    if name in ctx["multilayer_targets"]:
        f.append("twintoneMultilayerTarget")
    if name in ctx["excluded_custom"]:
        f.append("excludedFromCustomization")
    if name in ctx["excluded_generic"]:
        f.append("excludedFromGenericPaint")
    if n.endswith("_shadow") or "_shadow." in mb:
        f.append("shadow")
    if "\\common\\parts\\placeables\\" in m:
        f.append("placeable")
    for part in ("hood", "trunk", "door", "mirror", "roof", "skirt", "fender", "exhaust", "body", "chassis",
                 "chasis", "interior", "engine", "fuel"):
        if part in n:
            f.append("part:" + ("chassis" if part == "chasis" else part))
            break
    return f


def summarize_component(doc: cj.Doc, c: dict) -> dict:
    ctype = c.get("$type")
    out = OrderedDict()
    out["name"] = cj.val(c.get("name"))
    out["type"] = ctype
    mesh = cj.val(c.get("mesh")) if c.get("mesh") else ""
    if mesh:
        out["mesh"] = mesh
        out["meshAppearance"] = cj.val(c.get("meshAppearance"))
    parent = cj.binding(doc, c)
    if parent:
        out["parent"] = parent
    if ctype == "WorldWidgetComponent":
        mt = cj.binding(doc, c, "meshTargetBinding")
        if mt:
            out["meshTarget"] = mt
        for k, v in c.items():
            if isinstance(v, dict) and "DepotPath" in v and cj.val(v):
                out.setdefault("resources", {})[k] = cj.val(v)
    if ctype == "vehicleLightComponent":
        if "lightType" in c:  # vehicleELightType: Head, Brake, Reverse, Blinker...
            out["lightType"] = cj.val(c["lightType"])
    if ctype == "entDecalComponent" and c.get("material"):
        out["material"] = cj.val(c.get("material"))
    if ctype == "entSlotComponent":
        out["slots"] = [cj.val(s.get("slotName")) for s in (c.get("slots") or [])]
    return out


def component_signature(s: dict) -> tuple[str, str]:
    """What makes two appearances' copies of a component the same geometry in the same place:
    its type, mesh and parent binding (bind name and slot); and, apart, its mesh appearance (a
    material swap on the same geometry: a decal hung on it still sits where it was measured)."""
    par = s.get("parent") or {}
    geometry = "|".join(str(x or "") for x in (s.get("type"), s.get("mesh"), par.get("bindName"), par.get("slotName")))
    return geometry, str(s.get("meshAppearance") or "")


def trim_table(trims: list[dict], names: list[str], default: str, player_app: str,
               signatures: dict[str, dict[str, str]]) -> list[dict]:
    """Per record sharing this body (scope `records`): the entity appearance it spawns with, the
    components of that appearance, and those whose mesh or binding differ from the player
    appearance's (a decal hung on one of those would not sit on the panel it was measured on)."""
    out = []
    ref = signatures.get(player_app, {})
    # differs = another mesh or binding (the panel moved or changed); restyled = the same geometry
    # under another mesh appearance (paint or material only).
    for t in trims:
        app = t.get("appearance") or ""
        source = "tweakdb appearanceName"
        if app not in names:
            app, source = (default, "entity defaultAppearance") if default in names else                 ((names[0], "first entity appearance") if names else ("", "none"))
        sig = signatures.get(app)
        row = OrderedDict([("record", t["record"]), ("appearance", app), ("appearanceSource", source),
                           ("found", sig is not None)])
        if sig is not None:
            row["components"] = sorted(sig)
            row["differs"] = sorted(n for n, v in sig.items() if n in ref and ref[n][0] != v[0])
            row["restyled"] = sorted(n for n, v in sig.items() if n in ref and ref[n][0] == v[0] and ref[n][1] != v[1])
            row["absent"] = sorted(n for n in ref if n not in sig)
        out.append(row)
    return out


def read_scope(path: str, only: set[str] | None = None) -> list[dict]:
    """Bodies of docs/generated/vehicle-player-scope-<ver>.json (player_scope.py) as entries:
    the primary record, and every record of the body as a trim."""
    with open(path, encoding="utf-8") as fh:
        scope = json.load(fh)
    out = []
    for b in scope["bodies"]:
        if only and b["key"] not in only:
            continue
        maker = b["primary"].split(".", 1)[1].split("_")
        out.append({"key": b["key"], "record": b["primary"],
                    "label": b["key"].replace("_", " ").title(),
                    "category": "Bikes" if b["vehicleType"] == "Bike" else "Vehicle",
                    "price": None, "publicStock": False, "staffOnly": False,
                    "trims": [{"record": r["record"], "appearance": r["appearance"]} for r in b["records"]]})
    return out


def overlay_light_rp(stock: list[dict], light_rp: str) -> list[dict]:
    """Scope entries that are Light RP catalogue keys take the catalogue's label, category and
    staff flag and the dealership's price, so the dealer models read the same in both tables."""
    rp = {e["key"]: e for e in read_light_rp(light_rp, ["*"])}
    out = []
    for e in stock:
        c = rp.get(e["key"])
        if c and c["record"] != e["record"]:
            raise SystemExit(f'{e["key"]}: the scope primary {e["record"]} is not the Light RP record {c["record"]}')
        if c:
            e = dict(e, label=c["label"], category=c["category"], price=c["price"])
            if c.get("publicStock") is False:
                e["publicStock"], e["staffOnly"] = False, bool(c.get("staffOnly"))
            else:
                e.pop("publicStock", None)
                e.pop("staffOnly", None)
        out.append(e)
    return out


# ---- per model ---------------------------------------------------------------------------

def analyse_model(entry: dict, ctx_tdb: vi.Ctx, game: str, cp77tools: str, scratch: str,
                  index: dict[str, list[str]]) -> dict:
    rid = tdb.tdbid(entry["record"])
    row = vi.vehicle_row(ctx_tdb, rid, set(), detail=True)
    profiles = row.pop("_profiles")
    ent_path = row["entityTemplatePath"]
    model = OrderedDict()
    model["key"] = entry["key"]
    model["label"] = entry["label"]
    model["category"] = entry["category"]
    model["price"] = entry["price"]
    if entry.get("publicStock") is False:
        model["publicStock"] = False
        model["staffOnly"] = bool(entry.get("staffOnly"))
    model["record"] = entry["record"]
    model["tweakdb"] = OrderedDict((k, row[k]) for k in (
        "vehicleType", "manufacturer", "model", "twintoneModelName", "hasVisualCustomization",
        "customizableAppearance", "customizeCarRims", "customizeLights", "hasUniqueCustomization",
        "colorProfilesRestricted", "canDeleteUniqueTemplates", "customizationMenuType",
        "genericCustomizationMask", "appearanceName", "destroyedAppearance", "attachmentSlots"))
    model["tweakdb"]["excludedComponentsCustomization"] = [x for x in row["excludedComponentsCustomization"].split(";") if x]
    model["tweakdb"]["excludedComponentsGeneric"] = [x for x in row["excludedComponentsGeneric"].split(";") if x]
    model["wheels"] = {
        "setup": row["wheelSetup"],
        "front": {k: row["front" + k[0].upper() + k[1:]] for k in ("rimRadius", "tireRadius", "tireWidth", "wheelOffset")},
        "back": {k: row["back" + k[0].upper() + k[1:]] for k in ("rimRadius", "tireRadius", "tireWidth", "wheelOffset")},
    }
    model["twintone"] = {"appearancesToColorTemplate": row["appearancesToColorTemplate"],
                         "profileCount": len(profiles), "profiles": profiles}

    ent_info = cj.extract(game, cp77tools, scratch, [ent_path], index)[ent_path.lower()]
    model["entity"] = {"path": ent_path, "archive": ent_info["archive"], "alsoIn": ent_info["alsoIn"]}
    if not ent_info["json"]:
        model["entity"]["error"] = "not extracted"
        return model
    ent = cj.Doc(ent_info["json"])
    root = ent.root
    appearances = []
    for a in root.get("appearances") or []:
        appearances.append({"name": cj.val(a.get("name")), "appearanceName": cj.val(a.get("appearanceName")),
                            "app": cj.val(a.get("appearanceResource"))})
    model["entity"]["defaultAppearance"] = cj.val(root.get("defaultAppearance"))
    ent_comps = cj.component_list(ent, root)
    slot_comps = []
    for c in ent_comps:
        if c.get("$type") == "entSlotComponent":
            slot_comps.append({"name": cj.val(c.get("name")), "parent": cj.binding(ent, c),
                               "slots": [{"slot": cj.val(s.get("slotName")), "bone": cj.val(s.get("boneName"))}
                                         for s in (c.get("slots") or [])]})
    model["entity"]["slotComponents"] = slot_comps
    vs = next((s for s in slot_comps if s["name"] == "vehicle_slots"), None)
    model["wheelSlots"] = list(OrderedDict.fromkeys(
        s["slot"] for s in (vs or {}).get("slots", []) if s["slot"].startswith("wheel")))
    model["entity"]["componentTypes"] = dict(Counter(c.get("$type") for c in ent_comps).most_common())
    special = []
    for c in ent_comps:
        t = c.get("$type")
        if t in ("vehicleVehicleCustomization", "entDecalComponent", "WorldWidgetComponent") or \
                cj.val(c.get("name") or "").startswith("visual_customization"):
            s = summarize_component(ent, c)
            if t == "vehicleVehicleCustomization":
                s["defaultDecalsPerAppearance"] = c.get("defaultDecalsPerAppearance")
            special.append(s)
    model["entity"]["specialComponents"] = special

    app_paths = sorted({a["app"] for a in appearances if a["app"]})
    app_info = cj.extract(game, cp77tools, scratch, app_paths, index)
    model["appFiles"] = [{"path": p, "archive": app_info[p.lower()]["archive"],
                          "alsoIn": app_info[p.lower()]["alsoIn"]} for p in app_paths]

    ctx = {
        "decal_targets": {d.get("component") for p in profiles for d in p.get("decalDetails", [])},
        "multilayer_targets": {x for p in profiles for ml in p.get("multilayerDetails", []) for x in ml.get("affected", [])},
        "excluded_custom": set(model["tweakdb"]["excludedComponentsCustomization"]),
        "excluded_generic": set(model["tweakdb"]["excludedComponentsGeneric"]),
        "wheel_components": set(),
    }
    # The record's appearanceName is the entity appearance a spawned car gets; when the record
    # leaves it empty the entity's default appearance applies (first one when "random").
    player_app = row["appearanceName"]
    player_source = "tweakdb appearanceName"
    names = [a["name"] for a in appearances]
    if not player_app or player_app == "None" or player_app not in names:
        default = model["entity"]["defaultAppearance"]
        player_app, player_source = (default, "entity defaultAppearance") if default in names else             ((names[0], "first entity appearance") if names else ("", "none"))
    union: "OrderedDict[str, dict]" = OrderedDict()
    signatures: dict[str, dict[str, str]] = {}
    app_docs = {}
    per_appearance = []
    for a in appearances:
        p = (a["app"] or "").lower()
        if p not in app_docs:
            j = app_info.get(p, {}).get("json")
            app_docs[p] = cj.Doc(j) if j else None
        doc = app_docs[p]
        if doc is None:
            per_appearance.append(dict(a, found=False))
            continue
        defs = [doc.deref(x) for x in doc.root.get("appearances") or []]
        d = next((x for x in defs if x and cj.val(x.get("name")) == a["appearanceName"]), None)
        if d is None:
            per_appearance.append(dict(a, found=False))
            continue
        comps = cj.component_list(doc, d)
        summaries = [summarize_component(doc, c) for c in comps]
        signatures[a["name"]] = {s["name"]: component_signature(s) for s in summaries if s["name"] not in (None, "", "None")}
        # tires/rims hang on the wheel components: a second pass flags their children
        for s in summaries:
            par = s.get("parent") or {}
            if (par.get("slotName") or "").startswith("wheel_"):
                ctx["wheel_components"].add(s["name"].lower())
        names_by_flag: dict[str, list[str]] = {}
        for s in summaries:
            fl = flags_for(s["name"], s["type"], s.get("mesh", ""), s.get("parent"), ctx)
            key = s["name"] + "|" + s.get("mesh", "")
            u = union.get(key)
            if u is None:
                u = OrderedDict(s)
                u.pop("meshAppearance", None)
                u["meshAppearances"] = []
                u["appearanceCount"] = 0
                u["inPlayerAppearance"] = False
                u["flags"] = fl
                union[key] = u
            if s.get("meshAppearance") and s["meshAppearance"] not in u["meshAppearances"]:
                u["meshAppearances"].append(s["meshAppearance"])
            u["appearanceCount"] += 1
            if a["name"] == player_app:
                u["inPlayerAppearance"] = True
            for f in fl:
                if f in ("rim", "tire", "spoiler", "bumper", "plate", "glass", "visualCustomizationWidget", "widget", "decal"):
                    names_by_flag.setdefault(f, []).append(s["name"])
        per_appearance.append(dict(a, found=True, componentCount=len(comps),
                                   visualControllerParts=len(d.get("partsValues") or []),
                                   flagged={k: sorted(set(v)) for k, v in sorted(names_by_flag.items())}))
    model["appearances"] = per_appearance
    model["playerAppearance"] = player_app
    model["playerAppearanceSource"] = player_source
    if entry.get("trims"):
        model["trims"] = trim_table(entry["trims"], names, model["entity"]["defaultAppearance"], player_app, signatures)
    for u in union.values():
        if not u["meshAppearances"]:
            u.pop("meshAppearances")
    model["components"] = list(union.values())
    return model


def plate_survey(game: str, cp77tools: str, scratch: str, index: dict[str, list[str]]) -> dict:
    meshes = sorted(p for p in index if p.startswith(PLATE_MESH_DIR.lower()) and p.endswith(".mesh"))
    textures = sorted(p for p in index if re.search(r"\\license_plate[^\\]*\.xbm$", p))
    info = cj.extract(game, cp77tools, scratch, meshes, index)
    out = {"meshDirectory": PLATE_MESH_DIR, "textures": textures, "meshes": []}
    for p in meshes:
        j = info[p]["json"]
        entry = {"path": p, "archive": info[p]["archive"]}
        if j:
            doc = cj.Doc(j)
            r = doc.root
            entry["appearances"] = []
            for a in r.get("appearances") or []:
                ad = doc.deref(a)
                entry["appearances"].append({"name": cj.val(ad.get("name")),
                                             "chunkMaterials": [cj.val(x) for x in ad.get("chunkMaterials") or []]})
            mats = []
            for i, me in enumerate(r.get("materialEntries") or []):
                mats.append({"name": cj.val(me.get("name")), "index": me.get("index"),
                             "isLocalInstance": me.get("isLocalInstance")})
            entry["materialEntries"] = mats
            local = []
            # cooked meshes keep local materials either in the buffer or as preloaded instances
            local_src = (((r.get("localMaterialBuffer") or {}).get("materials")) or []) or                 (r.get("preloadLocalMaterialInstances") or []) or (r.get("localMaterialInstances") or [])
            for m in local_src:
                md = doc.deref(m) if isinstance(m, dict) else None
                if not md:
                    continue
                base_mat = cj.val(md.get("baseMaterial"))
                params = {}
                for pv in md.get("values") or []:
                    for k, v in pv.items():
                        if k.startswith("$"):
                            continue
                        vv = cj.val(v)
                        if isinstance(vv, str) and ("\\" in vv or vv.endswith(".xbm")):
                            params[k] = vv
                        elif isinstance(v, dict) and v.get("$type") in ("Color", "Vector4"):
                            params[k] = {kk: vvv for kk, vvv in v.items() if not kk.startswith("$")}
                        elif isinstance(v, (int, float)):
                            params[k] = v
                local.append({"baseMaterial": base_mat, "params": params})
            entry["localMaterials"] = local
            ext = []
            for m in r.get("externalMaterials") or []:
                ext.append(cj.val(m))
            if ext:
                entry["externalMaterials"] = ext
        out["meshes"].append(entry)
    return out


def plate_usage_all(game: str, cp77tools: str, scratch: str, index: dict[str, list[str]]) -> dict:
    """Every vehicle .app of the game: which appearances carry a plate component."""
    apps = sorted(p for p in index if p.endswith(".app") and re.match(r"^(base|ep1)\\vehicles\\", p))
    info = cj.extract(game, cp77tools, scratch, apps, index)
    ctx = {"decal_targets": set(), "multilayer_targets": set(), "excluded_custom": set(),
           "excluded_generic": set(), "wheel_components": set()}
    total_apps = total_appearances = with_plate = 0
    meshes: Counter = Counter()
    mesh_appearances: Counter = Counter()
    names: Counter = Counter()
    vc_widgets: dict[str, dict] = {}
    per_app = []
    failed = []
    for p in apps:
        j = info[p]["json"]
        if not j:
            failed.append(p)
            continue
        doc = cj.Doc(j)
        total_apps += 1
        n_app = n_plate = 0
        for a in doc.root.get("appearances") or []:
            d = doc.deref(a)
            if not d:
                continue
            n_app += 1
            found = False
            for c in cj.component_list(doc, d):
                mesh = cj.val(c.get("mesh")) if c.get("mesh") else ""
                name = cj.val(c.get("name")) or ""
                if c.get("$type") == "WorldWidgetComponent":
                    res = cj.val(c.get("widgetResource")) or ""
                    if name.startswith("visual_customization") or "visual_customization" in res.lower():
                        mt = cj.binding(doc, c, "meshTargetBinding") or {}
                        w = vc_widgets.setdefault(name + "|" + res, {
                            "name": name, "widgetResource": res, "meshTargets": [], "apps": []})
                        if mt.get("bindName") and mt["bindName"] not in w["meshTargets"]:
                            w["meshTargets"].append(mt["bindName"])
                        if p not in w["apps"]:
                            w["apps"].append(p)
                if "plate" in flags_for(name, c.get("$type"), mesh, None, ctx):
                    found = True
                    meshes[mesh] += 1
                    names[name] += 1
                    if mesh.lower().startswith(PLATE_MESH_DIR.lower()):
                        mesh_appearances[f"{mesh.rsplit(chr(92), 1)[-1]}:{cj.val(c.get('meshAppearance'))}"] += 1
            n_plate += found
        total_appearances += n_app
        with_plate += n_plate
        per_app.append({"app": p, "appearances": n_app, "withPlate": n_plate})
        del doc
    return {"appFiles": total_apps, "appearances": total_appearances, "appearancesWithPlate": with_plate,
            "appFilesWithPlate": sum(1 for x in per_app if x["withPlate"]),
            "plateMeshes": dict(meshes.most_common()), "plateComponentNames": dict(names.most_common()),
            "sharedMeshAppearances": dict(mesh_appearances.most_common()),
            "visualCustomizationWidgets": list(vc_widgets.values()),
            "notExtracted": failed, "perApp": per_app}


def write_markdown(path: str, models: list[dict], plates: dict, version: str, plate_usage: dict,
                   stem: str = "vehicle-components-dealer") -> None:
    L = []
    title = "Light RP dealership vehicles" if stem == "vehicle-components-dealer" else "Vanilla player vehicles (one row per body)"
    L.append(f"# {title} — customization inventory ({version})")
    L.append("")
    L.append("> Generated offline by `scripts/vehicle-kit/inventory/dealer_components.py` from "
             "`r6/cache/tweakdb*.bin` and the `.ent`/`.app` files of each model (WolvenKit CLI "
             "serialization). Metadata only. Full data: `" + stem + "-" + version + ".json`.")
    L.append("")
    L.append("Columns: **paint** = `hasVisualCustomization`; **rims** = `customizeCarRims` (CrystalCoat paint "
             "extends to the rims); **lights** = `customizeLights`; **profiles** = TwinTone colour templates "
             "(`appearancesToColorTemplate`); **wheel** = front/back tire radius in metres (rim radius).")
    L.append("")
    L.append("| key | record | paint | rims | lights | unique | profiles | entity appearances | player appearance |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for m in models:
        t = m["tweakdb"]
        L.append(f"| {m['key']} | `{m['record']}` | {yn(t['hasVisualCustomization'])} | {yn(t['customizeCarRims'])} | "
                 f"{yn(t['customizeLights'])} | {yn(t['hasUniqueCustomization'])} | {m['twintone']['profileCount']} | "
                 f"{len(m.get('appearances', []))} | `{m.get('playerAppearance', '')}` |")
    L.append("")
    L.append("Component names below are those of the player appearance (the one a spawned `_player` record "
             "gets), shadow meshes left out; the JSON lists every appearance. Role flags are name/mesh heuristics.")
    L.append("")
    L.append("| key | rim components | tire components | spoiler | bumpers | plate | wheel slots | wheel radius F / B (rim) |")
    L.append("|---|---|---|---|---|---|---|---|")
    for m in models:
        comps = m.get("components", [])

        def names(flag, player_only=True):
            return sorted({c["name"] for c in comps if flag in c["flags"] and "shadow" not in c["flags"]
                           and (c["inPlayerAppearance"] or not player_only)})
        w = m["wheels"]
        L.append(f"| {m['key']} | {fmt(names('rim'))} | {fmt(names('tire'))} | {fmt(names('spoiler'))} | "
                 f"{fmt(names('bumper'))} | {fmt(names('plate'))} | {fmt(m.get('wheelSlots', []))} | "
                 f"{w['front']['tireRadius']} / {w['back']['tireRadius']} ({w['front']['rimRadius']} / {w['back']['rimRadius']}) |")
    L.append("")
    L.append("## Per model")
    for m in models:
        t = m["tweakdb"]
        comps = m.get("components", [])
        player = [c for c in comps if c["inPlayerAppearance"]]
        L.append("")
        L.append(f"### {m['key']} — {m['label']} (`{m['record']}`)")
        L.append("")
        L.append(f"- entity: `{m['entity']['path']}` ({m['entity'].get('archive')}); app files: "
                 + ", ".join(f"`{a['path']}`" for a in m.get("appFiles", [])))
        L.append(f"- TwinTone model `{t['twintoneModelName']}`, menu `{t['customizationMenuType']}`, "
                 f"{m['twintone']['profileCount']} profiles; generic mask `{t['genericCustomizationMask'] or '-'}`")
        L.append(f"- excluded from customization: {fmt(t['excludedComponentsCustomization'])}; "
                 f"from generic paint: {fmt(t['excludedComponentsGeneric'])}")
        pats = [p for p in m["twintone"]["profiles"] if p.get("pattern") or p.get("decals") or p.get("multilayers")]
        if pats:
            L.append(f"- profiles with pattern/decals/multilayers: " + ", ".join(
                f"`{p['id'].split('.')[-1]}` (decals {p.get('decals', 0)}, layers {p.get('multilayers', 0)})" for p in pats))
            targets = sorted({d['component'] for p in pats for d in p.get('decalDetails', [])})
            if targets:
                L.append(f"- TwinTone decal target components: {fmt(targets)}")
        L.append(f"- player appearance `{m.get('playerAppearance')}` ({m.get('playerAppearanceSource')}): {len(player)} components; "
                 f"plate in player appearance: {yn(any('plate' in c['flags'] for c in player))}; "
                 f"appearances with a plate component: {sum(1 for a in m.get('appearances', []) if a.get('flagged', {}).get('plate'))}"
                 f"/{len(m.get('appearances', []))}")
        lights = sorted({c['name'] for c in player if c['type'] == 'vehicleLightComponent'})
        glass = sorted({c['name'] for c in player if 'glass' in c['flags'] and 'shadow' not in c['flags']})
        widgets = sorted({c['name'] for c in comps if 'widget' in c['flags']})
        L.append(f"- glass (player): {fmt(glass)}")
        kinds = Counter(c.get("lightType", "?") for c in player if c["type"] == "vehicleLightComponent")
        L.append(f"- light components (player): {len(lights)} ({', '.join(f'{k} {v}' for k, v in sorted(kinds.items()))}) — {fmt(lights)}")
        L.append(f"- all appearances, rims: {fmt(sorted({c['name'] for c in comps if 'rim' in c['flags'] and 'shadow' not in c['flags']}))}; "
                 f"spoilers: {fmt(sorted({c['name'] for c in comps if 'spoiler' in c['flags'] and 'shadow' not in c['flags']}))}; "
                 f"plates: {fmt(sorted({c['name'] for c in comps if 'plate' in c['flags'] and 'shadow' not in c['flags']}))}")
        L.append(f"- world widgets: {fmt(widgets)}")
        L.append(f"- factory appearances ({len(m.get('appearances', []))}): "
                 + ", ".join(f"`{a['name']}`" for a in m.get("appearances", [])))
    L.append("")
    L.append("## License plates")
    L.append("")
    L.append(f"Shared meshes under `{plates['meshDirectory']}`; textures: " + ", ".join(f"`{t}`" for t in plates["textures"]))
    L.append("")
    for me in plates["meshes"]:
        apps = ", ".join(f"`{a['name']}`" for a in me.get("appearances", []))
        texs = sorted({v for lm in me.get("localMaterials", []) for v in lm["params"].values() if isinstance(v, str)})
        L.append(f"- `{me['path'].rsplit(chr(92), 1)[-1]}`: appearances {apps or '-'}; textures/materials referenced: {fmt(texs)}")
    L.append("")
    L.append("Reading (fact unless marked):")
    L.append("")
    L.append("- Plates are ordinary mesh components (`entPhysicalMeshComponent` or `entMeshComponent`) that point to the "
             "shared meshes above. They usually hang on a bumper or the body and sometimes on a `vehicle_slots` slot "
             "(`bumper_back` / `bumper_front`). They are absent from some player appearances. In this list, Hella and "
             "Quartz carry a plate only in their non-player appearances, and Merrimac carries none in any appearance.")
    L.append("- The plate face is the `license_plate_holo` chunk: the holographic `base\\fx\\shaders\\parallaxscreen.mt` "
             "shader with a fixed `ParalaxTexture`. That texture is `license_plate_nightcity_d.xbm` for the `default` mesh "
             "appearance, which nearly every component uses. `socal_plate` and `rogue_custom` swap in the other two "
             "textures. The mesh has no text or number parameter. Every car showing a given mesh appearance therefore "
             "shows the same plate image. Inference: the number area of the nightcity and socal textures is a strip of "
             "glyph fragments that the shader's scroll mask animates, not a readable per-vehicle number.")
    L.append("- The plate meshes also have `decals` (`base\\vehicles\\common\\materials\\decals.mi`) and `stickers` "
             "(`stickers.mi`) chunks, the shared vehicle decal and sticker materials.")
    L.append("- Inference: a custom plate text needs a new texture or material per plate (an inert pack, through a "
             "mesh appearance or material override) or a runtime-rendered surface such as a world widget. That is "
             "plan E0.7, routes W, D and M. No vanilla plate takes text at runtime.")
    L.append("")
    u = plates.get("usage")
    if u:
        L.append(f"All vehicle `.app` files ({u['appFiles']}): {u['appearancesWithPlate']} of {u['appearances']} "
                 f"appearances carry a plate component ({u['appFilesWithPlate']} files).")
        L.append("")
        L.append("| plate mesh | components |")
        L.append("|---|---|")
        for mesh, n in u["plateMeshes"].items():
            L.append(f"| `{mesh}` | {n} |")
        L.append("")
        L.append("Shared plate mesh appearances used: " + ", ".join(f"`{k}` x{v}" for k, v in u["sharedMeshAppearances"].items()))
        L.append("")
        L.append("`visual_customization` world widgets (CrystalCoat ink rendered into a mesh) found in vehicle `.app` files: "
                 + ("; ".join(f"`{w['name']}` → `{w['widgetResource']}` on {fmt(w['meshTargets'])} in {len(w['apps'])} file(s)"
                              for w in u["visualCustomizationWidgets"]) or "none"))
        if u["notExtracted"]:
            L.append("")
            L.append("Not extracted: " + fmt(u["notExtracted"]))
        L.append("")
    L.append("Plate components per dealership model (all appearances): ")
    for k, v in plate_usage.items():
        L.append(f"- {k}: {v}")
    L.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(L))


def yn(v) -> str:
    return "yes" if v else "no"


def fmt(xs) -> str:
    xs = list(xs)
    return ", ".join(f"`{x}`" for x in xs) if xs else "—"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=os.environ.get("OP77_GAME_DIR"))
    ap.add_argument("--names", required=True, help="WolvenKit tweakdbstr.kark")
    ap.add_argument("--cache", required=True, help="scratch dir for archive listings / names")
    ap.add_argument("--scratch", required=True, help="scratch dir for extracted files (outside any repo)")
    ap.add_argument("--light-rp", help="Light RP checkout (read only); required without --scope. With --scope: "
                                       "the catalogue keys take their Light RP label, category and price")
    ap.add_argument("--scope", help="docs/generated/vehicle-player-scope-<ver>.json (player_scope.py): inventory "
                                    "its bodies instead of the Light RP stock, with their trims")
    ap.add_argument("--only", default="", help="with --scope: comma-separated body keys to inventory")
    ap.add_argument("--out-name", default="vehicle-components-dealer",
                    help="output stem under docs/generated (vehicle-components-player-bodies with --scope)")
    ap.add_argument("--cp77tools", default=vi.DEFAULT_CP77TOOLS)
    ap.add_argument("--version", default="2.50")
    ap.add_argument("--extra", default="",
                    help="comma-separated catalogue keys outside the public stock to inventory too (e.g. caliburn)")
    ap.add_argument("--skip-plate-survey", action="store_true",
                    help="do not serialize every vehicle .app to count plate components")
    a = ap.parse_args(argv)
    repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
    for p in (a.scratch, a.cache):
        if os.path.abspath(p).lower().startswith(repo.lower()):
            ap.error(f"{p} is inside the repository; extracted game files must stay outside it")

    if a.scope:
        stock = read_scope(a.scope, {k.strip() for k in a.only.split(",") if k.strip()} or None)
        if a.light_rp:
            stock = overlay_light_rp(stock, a.light_rp)
        if a.out_name == "vehicle-components-dealer":
            a.out_name = "vehicle-components-player-bodies"
    elif a.light_rp:
        stock = read_light_rp(a.light_rp, [k.strip() for k in a.extra.split(",") if k.strip()])
    else:
        ap.error("--light-rp or --scope is required")
    ctx = vi.open_context(a.game, a.names, a.cache, a.cp77tools)
    index = cj.archive_index(os.path.join(a.cache, "archive-lists"))
    models = []
    for entry in stock:
        print(f"{entry['key']}: {entry['record']}", flush=True)
        models.append(analyse_model(entry, ctx, a.game, a.cp77tools, a.scratch, index))
    plates = plate_survey(a.game, a.cp77tools, a.scratch, index)
    if not a.skip_plate_survey:
        print("surveying every vehicle .app for plate components", flush=True)
        plates["usage"] = plate_usage_all(a.game, a.cp77tools, a.scratch, index)
    plate_usage = OrderedDict()
    for m in models:
        meshes = Counter()
        for c in m.get("components", []):
            if "plate" in c["flags"]:
                meshes[f"{c['name']} -> {c.get('mesh', '')} ({c['appearanceCount']} app.)"] += 1
        plate_usage[m["key"]] = "; ".join(meshes) if meshes else "none"

    out_dir = os.path.join(repo, "docs", "generated")
    os.makedirs(out_dir, exist_ok=True)
    doc = OrderedDict()
    doc["generatedBy"] = "scripts/vehicle-kit/inventory/dealer_components.py"
    doc["gameVersion"] = a.version
    doc["source"] = "r6/cache/tweakdb.bin + tweakdb_ep1.bin; .ent/.app serialized with WolvenKit CLI"
    doc["models"] = models
    doc["licensePlates"] = plates
    jpath = os.path.join(out_dir, f"{a.out_name}-{a.version}.json")
    with open(jpath, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    mpath = os.path.join(out_dir, f"{a.out_name}-{a.version}.md")
    write_markdown(mpath, models, plates, a.version, plate_usage, a.out_name)
    print(f"wrote {jpath}\nwrote {mpath}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
