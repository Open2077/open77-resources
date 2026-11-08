"""Curated sticker catalogue of the Light RP dealer models (wave 2, W2.4), offline.

Input: the survey (st_survey.py: every sticker component the game fits to each dealer model, its
binding resolved on the player appearance) and the spec (specs/lightrp-stickers.json: groups,
exclusions, which vanilla appearance belongs to which group). Output: plan.json.

    sticker  = the sticker components one vanilla appearance shows together (a look the game's
               artists composed), after the filters below, deduplicated per model. Kept whole up
               to maxDecalsPerSticker decals; a bigger set is split by panel family (body,
               front, left, right, rear) into parts that each fit.
    decal    = one sticker component = one VehicleDecalAttachment (our .ent wrapping the
               vanilla mesh, hung on the player appearance's component). Shared by every
               sticker of the model that shows it.

Filters (a row refused here never reaches the pack): interior parts, components hidden in that
appearance (chunkMask 0), stickers the player car already wears, bindings with no host on the
player appearance, and every row, appearance or label carrying an excluded token (the contract
list: police, sheriff, border patrol, NCPD, MaxTac, Arasaka, Delamain; plus the proposed list,
an owner decision: NetWatch, Militech, Kang Tao, the taxi, Trauma).

Labels are generated, "<group> <n>" or "<group> <n>: <families>", so no make, model or character
name reaches a player; the vanilla appearance names stay in `source`, internal.

    python st_plan.py --survey <survey.json> --spec <spec.json> --out <plan.json>
    python st_plan.py --survey <survey.json> --spec <spec.json> --check <plan.json>

Both run the plan check and its negative tests (every mutation of a good plan must be refused).
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "liveries"))
from lv_common import MAX_DECALS_PER_TEMPLATE  # noqa: E402

SCHEMA = "open77.vehicle-stickers.plan/1"
SPEC_SCHEMA = "open77.vehicle-stickers/1"
SURVEY_SCHEMA = "open77.vehicle-stickers-survey/1"
ID_RE = re.compile(r"^st\.[a-z0-9]+\.[a-z0-9]+(?:_[a-z0-9]+)*_\d{2}[a-z]?$")
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 :+'-]{0,47}$")
MESH_RE = re.compile(r"^(base|ep1)\\vehicles\\[a-z0-9_\\]+\.mesh$")
COMPONENT_RE = re.compile(r"^[A-Za-z0-9_]{1,96}$")
HASH_RE = re.compile(r"^[0-9a-f]{8}$")
# Panel families, in the order a split fills its parts; anything else is "body".
FAMILIES = (("front", re.compile(r"^(hood|bumper_f)", re.I)), ("left", re.compile(r"^door_[fb]l", re.I)),
            ("right", re.compile(r"^door_[fb]r", re.I)), ("rear", re.compile(r"^(trunk|bumper_b|fuel)", re.I)))
FAMILY_ORDER = ("body", "front", "left", "right", "rear")


class PlanError(Exception):
    pass


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def family_of(component: str) -> str:
    for name, rx in FAMILIES:
        if rx.search(component):
            return name
    return "body"


def row_hash(row: dict) -> str:
    key = [row["component"], row["mesh"], row["meshAppearance"], row["chunkMask"], row["transform"],
           row["visualScale"], row["bind"]]
    return hashlib.sha256(json.dumps(key, sort_keys=True).encode()).hexdigest()[:8]


def excluded_tokens(spec: dict) -> list[str]:
    ex = spec["excludeTokens"]
    return [t.lower() for t in ex["contract"] + ex["proposed"]]


def token_hit(text: str, tokens: list[str]) -> str | None:
    low = text.lower()
    for t in tokens:
        if t in low:
            return t
    return None


def refusal(row: dict, tokens: list[str]) -> str | None:
    """Why a survey row never becomes a decal, or None."""
    if row["interior"]:
        return "interior"
    if row["chunkMask"] == "0":
        return "hidden (chunkMask 0)"
    if row["inPlayerAppearance"]:
        return "already on the player car"
    if row["attachHow"] == "none" or not row["attach"]:
        return "no host component on the player appearance"
    if not row["enabled"]:
        return "disabled"
    for text in (os.path.basename(row["mesh"]), row["component"]):
        hit = token_hit(text, tokens)
        if hit:
            return f"excluded token {hit}"
    return None


def split(decals: list[dict], limit: int) -> list[list[dict]]:
    """Whole families packed in order into parts of at most `limit`; a family bigger than the
    limit is cut by count."""
    fams = OrderedDict((f, []) for f in FAMILY_ORDER)
    for d in decals:
        fams[d["family"]].append(d)
    parts, cur = [], []
    for f, items in fams.items():
        while len(items) > limit:
            if cur:
                parts.append(cur)
                cur = []
            parts.append(items[:limit])
            items = items[limit:]
        if not items:
            continue
        if len(cur) + len(items) > limit:
            parts.append(cur)
            cur = []
        cur = cur + items
    if cur:
        parts.append(cur)
    return parts


def plan_model(m: dict, spec: dict, tokens: list[str], refused: dict) -> OrderedDict:
    limit = spec["maxDecalsPerSticker"]
    rows = OrderedDict()   # hash -> decal
    by_app: dict[str, list[str]] = {}
    for row in m["stickers"]:
        why = refusal(row, tokens)
        if why:
            refused[why] = refused.get(why, 0) + 1
            continue
        h = row_hash(row)
        if h in rows:
            raise PlanError(f"{m['key']}: two sticker rows hash to {h}")
        rows[h] = OrderedDict([
            ("id", h), ("record", f"{spec['decalPrefix']}{m['key']}_{h}"), ("component", row["attach"]),
            ("attachHow", row["attachHow"]), ("family", family_of(row["attach"])),
            ("mesh", row["mesh"]), ("meshAppearance", row["meshAppearance"]), ("chunkMask", row["chunkMask"]),
            ("transform", row["transform"]), ("visualScale", row["visualScale"]),
            ("sourceComponent", row["component"]), ("archive", row["archive"]),
        ])
        for a in row["appearances"]:
            by_app.setdefault(a, []).append(h)
    sets: OrderedDict[frozenset, list[str]] = OrderedDict()
    for app in sorted(by_app):
        if app in spec["excludeAppearances"]:
            refused["excluded appearance"] = refused.get("excluded appearance", 0) + 1
            continue
        hit = token_hit(app, tokens)
        if hit:
            refused["excluded appearance"] = refused.get("excluded appearance", 0) + 1
            continue
        if app not in spec["appearances"]:
            raise PlanError(f"{m['key']}: vanilla appearance {app} shows stickers but the spec does not classify it: "
                            "add it to `appearances` (a group) or `excludeAppearances` (a reason)")
        sets.setdefault(frozenset(by_app[app]), []).append(app)
    stickers, numbers, used = [], {}, set()
    for hs, apps in sets.items():
        group = spec["appearances"][apps[0]]
        if group not in spec["groups"]:
            raise PlanError(f"{apps[0]}: group {group!r} is not in the spec's groups")
        numbers[group] = numbers.get(group, 0) + 1
        n = numbers[group]
        base_id = f"st.{m['key']}.{slug(group)}_{n:02d}"
        decals = sorted((rows[h] for h in hs), key=lambda d: (FAMILY_ORDER.index(d["family"]), d["component"], d["id"]))
        parts = [decals] if len(decals) <= limit else split(decals, limit)
        for i, part in enumerate(parts):
            sid = base_id if len(parts) == 1 else f"{base_id}{'abcdefghij'[i]}"
            label = f"{group} {n}"
            if len(parts) > 1:
                fams = [f for f in FAMILY_ORDER if any(d["family"] == f for d in part)]
                label = f"{label}: {' + '.join(fams)}"
            ids = [d["id"] for d in part]
            used.update(ids)
            stickers.append(OrderedDict([
                ("id", sid), ("label", label), ("group", group), ("model", m["record"]),
                ("decals", len(ids)), ("record", spec["stickerPrefix"] + sid.replace(".", "_")),
                ("parts", ids), ("source", apps),
            ]))
    decals = [d for h, d in rows.items() if h in used]
    refused["not shown by a kept appearance"] = refused.get("not shown by a kept appearance", 0) + len(rows) - len(decals)
    hosts = sorted({v["component"] for v in m["attach"].values() if v["component"]})
    return OrderedDict([("key", m["key"]), ("record", m["record"]), ("hosts", hosts),
                        ("decals", decals), ("stickers", stickers)])


def build_plan(survey: dict, spec: dict) -> OrderedDict:
    check_spec(spec)
    if survey.get("schema") != SURVEY_SCHEMA:
        raise PlanError(f"survey schema must be {SURVEY_SCHEMA}")
    tokens = excluded_tokens(spec)
    refused: dict[str, int] = {}
    models = [plan_model(m, spec, tokens, refused) for m in survey["models"]]
    unused = sorted(set(spec["appearances"]) - {a for m in models for s in m["stickers"] for a in s["source"]})
    if unused:
        raise PlanError(f"the spec classifies appearances no kept sticker comes from: {', '.join(unused)}")
    return OrderedDict([
        ("schema", SCHEMA), ("gameVersion", survey.get("gameVersion", "2.50")),
        ("limits", OrderedDict([("maxDecalsPerCar", spec["maxDecalsPerCar"]),
                                ("maxDecalsPerSticker", spec["maxDecalsPerSticker"])])),
        ("prefixes", OrderedDict([("decal", spec["decalPrefix"]), ("sticker", spec["stickerPrefix"])])),
        ("refused", OrderedDict(sorted(refused.items()))),
        ("models", models),
        ("totals", OrderedDict([("stickers", sum(len(m["stickers"]) for m in models)),
                                ("decals", sum(len(m["decals"]) for m in models)),
                                ("modelsWithStickers", sum(1 for m in models if m["stickers"]))])),
    ])


def check_spec(spec: dict) -> None:
    if spec.get("schema") != SPEC_SCHEMA:
        raise PlanError(f"spec schema must be {SPEC_SCHEMA}")
    if not re.fullmatch(r"[a-z0-9_-]{1,64}", spec["resource"]):
        raise PlanError("spec resource must match [a-z0-9_-]{1,64}")
    for k in ("decalPrefix", "stickerPrefix"):
        if not re.fullmatch(r"Vehicle\.o77_[a-z0-9_]+_", spec[k]):
            raise PlanError(f"spec {k} must look like Vehicle.o77_<name>_")
    if spec["decalPrefix"] == spec["stickerPrefix"]:
        raise PlanError("decalPrefix and stickerPrefix must differ")
    if not (1 <= spec["maxDecalsPerSticker"] <= spec["maxDecalsPerCar"] <= MAX_DECALS_PER_TEMPLATE):
        raise PlanError(f"limits must satisfy 1 <= maxDecalsPerSticker <= maxDecalsPerCar <= {MAX_DECALS_PER_TEMPLATE}")
    for need in ("police", "sheriff", "border", "arasaka", "delamain"):
        if need not in [t.lower() for t in spec["excludeTokens"]["contract"]]:
            raise PlanError(f"the contract exclusion {need} is missing from the spec")


def check_plan(plan: dict, spec: dict, survey: dict) -> None:
    """Independent re-check of a plan against the survey and the spec (also run on mutated plans)."""
    tokens = excluded_tokens(spec)
    limit, cap = spec["maxDecalsPerSticker"], spec["maxDecalsPerCar"]
    if plan.get("schema") != SCHEMA:
        raise PlanError("plan schema")
    if limit > cap or cap > MAX_DECALS_PER_TEMPLATE:
        raise PlanError("limits above the engine cap")
    rows_by_model = {m["key"]: {row_hash(r): r for r in m["stickers"]} for m in survey["models"]}
    records = {m["key"]: m["record"] for m in survey["models"]}
    ids, sticker_records, decal_records = set(), set(), set()
    for m in plan["models"]:
        key = m["key"]
        if records.get(key) != m["record"]:
            raise PlanError(f"{key}: unknown model or record {m['record']}")
        survey_rows = rows_by_model[key]
        decals = {}
        for d in m["decals"]:
            h = d["id"]
            if not HASH_RE.match(h) or h in decals:
                raise PlanError(f"{key}: bad or duplicate decal id {h}")
            src = survey_rows.get(h)
            if src is None:
                raise PlanError(f"{key}/{h}: no survey row has this hash (decal edited)")
            why = refusal(src, tokens)
            if why:
                raise PlanError(f"{key}/{h}: refused row in the plan ({why})")
            for field, want in (("mesh", src["mesh"]), ("meshAppearance", src["meshAppearance"]),
                                ("chunkMask", src["chunkMask"]), ("transform", src["transform"]),
                                ("visualScale", src["visualScale"]), ("component", src["attach"])):
                if d[field] != want:
                    raise PlanError(f"{key}/{h}: {field} differs from the survey")
            if d["record"] != f"{spec['decalPrefix']}{key}_{h}" or d["record"] in decal_records:
                raise PlanError(f"{key}/{h}: decal record name {d['record']}")
            if not MESH_RE.match(d["mesh"]):
                raise PlanError(f"{key}/{h}: mesh outside the vanilla vehicle folders: {d['mesh']}")
            if not COMPONENT_RE.match(d["component"]) or d["component"] not in m["hosts"]:
                raise PlanError(f"{key}/{h}: host component {d['component']} is not on the player appearance")
            for text in (d["mesh"], d["component"], d["sourceComponent"]):
                hit = token_hit(os.path.basename(text), tokens)
                if hit:
                    raise PlanError(f"{key}/{h}: excluded token {hit}")
            decal_records.add(d["record"])
            decals[h] = d
        used, seen_sets, labels = set(), set(), set()
        for s in m["stickers"]:
            sid = s["id"]
            if not ID_RE.match(sid) or sid in ids or not sid.startswith(f"st.{key}."):
                raise PlanError(f"{key}: bad or duplicate sticker id {sid}")
            ids.add(sid)
            if s["record"] != spec["stickerPrefix"] + sid.replace(".", "_") or s["record"] in sticker_records:
                raise PlanError(f"{sid}: sticker record name {s['record']}")
            sticker_records.add(s["record"])
            if s["model"] != m["record"]:
                raise PlanError(f"{sid}: model {s['model']} is not {m['record']}")
            if not LABEL_RE.match(s["label"]) or s["label"].lower() in labels:
                raise PlanError(f"{sid}: bad or duplicate label {s['label']!r}")
            labels.add(s["label"].lower())
            if s["group"] not in spec["groups"]:
                raise PlanError(f"{sid}: unknown group {s['group']}")
            for text in (s["label"], sid):
                hit = token_hit(text, tokens)
                if hit:
                    raise PlanError(f"{sid}: excluded token {hit} in the label or id")
            parts = s["parts"]
            if s["decals"] != len(parts) or len(set(parts)) != len(parts):
                raise PlanError(f"{sid}: decals={s['decals']} but {len(parts)} parts ({len(set(parts))} distinct)")
            if not 1 <= len(parts) <= limit:
                raise PlanError(f"{sid}: {len(parts)} decals, outside 1..{limit}")
            for h in parts:
                if h not in decals:
                    raise PlanError(f"{sid}: part {h} is not a decal of {key}")
            fs = frozenset(parts)
            if fs in seen_sets:
                raise PlanError(f"{sid}: same decals as another sticker of {key}")
            seen_sets.add(fs)
            used.update(parts)
            for app in s["source"]:
                if app in spec["excludeAppearances"] or token_hit(app, tokens):
                    raise PlanError(f"{sid}: comes from the excluded appearance {app}")
                if spec["appearances"].get(app) != s["group"]:
                    raise PlanError(f"{sid}: {app} is classified {spec['appearances'].get(app)!r}, not {s['group']!r}")
        if used != set(decals):
            raise PlanError(f"{key}: decals no sticker uses: {sorted(set(decals) - used)}")
    if len(decal_records & sticker_records):
        raise PlanError("a decal record and a sticker record share a name")


def _first(plan, pred):
    for m in plan["models"]:
        for s in m["stickers"]:
            if pred(m, s):
                return m, s
    raise PlanError("mutation found no target")


def _mut_decal_count(p):
    _first(p, lambda m, s: True)[1]["decals"] += 1


def _mut_thirteen(p):
    m = max(p["models"], key=lambda m: len(m["decals"]))
    s = m["stickers"][0]
    s["parts"] = [d["id"] for d in m["decals"]][:13]
    s["decals"] = len(s["parts"])


def _mut_police_mesh(p):
    m = next(m for m in p["models"] if m["decals"])
    d = m["decals"][0]
    d["mesh"] = d["mesh"].replace(".mesh", "_police.mesh")


def _mut_delamain_source(p):
    _first(p, lambda m, s: True)[1]["source"].append("villefort_cortes__basic_delamain_01")


def _mut_arasaka_label(p):
    _first(p, lambda m, s: True)[1]["label"] = "Arasaka 1"


def _mut_duplicate_id(p):
    ss = [s for m in p["models"] for s in m["stickers"] if m["key"] == "thrax"]
    ss[1]["id"] = ss[0]["id"]


def _mut_unknown_group(p):
    _first(p, lambda m, s: True)[1]["group"] = "Corporate"


def _mut_host_missing(p):
    m = next(m for m in p["models"] if m["decals"])
    m["decals"][0]["component"] = "window_f"


def _mut_transform(p):
    m = next(m for m in p["models"] if m["decals"])
    m["decals"][0]["transform"]["positionBits"][2] += 1


def _mut_duplicate_set(p):
    m = next(m for m in p["models"] if len(m["stickers"]) > 1)
    m["stickers"][1]["parts"] = list(m["stickers"][0]["parts"])
    m["stickers"][1]["decals"] = len(m["stickers"][0]["parts"])


def _mut_interior_row(p, survey):
    for sm in survey["models"]:
        for row in sm["stickers"]:
            if row["interior"]:
                m = next(m for m in p["models"] if m["key"] == sm["key"])
                h = row_hash(row)
                m["decals"].append(OrderedDict([("id", h), ("record", f"{p['prefixes']['decal']}{sm['key']}_{h}"),
                                                ("component", row["attach"] or "interior_01"), ("attachHow", "direct"),
                                                ("family", "body"), ("mesh", row["mesh"]),
                                                ("meshAppearance", row["meshAppearance"]), ("chunkMask", row["chunkMask"]),
                                                ("transform", row["transform"]), ("visualScale", row["visualScale"]),
                                                ("sourceComponent", row["component"]), ("archive", row["archive"])]))
                if m["stickers"]:
                    m["stickers"][0]["parts"].append(h)
                    m["stickers"][0]["decals"] += 1
                return
    raise PlanError("no interior row to inject")


def _mut_record_name(p):
    _first(p, lambda m, s: True)[1]["record"] = "Vehicle.v_standard2_archer_hella_player"


def _mut_orphan_decal(p):
    for m in p["models"]:
        for i, s in enumerate(m["stickers"]):
            others = {h for j, x in enumerate(m["stickers"]) if j != i for h in x["parts"]}
            if set(s["parts"]) - others:
                del m["stickers"][i]
                return
    raise PlanError("no sticker owns a decal alone")


MUTATIONS = [
    ("decals field off by one", _mut_decal_count),
    ("more decals than a sticker may carry", _mut_thirteen),
    ("a police mesh", _mut_police_mesh),
    ("a Delamain source appearance", _mut_delamain_source),
    ("an Arasaka label", _mut_arasaka_label),
    ("a duplicate sticker id", _mut_duplicate_id),
    ("an unknown group", _mut_unknown_group),
    ("a host missing from the player appearance", _mut_host_missing),
    ("a transform edited after the survey", _mut_transform),
    ("two stickers with the same decals", _mut_duplicate_set),
    ("an interior row", None),
    ("a sticker record named like a vanilla record", _mut_record_name),
    ("a decal no sticker uses", _mut_orphan_decal),
]


def negative_tests(plan: dict, spec: dict, survey: dict) -> tuple[list[str], int]:
    failures = []
    for name, fn in MUTATIONS:
        p = copy.deepcopy(plan)
        try:
            if fn is None:
                _mut_interior_row(p, survey)
            else:
                fn(p)
        except (PlanError, StopIteration, IndexError) as e:
            failures.append(f"{name}: mutation could not be applied ({e})")
            continue
        try:
            check_plan(p, spec, survey)
        except PlanError:
            continue
        failures.append(f"{name}: accepted")
    return failures, len(MUTATIONS)


def run_checks(plan: dict, spec: dict, survey: dict) -> int:
    check_plan(plan, spec, survey)
    failures, total = negative_tests(plan, spec, survey)
    if failures:
        raise PlanError("negative tests failed:\n  " + "\n  ".join(failures))
    return total


def read(path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--survey", required=True)
    ap.add_argument("--spec", default=str(HERE / "specs" / "lightrp-stickers.json"))
    ap.add_argument("--out", help="write plan.json")
    ap.add_argument("--check", help="re-check an existing plan.json")
    a = ap.parse_args(argv)
    try:
        survey, spec = read(a.survey), read(a.spec)
        if a.check:
            plan = read(a.check)
            check_spec(spec)
        elif a.out:
            plan = build_plan(survey, spec)
        else:
            ap.error("--out or --check is required")
        total = run_checks(plan, spec, survey)
        if a.out:
            Path(a.out).parent.mkdir(parents=True, exist_ok=True)
            Path(a.out).write_text(json.dumps(plan, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
        t = plan["totals"]
        print(f"ST_PLAN_OK models={t['modelsWithStickers']} stickers={t['stickers']} decals={t['decals']} "
              f"negative_tests={total}/{total}" + (f" out={a.out}" if a.out else " (checked)"))
        return 0
    except (PlanError, KeyError, OSError, ValueError) as e:
        print(f"st_plan: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
