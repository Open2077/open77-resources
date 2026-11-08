"""Decal meshes of the liveries: our own grid, laid on each model's painted panels.

    uv run --no-project --with pillow --with numpy python -I lv_decals.py --plan <plan.json>
        --spec <spec.json> --measure-work <body-kit measure cache> --mesh-json <dir>
        --game-json <dir> --art <art dir> --out <dir> [--spacing 0.02] [--offset 0.004]

The geometry is MEASURED, not copied: three orthographic ray grids (the car seen from its
left, its right and from above, one ray every --spacing metres) are cast on the exterior
of the model's player appearance as the game draws it (lv_surface.py: the chunks the
appearance's chunkMask leaves visible, decal shells left out). Each grid point that lands
on the multilayered paint of a painted panel (plan.json `targets`; glass, lights, rubber
and hidden chunks of the same component are not targets, only occluders) becomes a
vertex of a regular quad grid, pushed --offset metres out
along the panel normal, then expressed in the frame of the component it landed on: a
VehicleDecalAttachment draws its entity in that component's frame, as the vanilla
customization decals do (their meshes sit ~4 mm outside the panel, in the panel's own
mesh frame). Quads never bridge two components, a depth step, or a surface that faces
another view, so each panel gets one continuous, non-overlapping skin per view.

UVs come from the vehicle frame (lv_common.REGIONS): the same atlas fits every model and
the artwork runs continuously over doors, body and lids.

Writes <out>/<model>/<component>.glb and <out>/decals.json (per model: bounds,
components, and which design covers which component). The previews come from
lv_composite.py check, which renders these meshes over the composited multilayer.

Until 2026-11-06 the grids were cast on body_measure.assemble(), every LOD_1 submesh of
every component: a decal could land on a hidden chunk, on a light cover or on the glass.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lv_common import (ATLAS_H, ATLAS_W, REPO, inverse_apply, inverse_rotate,  # noqa: E402
                       region_box, unit, write_glb, write_json)
from lv_surface import AXIS, KIND_PAINT, face_normals, hit_points, model_surface, raster  # noqa: E402
from lv_surface import VIEWS as RASTER_VIEWS  # noqa: E402

DEALER = REPO / 'docs/generated/vehicle-components-dealer-2.50.json'
VIEWS = {
    #        camera dir (towards the viewer), +u dir, +v dir; the raster is lv_surface's
    'left': ((-1.0, 0.0, 0.0), (0.0, -1.0, 0.0), (0.0, 0.0, -1.0)),
    'right': ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, -1.0)),
    'top': ((0.0, 0.0, 1.0), (0.0, -1.0, 0.0), (-1.0, 0.0, 0.0)),
}
MIN_FACING = 0.45            # |n . camera| below this: the panel faces another view
CENTRE_TOLERANCE = 0.01      # a quad's centre must hit its panel within 1 cm of the corners' depth


def build_model(m, model_plan, work, meshjson, gamejson, spacing, offset, out_dir):
    surface = model_surface(m, model_plan, work, meshjson, [gamejson])
    frames = surface.frames
    names = surface.names
    tris = surface.tris.astype(np.float64)
    comp = surface.comp.astype(np.int64)
    targets = set(model_plan['targets'])
    hosts = model_plan.get('decalHosts') or {}
    # a triangle is a target when it is visible multilayered paint of a target component
    tri_tgt = np.array([n in targets for n in names])[comp] & (surface.kind == KIND_PAINT)
    missing = sorted(targets - {names[c] for c in np.unique(comp[tri_tgt])})
    tv = tris[tri_tgt].reshape(-1, 3)
    if not len(tv):
        raise SystemExit(f'lv_decals: {m["key"]}: no target panel geometry (extract the body-kit cache first)')
    bounds = {
        'x': [float(tv[:, 0].min()), float(tv[:, 0].max())],
        'y': [float(tv[:, 1].min()), float(tv[:, 1].max())],
        'zlo': float(np.percentile(tv[:, 2], 2)), 'zhi': float(tv[:, 2].max()),
    }
    lo = tris.reshape(-1, 3).min(0) - spacing
    hi = tris.reshape(-1, 3).max(0) + spacing
    fn = face_normals(tris)

    L = bounds['y'][1] - bounds['y'][0]
    W = bounds['x'][1] - bounds['x'][0]
    H = bounds['zhi'] - bounds['zlo']

    def uv_of(view, p):
        x0, y0, x1, y1 = region_box(view)
        fu = (bounds['y'][1] - p[..., 1]) / L if view != 'right' else (p[..., 1] - bounds['y'][0]) / L
        fv = (bounds['zhi'] - p[..., 2]) / H if view != 'top' else (bounds['x'][1] - p[..., 0]) / W
        fu, fv = fu.clip(0, 1), fv.clip(0, 1)
        return np.stack([(x0 + fu * (x1 - x0)) / ATLAS_W, (y0 + fv * (y1 - y0)) / ATLAS_H], -1)

    def view_grid(view, step):
        cam = np.array(VIEWS[view][0])
        owner, zbuf, geo, _ = raster(tris, view, step, lo, hi)
        p = hit_points(view, zbuf, geo, lo, step)
        valid = owner >= 0
        ow = owner.clip(0)
        n = fn[ow]
        facing = (n * cam).sum(-1)
        n = np.where(facing[..., None] < 0, -n, n)
        facing = np.abs(facing)
        cidx = np.where(valid, comp[ow], -1)
        is_tgt = valid & tri_tgt[ow]
        good = is_tgt & (facing >= MIN_FACING)
        if view != 'top':
            good &= np.abs(n[..., 0]) >= np.abs(n[..., 2])
        else:
            good &= n[..., 2] > np.abs(n[..., 0])
        return {'cidx': cidx, 'good': good, 'n': n, 'uv': uv_of(view, p), 'p': p, 'zbuf': zbuf}

    meshes = {}      # component -> lists
    for view, (cam, udir, vdir) in VIEWS.items():
        g = view_grid(view, spacing)
        zbuf, p, n, cidx, good, uv = g['zbuf'], g['p'], g['n'], g['cidx'], g['good'], g['uv']
        cam_v = np.array(cam)
        na, nb = good.shape
        g00, g10, g01, g11 = good[:-1, :-1], good[1:, :-1], good[:-1, 1:], good[1:, 1:]
        c00, c10, c01, c11 = cidx[:-1, :-1], cidx[1:, :-1], cidx[:-1, 1:], cidx[1:, 1:]
        z = zbuf
        zs = np.stack([z[:-1, :-1], z[1:, :-1], z[:-1, 1:], z[1:, 1:]], 0)
        with np.errstate(invalid='ignore'):
            spread = np.nan_to_num(zs.max(0) - zs.min(0), nan=1e9, posinf=1e9)
        flat_ok = spread <= 2.5 * spacing
        # The quad's centre, cast on a grid shifted by half a cell, must land on the same panel
        # at the corners' depth: four corners on the bars of a roof rack must not bridge the gap.
        A, B = AXIS[RASTER_VIEWS[view][0]], AXIS[RASTER_VIEWS[view][1]]
        lo_c = lo.copy()
        lo_c[A] += spacing / 2
        lo_c[B] += spacing / 2
        own_c, z_c, _geo_c, _ = raster(tris, view, spacing, lo_c, hi)
        own_c, z_c = own_c[:na - 1, :nb - 1], z_c[:na - 1, :nb - 1]
        hit_c = own_c >= 0
        c_c = np.where(hit_c, comp[own_c.clip(0)], -1)
        with np.errstate(invalid='ignore'):
            centre_ok = hit_c & tri_tgt[own_c.clip(0)] & (c_c == c00) & (np.abs(z_c - zs.mean(0)) <= CENTRE_TOLERANCE)
        quad = g00 & g10 & g01 & g11 & (c00 == c10) & (c00 == c01) & (c00 == c11) & flat_ok & centre_ok
        for ci in np.unique(c00[quad]):
            # A panel folded into its host (plan decalHosts: a stripe into its door) is meshed
            # as before, but written in the host's frame and into the host's decal.
            part = names[ci]
            name = hosts.get(part, part)
            qa, qb = np.nonzero(quad & (c00 == ci))
            used = np.zeros((na, nb), bool)
            for da, db in ((0, 0), (1, 0), (0, 1), (1, 1)):
                used[qa + da, qb + db] = True
            ua, ub = np.nonzero(used)
            vid = np.full((na, nb), -1, np.int64)
            mesh = meshes.setdefault(name, {'pos': [], 'nor': [], 'tan': [], 'uv': [], 'idx': [], 'views': {}, 'parts': set()})
            mesh['parts'].add(part)
            base = len(mesh['pos'])
            vid[ua, ub] = base + np.arange(len(ua))
            tf = frames[name]
            udir_v = np.array(udir)
            vdir_v = np.array(vdir)
            for a_, b_ in zip(ua.tolist(), ub.tolist()):
                nn = n[a_, b_]
                wp = p[a_, b_] + nn * offset
                mesh['pos'].append(tuple(inverse_apply(tf, tuple(wp))))
                ln = unit(inverse_rotate(tf, tuple(nn)))
                mesh['nor'].append(ln)
                t = udir_v - nn * float(udir_v @ nn)
                t = t / (np.linalg.norm(t) or 1.0)
                hand = 1.0 if float(np.cross(nn, t) @ vdir_v) >= 0 else -1.0
                lt = unit(inverse_rotate(tf, tuple(t)))
                mesh['tan'].append(lt + (hand,))
                mesh['uv'].append(tuple(float(x) for x in uv[a_, b_]))
            i00, i10, i01, i11 = vid[qa, qb], vid[qa + 1, qb], vid[qa, qb + 1], vid[qa + 1, qb + 1]
            # Winding: the geometric normal must face the camera (outward).
            pa0 = p[qa, qb]; pa1 = p[qa + 1, qb]; pa2 = p[qa, qb + 1]
            gn = np.cross(pa1 - pa0, pa2 - pa0)
            flip = (gn * cam_v).sum(-1) < 0
            tri1 = np.where(flip[:, None], np.stack([i00, i01, i10], 1), np.stack([i00, i10, i01], 1))
            tri2 = np.where(flip[:, None], np.stack([i10, i01, i11], 1), np.stack([i10, i11, i01], 1))
            mesh['idx'].extend(np.concatenate([tri1, tri2], 1).reshape(-1).tolist())
            mesh['views'][view] = mesh['views'].get(view, 0) + int(len(qa)) * 2
    out = {'key': m['key'], 'bounds': bounds, 'missingTargets': missing, 'components': {}}
    mdir = out_dir / m['key']
    mdir.mkdir(parents=True, exist_ok=True)
    for name, mesh in sorted(meshes.items()):
        if len(mesh['idx']) < 6:
            continue
        glb = mdir / f'{name}.glb'
        write_glb(glb, mesh['pos'], mesh['nor'], mesh['tan'], mesh['uv'], mesh['idx'])
        pos = np.array(mesh['pos'])
        uvs = np.array(mesh['uv'])
        out['components'][name] = {
            'glb': str(glb), 'vertices': len(mesh['pos']), 'triangles': len(mesh['idx']) // 3, 'views': mesh['views'],
            'parts': sorted(mesh['parts']),
            'bounds': [pos.min(0).round(4).tolist(), pos.max(0).round(4).tolist()],
            'uvSamples': uvs[:: max(1, len(uvs) // 4000)].round(5).tolist(),
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--plan', required=True, type=Path)
    ap.add_argument('--spec', required=True, type=Path)
    ap.add_argument('--measure-work', required=True, type=Path)
    ap.add_argument('--mesh-json', required=True, type=Path, help='WolvenKit JSON of the raw .mesh files')
    ap.add_argument('--game-json', required=True, type=Path, help='WolvenKit JSON of the .mi chains (work/game/json)')
    ap.add_argument('--art', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--dealer', type=Path, default=DEALER)
    ap.add_argument('--spacing', type=float, default=0.02)
    ap.add_argument('--offset', type=float, default=0.004)
    ap.add_argument('--min-coverage', type=int, default=6, help='covered UV samples a component needs to get a decal')
    ap.add_argument('--only', default='')
    a = ap.parse_args()
    plan = json.loads(a.plan.read_text(encoding='utf-8'))
    spec = json.loads(a.spec.read_text(encoding='utf-8'))
    dealer = {m['key']: m for m in json.loads(a.dealer.read_text(encoding='utf-8'))['models']}
    atlases = {}
    for dsg in spec['designs']:
        atlases[dsg['id']] = np.array(Image.open(a.art / f"{dsg['id']}_d.png").getchannel('A'), np.float32)
    result = {'schema': 'open77.vehicle-liveries.decals/1', 'spacing': a.spacing, 'offset': a.offset, 'models': {}}
    for mp in plan['models']:
        if a.only and mp['key'] not in a.only.split(','):
            continue
        out = build_model(dealer[mp['key']], mp, a.measure_work, a.mesh_json, a.game_json, a.spacing, a.offset, a.out)
        cover = {}
        for dsg in spec['designs']:
            alpha = atlases[dsg['id']]
            comps = []
            for name, c in out['components'].items():
                uv = np.array(c['uvSamples'])
                px = (uv[:, 0] * ATLAS_W).astype(int).clip(0, ATLAS_W - 1)
                py = (uv[:, 1] * ATLAS_H).astype(int).clip(0, ATLAS_H - 1)
                if int((alpha[py, px] > 8).sum()) >= a.min_coverage:
                    comps.append(name)
            cover[dsg['id']] = comps
        out['designs'] = cover
        for c in out['components'].values():
            c.pop('uvSamples')
        result['models'][mp['key']] = out
        tri = sum(c['triangles'] for c in out['components'].values())
        print(f"{mp['key']:9} decal components {len(out['components'])} triangles {tri} "
              f"missing targets {out['missingTargets']} bounds y {out['bounds']['y'][0]:.2f}..{out['bounds']['y'][1]:.2f} "
              f"z {out['bounds']['zlo']:.2f}..{out['bounds']['zhi']:.2f}")
    write_json(a.out / 'decals.json', result)
    print(f'LV_DECALS_OK models={len(result["models"])}')


if __name__ == '__main__':
    main()
