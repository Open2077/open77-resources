"""Livery plan: which mask, which components and which reference paint stack per model.

    python lv_plan.py --spec specs/lightrp-liveries.json --game <Cyberpunk 2077> --out <work>/plan.json

Read-only on the game (tweakdb.bin, tweakdb_ep1.bin). For each model of the spec it reads
docs/generated/vehicle-components-dealer-2.50.json and the TweakDB, then picks the
model's own vanilla "full body" unique template: the TwinTone template whose multilayers
cover the car with masks of the model itself (no pattern mask from
visual_customization\\unique_mlmasks, no junk-kit mask), fewest multilayers first. Its
multilayers give the mask (referenced by path, never shipped), the components each one
paints or skips, and the clear-coat layer range; every vanilla setup used over the same
mask and component set is a reference stack for lv_cook.py (layer roles only).

Writes plan.json and prints one line per model. Fails when a record, an
AppearancesToColorTemplate or a flat named by the dealer table is missing from the
TweakDB of this game build.

Trims (`records` in plan.json): the other records of a model's body (the component table's
`trims`, docs/generated/vehicle-components-player-bodies-<ver>.json) take the same liveries when they
point at the same AppearancesToColorTemplate record (our templates are appended to that list,
so their TweakDB has them) and their appearance carries every decal panel with the same mesh
and binding. The others are listed under `trimsRefused` with the reason.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lv_common import BS, MAX_DECALS_PER_TEMPLATE, REPO, write_json  # noqa: E402

import tdb  # noqa: E402  (scripts/vehicle-kit/inventory, read-only)

DEALER = REPO / 'docs/generated/vehicle-components-dealer-2.50.json'
SKIP_FLAGS = {'shadow', 'glass', 'light', 'wheel', 'tire', 'rim', 'placeable', 'widget', 'decal',
              'part:interior', 'part:chassis', 'part:engine', 'part:exhaust', 'part:fuel', 'excludedFromCustomization'}
PAINT_FLAGS = {'twintoneMultilayerTarget', 'part:body', 'part:door', 'part:hood', 'part:trunk', 'part:roof', 'bumper'}


def rid_of(name):
    """TweakDB id of a record name, or of `<0x..........>`: a record whose name the names table
    lacks (vehicle_inventory.py prints the id itself)."""
    hashed = re.fullmatch(r'<0x([0-9A-Fa-f]{10,16})>', name)
    return int(hashed.group(1), 16) & tdb.ID_MASK if hashed else tdb.tdbid(name)


def mask_ok(path):
    p = path.lower()
    return bool(p) and 'visual_customization' + BS + 'unique_mlmasks' not in p and 'junk' not in p


def target_components(model):
    """Painted exterior panels a decal may be attached to (player appearance only)."""
    out = []
    for c in model['components']:
        if not c.get('inPlayerAppearance') or not c.get('mesh'):
            continue
        flags = set(c.get('flags') or [])
        if c['type'] not in ('entPhysicalMeshComponent', 'entMeshComponent'):
            continue
        if flags & SKIP_FLAGS or not flags & PAINT_FLAGS:
            continue
        if '__int01' in c['mesh']:
            continue
        out.append(c['name'])
    return sorted(out)


def kit_hidden(spec_path, spec):
    """record -> components a body kit of this server can hide (the spec's kitFits files)."""
    hidden = collections.defaultdict(set)
    for name in spec.get('kitFits', []):
        fits = json.loads((spec_path.parent / name).read_text(encoding='utf-8'))
        for part in fits.get('parts', {}).values():
            for record, fit in (part.get('fit') or {}).items():
                hidden[record].update(fit.get('hide') or [])
    return hidden


def decal_hosts(model, targets, protected):
    """target -> the target whose decal carries it, so no template exceeds MAX_DECALS_PER_TEMPLATE.

    A model at or under the cap keeps one decal per target. Above it, whole tiers are applied
    in order until the count fits:
      1. a plain entMeshComponent hard-bound under a target (directly or through non-target
         components, e.g. a door stripe bound to the door's shadow mesh) joins that target;
      2. targets hard-bound to the same vehicle_slots slot join one of them (the name without
         'player' first, then the first by name).
    The folded geometry rides the host's frame, which carries it rigidly. A component a kit
    can hide (`protected`) is never folded and never receives another, or its artwork would
    float where the hidden part was. Fails when the cap still cannot be met.
    """
    host = {t: t for t in targets}
    if len(targets) <= MAX_DECALS_PER_TEMPLATE:
        return host
    comps = {c['name']: c for c in model['components']}
    tset = set(targets)

    def target_parent(name):
        seen, p = set(), comps[name].get('parent') or {}
        while p.get('bindName') and p['bindName'] != 'vehicle_slots' and p['bindName'] not in seen:
            b = p['bindName']
            seen.add(b)
            if b in tset:
                return b
            if b not in comps:
                return None
            p = comps[b].get('parent') or {}
        return None

    def root(name):
        while host[name] != name:
            name = host[name]
        return name

    def count():
        return len({root(t) for t in targets})

    for name in sorted(targets):
        par = target_parent(name)
        if comps[name]['type'] == 'entMeshComponent' and par and name not in protected and root(par) not in protected:
            host[name] = par
    if count() > MAX_DECALS_PER_TEMPLATE:
        slots = collections.defaultdict(list)
        for name in sorted(targets):
            p = comps[name].get('parent') or {}
            if root(name) == name and name not in protected and p.get('bindName') == 'vehicle_slots':
                slots[p.get('slotName')].append(name)
        for names in slots.values():
            keep = sorted(names, key=lambda x: ('player' in x, x))[0]
            for name in names:
                if name != keep:
                    host[name] = keep
    flat = {t: root(t) for t in targets}
    if len(set(flat.values())) > MAX_DECALS_PER_TEMPLATE:
        raise SystemExit(f'lv_plan: {model["key"]}: {len(set(flat.values()))} decal panels after folding, '
                         f'over the engine cap of {MAX_DECALS_PER_TEMPLATE} per template')
    return flat


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spec', required=True, type=Path)
    ap.add_argument('--game', required=True)
    ap.add_argument('--dealer', type=Path, default=DEALER)
    ap.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()
    spec = json.loads(a.spec.read_text(encoding='utf-8'))
    dealer = {m['key']: m for m in json.loads(a.dealer.read_text(encoding='utf-8'))['models']}
    hidden_by_kits = kit_hidden(a.spec, spec)
    cache = os.path.join(a.game, 'r6', 'cache')
    db = tdb.LayeredTweakDB([os.path.join(cache, 'tweakdb.bin'), os.path.join(cache, 'tweakdb_ep1.bin')])

    def need(name, what):
        rid = rid_of(name)
        if db.record_type(rid) is None:
            raise SystemExit(f'lv_plan: {what} {name} is not a TweakDB record on this game build')
        return rid

    models, files = [], set(spec['finishes'].values())
    for key in spec['models']:
        if key in spec.get('unsupported', {}):
            raise SystemExit(f'lv_plan: {key} is both a model and unsupported')
        m = dealer.get(key) or sys.exit(f'lv_plan: {key} is not in {a.dealer.name}')
        rec = need(m['record'], 'record')
        a2c_name = m['twintone']['appearancesToColorTemplate']
        a2c = need(a2c_name, 'AppearancesToColorTemplate')
        if (db.prop(rec, 'appearancesToColorTemplate', 0) or 0) & tdb.ID_MASK != a2c & tdb.ID_MASK:
            raise SystemExit(f'lv_plan: {m["record"]}.appearancesToColorTemplate is not {a2c_name}')
        if not db.prop(rec, 'hasUniqueCustomization', False) and not m['tweakdb'].get('hasUniqueCustomization'):
            raise SystemExit(f'lv_plan: {key} has hasUniqueCustomization = false (list it under unsupported)')
        live = {x & tdb.ID_MASK for x in db.prop(a2c, 'colorTemplates', [])}
        profiles = [p for p in m['twintone']['profiles'] if p.get('pattern') and p.get('multilayerDetails')]
        for p in profiles:
            if rid_of(p['id']) & tdb.ID_MASK not in live:
                raise SystemExit(f'lv_plan: {p["id"]} is no longer in {a2c_name}')
        # Setups used over each (mask, affected, excluded) set: the reference stacks.
        usage = collections.defaultdict(list)
        for p in profiles:
            for ml in p['multilayerDetails']:
                usage[(ml['mlmask'], tuple(ml['affected']), tuple(ml['excluded']))].append(ml['mlsetup'])
        candidates = []
        for p in profiles:
            mls = p['multilayerDetails']
            if not all(mask_ok(ml['mlmask']) for ml in mls):
                continue
            if any(ml['onlyFor'] for ml in mls):
                continue
            # Must paint every panel: one multilayer with no affected list, plus any
            # multilayers covering what that one excludes besides the wheels.
            if not any(not ml['affected'] for ml in mls):
                continue
            pop = sum(len(usage[(ml['mlmask'], tuple(ml['affected']), tuple(ml['excluded']))]) for ml in mls)
            candidates.append((len(mls), -pop, p['id'], p))
        if not candidates:
            raise SystemExit(f'lv_plan: {key}: no vanilla full-body unique template with the model\'s own masks')
        candidates.sort()
        ref = candidates[0][3]
        layers = []
        for ml in ref['multilayerDetails']:
            mid = need(ml['id'], 'multilayer')
            sig = (ml['mlmask'], tuple(ml['affected']), tuple(ml['excluded']))
            setups = sorted(set(usage[sig]), key=lambda s: (s != ml['mlsetup'], s))
            files.update(setups)
            layers.append({
                'source': ml['id'], 'mask': ml['mlmask'], 'affected': ml['affected'], 'excluded': ml['excluded'],
                'coatLayerMin': float(db.prop(mid, 'coatLayerMin', -1.0)), 'coatLayerMax': float(db.prop(mid, 'coatLayerMax', -1.0)),
                'referenceSetups': setups,
            })
        targets = target_components(m)
        hosts = decal_hosts(m, targets, hidden_by_kits.get(m['record'], set()))
        folded = {t: h for t, h in hosts.items() if t != h}
        records, refused = [m['record']], []
        for t in m.get('trims') or []:
            if t['record'] == m['record']:
                continue
            trid = tdb.tdbid(t['record'])
            why = None
            if db.record_type(trid) is None:
                why = 'not a TweakDB record on this build'
            elif (db.prop(trid, 'appearancesToColorTemplate', 0) or 0) & tdb.ID_MASK != a2c & tdb.ID_MASK:
                why = f'another AppearancesToColorTemplate than {a2c_name}'
            elif not t.get('found'):
                why = f'appearance {t.get("appearance")} not read'
            else:
                missing = [x for x in targets if x not in t['components']]
                differ = [x for x in targets if x in t.get('differs', [])]
                if missing:
                    why = f'appearance {t["appearance"]} lacks {", ".join(missing)}'
                elif differ:
                    why = f'appearance {t["appearance"]} has another {", ".join(differ)}'
            if why:
                refused.append({'record': t['record'], 'reason': why})
            else:
                records.append(t['record'])
        models.append({
            'key': key, 'label': m['label'], 'record': m['record'], 'twintone': m['tweakdb']['twintoneModelName'],
            'appearancesToColorTemplate': a2c_name, 'playerAppearance': m['playerAppearance'],
            'reference': ref['id'], 'multilayers': layers, 'targets': targets, 'decalHosts': folded,
            **({'records': records} if len(records) > 1 else {}),
            **({'trimsRefused': refused} if refused else {}),
        })
        print(f'{key:9} ref {ref["id"]}  multilayers {len(layers)}  masks {[l["mask"].split(BS)[-1] for l in layers]}  '
              f'coat {[(l["coatLayerMin"], l["coatLayerMax"]) for l in layers]}  refs {[len(l["referenceSetups"]) for l in layers]}  '
              f'targets {len(targets)}  decal panels {len(set(hosts.values()))}  folded {folded}')
    plan = {'schema': 'open77.vehicle-liveries.plan/1', 'spec': str(a.spec), 'models': models,
            'gameFiles': sorted(files)}
    write_json(a.out, plan)
    print(f'LV_PLAN_OK models={len(models)} gameFiles={len(files)}')


if __name__ == '__main__':
    main()
