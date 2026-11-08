"""What the game composites: the multilayer paint of a livery and its decals, offline.

    uv run --no-project --with pillow --with numpy python -I lv_composite.py <command> --cfg <composite.json>

    inputs  which mesh and mltemplate files the two other commands read -> inputs.json
    roles   the vanilla reference stacks against the factory TwinTone mask: which layer of
            each stack paints the body, which is trim, which is grime -> layer-roles.json
            (read by lv_cook.py prepare to give every layer its role)
    check   our generated stacks and decals: coverage table, build assertions, previews

Why it exists. The first in-game look (2026-11-06, revision 66ea08e0cd1f) showed cars the
old preview never showed: it painted every panel in the design's primary and laid the
artwork on top. The game does something else, and this module reproduces it:

  1. Multilayer. A paint chunk's colour is its .mlsetup's layers blended in order over the
     model's .mlmask: layer 0 everywhere, then each layer i over the result, weighted by
     mask_i(uv0) * opacity_i (a lerp). The vanilla mask (exported to PNG layers by WolvenKit,
     never shipped) is sampled at the UV0 of every visible paint texel of the player
     appearance; a layer's colour is its mltemplate's colorScale entry (linear RGB). The
     template's own albedo texture and the microblend are not modelled.
  2. Decals. Our decal meshes (the glb the archive ships) are drawn over the body where they
     are not behind it, with the design atlas as colour and, as opacity, either the atlas
     alpha ('mask') or 1 ('opaque': what a decal material without a working alpha draws).
  3. The factory reference. Each model's TwinTone generic mask
     (TweakDB genericCustomizationMask, a UV0 texture, never shipped) is how the game itself
     splits a player car between colours: mid grey = main colour, white = secondary colour,
     black = left to the vanilla material (sills, lower bumpers, inner arches, interior). It
     defines the painted body.

Five orthographic views (left, right, top, front, rear) at --spacing; each visible texel
counts once, so shares are shares of what a viewer sees, not of UV space. A texel's winning
layer is the one contributing most to its colour: c_i = w_i * prod_{j>i} (1 - w_j).

Build assertions (check):
  - primary share: of the painted body (visible texels of the target panels, outside the
    TweakDB excludedComponentsGeneric, where the generic mask paints), the layers carrying
    the design's paint must win at least minPrimary, for every design and model;
  - trim recoloured: on the body texels the generic mask leaves to the vanilla material
    (sills, lower bumpers, arches), the share our primary/secondary layers win may exceed
    the share the reference's own paint layers win there by at most maxTrimRecolouredExcess
    (the painted-body share cannot see this: those texels are outside it);
  - other multilayers (semimaru rims, maimai's second exterior mask): the same primary
    share on their own texels, asserted only where the generic mask grounds them;
  - decal placement, in the view each decal face was laid from: every decal component must
    be a component of the player appearance with visible paint, and each decal entity must
    be in front of its own panel (minDecalVisible), on that panel (minDecalOnComponent), and
    not float more than 2 cm off the body (maxDecalFloating).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lv_common import ATLAS_H, ATLAS_W, BS, cv, flat_name, read_json, write_json  # noqa: E402
from lv_surface import (KIND_GLASS, KIND_LIGHT, KIND_ML_OTHER, KIND_OTHER, KIND_PAINT, VIEWS, _quat_matrix,  # noqa: E402
                        app_components, face_normals, mesh_json_path, mesh_materials, model_surface, raster,
                        read_glb_lod1, to_image)

import body_measure  # noqa: E402  (read-only reuse; lv_common puts ../blender on sys.path)

DEALER = Path(__file__).resolve().parents[3] / 'docs/generated/vehicle-components-dealer-2.50.json'
RENDER_VIEWS = ('left', 'right', 'top', 'front', 'rear')
AUTHOR_VIEWS = ('left', 'right', 'top')      # the views lv_decals.py lays the grids from
LIGHT = np.array([-0.35, 0.45, 0.82]) / np.linalg.norm([-0.35, 0.45, 0.82])
DECAL_BEHIND = 0.003         # a decal up to 3 mm behind the body still draws (depth bias)
DECAL_FLOAT = 0.02           # more than 2 cm in front of the body: floating
DEFAULT_LIMITS = {'minPrimary': 0.85, 'maxTrimRecolouredExcess': 0.05, 'minDecalVisible': 0.85,
                  'minDecalOnComponent': 0.9, 'maxDecalFloating': 0.03}   # build-liveries.ps1 passes its own
DARK_LUMINANCE = 0.03        # linear luminance under this (about sRGB 48/255): reads as black
GRIME = ('\\grunge\\', '\\dust', 'dirt', '\\ground\\', 'rust', 'iron_old', 'damp', 'mud', 'soot', 'moss', 'leak',
         'graffiti', 'burnt', 'stain')
GENERIC_NONE, GENERIC_MAIN, GENERIC_SECONDARY = 0, 1, 2
KIND_COLOURS = {KIND_GLASS: (0.05, 0.07, 0.09), KIND_LIGHT: (0.55, 0.25, 0.10), KIND_ML_OTHER: (0.10, 0.10, 0.11),
                KIND_OTHER: (0.06, 0.06, 0.06)}
LAYER_COLOURS = [(230, 25, 75), (60, 180, 75), (255, 225, 25), (0, 130, 200), (245, 130, 48), (145, 30, 180),
                 (70, 240, 240), (240, 50, 230), (210, 245, 60), (250, 190, 212), (0, 128, 128), (220, 190, 255),
                 (170, 110, 40), (255, 250, 200), (128, 0, 0), (170, 255, 195), (128, 128, 0), (255, 215, 180),
                 (0, 0, 128), (128, 128, 128)]


def fail(msg):
    raise SystemExit(f'lv_composite: {msg}')


def is_grime(path):
    p = (path or '').lower()
    return any(g in p for g in GRIME)


def roots_of(cfg):
    g = cfg['gameJson']
    return g if isinstance(g, list) else [g]


def find_json(roots, depot):
    """A serialized game file: <root>/<flat name>.json (the build's layout)."""
    for r in roots:
        p = Path(r) / (flat_name(depot) + '.json')
        if p.exists():
            return p
    fail(f'{depot} is not extracted (looked in {", ".join(str(r) for r in roots)})')


def setup_layers(doc):
    return doc['Data']['RootChunk']['layers'] if 'Data' in doc else doc['layers']


# --------------------------------------------------------------------------- inputs
class Masks:
    """A .mlmask exported by WolvenKit: <root>/<flat depot>/<stem>.masklist + <stem>_layers/*.png."""

    def __init__(self, root, depot):
        stem_ = depot.split(BS)[-1][:-len('.mlmask')]
        d = Path(root) / flat_name(depot)
        lst = d / f'{stem_}.masklist'
        if not lst.exists():
            fail(f'mask {depot} is not exported ({lst} missing)')
        files = [ln.strip().replace(BS, '/') for ln in lst.read_text(encoding='utf-8').splitlines() if ln.strip()]
        self.depot = depot
        self.layers = [np.asarray(Image.open(d / f).convert('L'), np.float32) / 255.0 for f in files]

    def sample(self, uv):
        """Bilinear, wrapped: (K, 2) uv -> (K, L) mask values (layer 0 is 1 everywhere)."""
        out = np.empty((len(uv), len(self.layers)), np.float32)
        u = np.mod(uv[:, 0], 1.0)
        v = np.mod(uv[:, 1], 1.0)
        out[:, 0] = 1.0
        for i, m in enumerate(self.layers[1:], 1):
            h, w = m.shape
            x = u * w - 0.5
            y = v * h - 0.5
            x0 = np.floor(x).astype(np.int64)
            y0 = np.floor(y).astype(np.int64)
            fx = (x - x0).astype(np.float32)
            fy = (y - y0).astype(np.float32)
            x0m, x1m = x0 % w, (x0 + 1) % w
            y0m, y1m = y0 % h, (y0 + 1) % h
            top = m[y0m, x0m] * (1 - fx) + m[y0m, x1m] * fx
            bot = m[y1m, x0m] * (1 - fx) + m[y1m, x1m] * fx
            out[:, i] = top * (1 - fy) + bot * fy
        return out


def generic_classes(path, uv):
    """TwinTone generic mask (PNG exported by WolvenKit) at uv0, nearest: 0 none, 1 main, 2 secondary."""
    img = np.asarray(Image.open(path).convert('L'), np.float32) / 255.0
    h, w = img.shape
    px = (np.mod(uv[:, 0], 1.0) * w).astype(np.int64).clip(0, w - 1)
    py = (np.mod(uv[:, 1], 1.0) * h).astype(np.int64).clip(0, h - 1)
    v = img[py, px]
    return np.where(v < 0.25, GENERIC_NONE, np.where(v < 0.75, GENERIC_MAIN, GENERIC_SECONDARY))


class Palettes:
    def __init__(self, roots):
        self.roots = roots
        self.cache = {}

    def colour(self, template, key):
        if template not in self.cache:
            doc = read_json(find_json(self.roots, template))['Data']['RootChunk']
            self.cache[template] = {c['n']['$value']: tuple(c['v']['Elements']) for c in doc['overrides']['colorScale']}
        pal = self.cache[template]
        if key in pal:
            return np.array(pal[key], np.float32)
        return np.array((0.18, 0.18, 0.18), np.float32)      # 'null_null' and unknown keys: neutral grey


# --------------------------------------------------------------------------- compositing
def weights(mvals, layers):
    """(K, L) mask values, layer list -> (K, n) blend weights w_i = mask_i * opacity_i."""
    n = min(mvals.shape[1], len(layers))
    op = np.array([float(l['opacity']) for l in layers[:n]], np.float32)
    w = mvals[:, :n] * op[None, :]
    w[:, 0] = op[0]
    return w.clip(0, 1)


def contributions(w):
    """c_i = w_i * prod_{j>i} (1 - w_j): the share of layer i in the final colour."""
    k, n = w.shape
    keep = np.ones(k, np.float32)
    c = np.zeros((k, n), np.float32)
    for i in range(n - 1, -1, -1):
        c[:, i] = w[:, i] * keep
        keep = keep * (1 - w[:, i])
    return c


def blend(w, colours):
    """Sequential lerp: result = lerp(result, colour_i, w_i). -> rgb (K, 3), winner (K,)."""
    rgb = np.zeros((w.shape[0], 3), np.float32)
    for i in range(w.shape[1]):
        rgb = rgb * (1 - w[:, i:i + 1]) + colours[i][None, :] * w[:, i:i + 1]
    return rgb, contributions(w).argmax(1)


def applicable(multilayers, comp):
    """The multilayer painting a component: the last one that applies (an empty 'affected'
    list means every component); the later entries of a template are the specific ones
    (maimai: body, then bumpers/hood/trunk; semimaru: body, then rims)."""
    for i in range(len(multilayers) - 1, -1, -1):
        ml = multilayers[i]
        if (not ml['affected'] or comp in ml['affected']) and comp not in ml['excluded']:
            return i
    return -1


def without_grime(layers):
    out = []
    for l in layers:
        if is_grime(cv(l['material'])):
            l = dict(l)
            l['opacity'] = 0
        out.append(l)
    return out


# --------------------------------------------------------------------------- views
class ModelViews:
    """The five rasterized views of one model's visible exterior, with, per paint texel, the
    multilayer that paints it, its mask samples and its generic-mask class."""

    def __init__(self, surface, model, model_plan, masks_root, generic_png, spacing):
        self.s = surface
        self.spacing = spacing
        tris = surface.tris
        self.lo = tris.reshape(-1, 3).min(0) - 2 * spacing
        self.hi = tris.reshape(-1, 3).max(0) + 2 * spacing
        self.fn = face_normals(tris)
        targets = set(model_plan['targets'])
        generic_excluded = set(model['tweakdb'].get('excludedComponentsGeneric') or [])
        mls = model_plan['multilayers']
        none = len(surface.names)
        comp_ml = np.array([applicable(mls, n) for n in surface.names] + [-1])
        comp_target = np.array([n in targets for n in surface.names] + [False])
        comp_generic = np.array([n in targets and n not in generic_excluded for n in surface.names] + [False])
        self.masks = [Masks(masks_root, ml['mask']) for ml in mls]
        self.views = {}
        for view in RENDER_VIEWS:
            owner, zbuf, geo, bary = raster(tris, view, spacing, self.lo, self.hi, want_bary=True)
            valid = owner >= 0
            ow = owner.clip(0)
            cam = np.array(VIEWS[view][4])
            n = self.fn[ow]
            n = np.where(((n * cam).sum(-1) < 0)[..., None], -n, n)
            kind = np.where(valid, surface.kind[ow], -1)
            comp = np.where(valid, surface.comp[ow], none)
            uv = (surface.uvs[ow] * bary[..., None]).sum(-2)
            ml = comp_ml[comp]
            paint = valid & (kind == KIND_PAINT) & (ml >= 0)
            body = paint & comp_target[comp]
            gen = np.full(owner.shape, -1, np.int64)
            sel = paint & comp_generic[comp]
            if generic_png and sel.any():
                gen[sel] = generic_classes(generic_png, uv[sel])
            samples = {}
            for i, m in enumerate(self.masks):
                s = paint & (ml == i)
                if s.any():
                    samples[i] = (s, m.sample(uv[s]))
            self.views[view] = {'owner': owner, 'zbuf': zbuf, 'geo': geo, 'valid': valid, 'n': n, 'kind': kind,
                                'comp': comp, 'paint': paint, 'body': body, 'generic': gen, 'samples': samples,
                                'ml': ml}

    def composite(self, stacks, palettes):
        """stacks: multilayer index -> layer list. Per view: rgb (na, nb, 3) linear, winner (na, nb)."""
        out = {}
        cols = {i: [palettes.colour(cv(l['material']), cv(l['colorScale'])) for l in st] for i, st in stacks.items()}
        for view, g in self.views.items():
            rgb = np.zeros(g['valid'].shape + (3,), np.float32)
            win = np.full(g['valid'].shape, -1, np.int64)
            for i, (sel, mv) in g['samples'].items():
                if i not in stacks:
                    continue
                w = weights(mv, stacks[i])
                c, wi = blend(w, cols[i][:w.shape[1]])
                rgb[sel] = c
                win[sel] = wi
            out[view] = (rgb, win)
        return out

    def contrib(self, i, layers, where):
        """Summed contribution of each layer of multilayer i over the texels selected by
        where(view dict) (a boolean grid, restricted here to that multilayer's paint)."""
        total = np.zeros(len(layers))
        for g in self.views.values():
            if i not in g['samples']:
                continue
            sel, mv = g['samples'][i]
            c = contributions(weights(mv, layers))
            pick = where(g)[sel]
            total[:c.shape[1]] += c[pick].sum(0)
        return total


# --------------------------------------------------------------------------- decals
def decal_triangles(dm, frames, comps):
    """World triangles + atlas UVs of the given decal components (the glb the archive ships)."""
    tris, uvs, owner = [], [], []
    for ci, comp in enumerate(comps):
        info = dm['components'].get(comp)
        if not info or comp not in frames:
            continue
        q, t = frames[comp]
        rot = _quat_matrix(q)
        for sub in read_glb_lod1(info['glb']):
            p = sub['pos'] @ rot.T + np.array(t)
            tris.append(p[sub['idx']])
            uvs.append(sub['uv'][sub['idx']])
            owner.append(np.full(len(sub['idx']), ci))
    if not tris:
        return np.zeros((0, 3, 3)), np.zeros((0, 3, 2)), np.zeros(0, np.int64)
    return np.concatenate(tris), np.concatenate(uvs), np.concatenate(owner)


def load_atlas(art_dir, did):
    """Design atlas: linear colour + alpha. The alpha is the diffuse's own channel (what the
    shipped texture carries); an older art folder without one falls back to <id>_m.png."""
    img = Image.open(Path(art_dir) / f'{did}_d.png')
    rgb = np.asarray(img.convert('RGB'), np.float32) / 255.0
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4).astype(np.float32)
    if img.mode == 'RGBA':
        alpha = np.asarray(img.getchannel('A'), np.float32) / 255.0
    else:
        alpha = np.asarray(Image.open(Path(art_dir) / f'{did}_m.png').convert('L'), np.float32) / 255.0
    return lin, alpha


def atlas_sample(atlas, uv):
    rgb_a, a_a = atlas
    px = (uv[..., 0] * ATLAS_W).astype(np.int64).clip(0, ATLAS_W - 1)
    py = (uv[..., 1] * ATLAS_H).astype(np.int64).clip(0, ATLAS_H - 1)
    return rgb_a[py, px], a_a[py, px]


def decal_render(mv, dtris, duvs, atlas, alpha_mode):
    """Per view: decal rgb (linear) and alpha where a decal draws over the visible body."""
    out = {}
    for view, g in mv.views.items():
        rgb = np.zeros(g['valid'].shape + (3,), np.float32)
        alpha = np.zeros(g['valid'].shape, np.float32)
        if len(dtris):
            owner, zbuf, _geo, bary = raster(dtris, view, mv.spacing, mv.lo, mv.hi, want_bary=True)
            vis = (owner >= 0) & (zbuf <= g['zbuf'] + DECAL_BEHIND)
            uv = (duvs[owner.clip(0)] * bary[..., None]).sum(-2)
            col, a = atlas_sample(atlas, uv)
            if alpha_mode == 'opaque':
                a = np.ones_like(a)
            rgb[vis] = col[vis]
            alpha[vis] = a[vis]
        out[view] = (rgb, alpha)
    return out


def decal_placement(mv, surface, dtris, downer, comps, parts=None):
    """In the view each decal face was laid from (its outward normal faces that camera most;
    lv_decals.py winds every face towards the camera it was laid from, so the sign tells the
    left side from the right): drawn texels, visible ones (not behind the body), ones over
    their own component, ones floating more than DECAL_FLOAT in front of the body.
    `parts` (decal component -> panels it carries) counts a texel over a panel folded into
    that decal (lv_plan.py decalHosts: a door stripe in its door's decal) as on its panel."""
    stats = np.zeros((len(comps), 4), np.int64)
    if not len(dtris):
        return stats
    fn = face_normals(dtris)
    cams = np.array([VIEWS[v][4] for v in AUTHOR_VIEWS])
    best = (fn @ cams.T).argmax(1)
    name_idx = {n: i for i, n in enumerate(surface.names)}
    parts = parts or {}
    # allowed[j, i]: decal j may lie over surface component i (last row / column: none)
    allowed = np.zeros((len(comps) + 1, len(surface.names) + 1), bool)
    for j, c in enumerate(comps):
        for n in parts.get(c) or [c]:
            if n in name_idx:
                allowed[j, name_idx[n]] = True
    for vi, view in enumerate(AUTHOR_VIEWS):
        sel = np.nonzero(best == vi)[0]
        if not len(sel):
            continue
        g = mv.views[view]
        owner, zbuf, _geo, _ = raster(dtris[sel], view, mv.spacing, mv.lo, mv.hi)
        hit = owner >= 0
        k = np.where(hit, downer[sel][owner.clip(0)], len(comps))
        vis = hit & (zbuf <= g['zbuf'] + DECAL_BEHIND)
        sc = np.where(g['comp'] >= 0, g['comp'], len(surface.names))
        own = vis & allowed[k, sc]
        flo = vis & (zbuf < g['zbuf'] - DECAL_FLOAT)
        for j in range(len(comps)):
            mine = k == j
            stats[j] += (int(mine.sum()), int((mine & vis).sum()), int((mine & own).sum()), int((mine & flo).sum()))
    return stats


# --------------------------------------------------------------------------- images
def to_srgb8(lin):
    lin = np.clip(lin, 0, 1)
    s = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1 / 2.4) - 0.055)
    return (np.clip(s, 0, 1) * 255 + 0.5).astype(np.uint8)


def shade_view(mv, view, body_rgb, decal=None):
    g = mv.views[view]
    shade = (0.38 + 0.62 * np.clip((g['n'] * LIGHT).sum(-1), 0, 1))[..., None].astype(np.float32)
    img = np.ones(g['valid'].shape + (3,), np.float32)
    col = body_rgb.copy()
    for kind, c in KIND_COLOURS.items():
        col[g['valid'] & (g['kind'] == kind)] = c
    col[g['valid'] & (g['kind'] == KIND_PAINT) & ~g['paint']] = (0.12, 0.12, 0.13)
    if decal is not None:
        d_rgb, d_a = decal
        col = col * (1 - d_a[..., None]) + d_rgb * d_a[..., None]
    img[g['valid']] = (col * shade)[g['valid']]
    return to_srgb8(img)


def winner_view(mv, view, win):
    g = mv.views[view]
    img = np.full(g['valid'].shape + (3,), 255, np.uint8)
    img[g['valid']] = (60, 60, 60)
    for i, c in enumerate(LAYER_COLOURS):
        img[g['paint'] & (win == i)] = c
    return img


def generic_view(mv, view):
    g = mv.views[view]
    img = np.full(g['valid'].shape + (3,), 255, np.uint8)
    img[g['valid']] = (150, 150, 150)
    img[g['generic'] == GENERIC_NONE] = (35, 35, 35)
    img[g['generic'] == GENERIC_MAIN] = (230, 60, 60)
    img[g['generic'] == GENERIC_SECONDARY] = (60, 120, 230)
    return img


def sheet(panels, title, legend=None):
    """panels: [(view, rgb uint8 in viewer orientation)]: left/right/top stacked, front + rear side by side."""
    imgs = [(lbl, Image.fromarray(a, 'RGB')) for lbl, a in panels]
    big = [p for p in imgs if p[0] in ('left', 'right', 'top')]
    small = [p for p in imgs if p[0] in ('front', 'rear')]
    w = max([p.width for _, p in big] + [sum(p.width for _, p in small) + 20, 640])
    h = 34 + sum(p.height + 18 for _, p in big) + (max([p.height for _, p in small] or [0]) + 18)
    leg_h = 16 * ((len(legend) + 2) // 3) + 8 if legend else 0
    out = Image.new('RGB', (w, h + leg_h), (255, 255, 255))
    d = ImageDraw.Draw(out)
    font = ImageFont.load_default(size=13)
    d.text((8, 8), title, fill=(0, 0, 0), font=font)
    y = 34
    for lbl, p in big:
        d.text((8, y), lbl, fill=(90, 90, 90), font=font)
        out.paste(p, (0, y + 16))
        y += p.height + 18
    x = 0
    for lbl, p in small:
        d.text((x + 8, y), lbl, fill=(90, 90, 90), font=font)
        out.paste(p, (x, y + 16))
        x += p.width + 20
    for k, (c, txt) in enumerate(legend or []):
        cx, cy = 8 + (k % 3) * (w // 3), h + 16 * (k // 3)
        d.rectangle((cx, cy + 2, cx + 10, cy + 12), fill=c, outline=(0, 0, 0))
        d.text((cx + 14, cy), txt, fill=(0, 0, 0), font=font)
    return out


def save_png(img, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)


def stem(depot):
    return depot.split(BS)[-1].rsplit('.', 1)[0]


# --------------------------------------------------------------------------- commands
def load_common(cfg):
    plan = read_json(cfg['plan'])
    spec = read_json(cfg['spec'])
    dealer = {m['key']: m for m in read_json(cfg.get('dealer') or DEALER)['models']}
    return plan, spec, dealer


def model_views(cfg, model, mp):
    surface = model_surface(model, mp, cfg['measureWork'], cfg['meshJson'], roots_of(cfg))
    gdepot = model['tweakdb'].get('genericCustomizationMask') or ''
    # WolvenKit exports <flat depot>.xbm next to itself as <flat depot without .xbm>.png
    gpng = Path(cfg['generic']) / (flat_name(gdepot)[:-len('.xbm')] + '.png') if gdepot else None
    if gpng is not None and not gpng.exists():
        fail(f'{model["key"]}: generic mask {gdepot} is not exported ({gpng})')
    return surface, ModelViews(surface, model, mp, cfg['masks'], gpng, cfg['spacing'])


def cmd_inputs(cfg):
    """Files the composite reads besides the plan's: the raw .mesh of every component it
    assembles (body-kit cache), every mltemplate the reference stacks use, and every .mi of
    the material chains of those meshes. The chains are only known once the meshes and the
    first .mi files are serialized, so the build calls this until `complete` is true."""
    plan, _spec, dealer = load_common(cfg)
    work = Path(cfg['measureWork'])
    roots = roots_of(cfg)
    meshes, templates, materials = {}, set(), set()
    complete = True
    for mp in plan['models']:
        for c in body_measure.selected_components(dealer[mp['key']]):
            if c['type'] == 'entAppearanceProxyMeshComponent':
                continue
            raw = work / 'glb' / (c['mesh'].replace(BS, '/'))
            if raw.exists():
                meshes[c['mesh']] = str(raw)
        for ml in mp['multilayers']:
            for s in ml['referenceSetups']:
                for l in setup_layers(read_json(find_json(roots, s))):
                    if cv(l['material']):
                        templates.add(cv(l['material']))
    todo = []
    for depot in sorted(meshes):
        mj = mesh_json_path(cfg['meshJson'], depot)
        if mj.exists():
            todo += sorted(mesh_materials(mj))
        else:
            complete = False
    while todo:
        m = todo.pop()
        if not m.lower().endswith('.mi') or m in materials:
            continue
        materials.add(m)
        p = next((Path(r) / (flat_name(m) + '.json') for r in roots if (Path(r) / (flat_name(m) + '.json')).exists()), None)
        if p is None:
            complete = False
            continue
        base = cv(read_json(p)['Data']['RootChunk'].get('baseMaterial'))
        if base:
            todo.append(base)
    write_json(cfg['inputsOut'], {'complete': complete, 'meshes': dict(sorted(meshes.items())),
                                  'templates': sorted(templates), 'materials': sorted(materials)})
    print(f'LV_INPUTS_OK meshes={len(meshes)} templates={len(templates)} materials={len(materials)} complete={complete}')


def classify_layers(mv, i, layers, wheels_only):
    """Role of each layer of a reference stack, from where it shows on the body (grime off).

    A multilayer whose components all lie outside the factory generic mask (TweakDB
    excludedComponentsGeneric: maimai's second multilayer, hood + trunk + bumpers) has no
    factory reference: its layer 0 is paint, every other layer is trim."""
    clean = without_grime(layers)
    on_all = mv.contrib(i, clean, lambda g: g['generic'] >= 0)
    on_paint = mv.contrib(i, clean, lambda g: g['generic'] >= GENERIC_MAIN)
    on_sec = mv.contrib(i, clean, lambda g: g['generic'] == GENERIC_SECONDARY)
    texels = int(sum(int((g['generic'] >= 0)[g['samples'][i][0]].sum()) for g in mv.views.values() if i in g['samples']))
    visible = int(sum(int(g['samples'][i][0].sum()) for g in mv.views.values() if i in g['samples']))
    ungrounded = texels == 0 and visible > 0
    if ungrounded:
        on_all = mv.contrib(i, clean, lambda g: g['paint'])
    rows = []
    for k, l in enumerate(layers):
        mat = cv(l['material']) or ''
        paint = float(on_paint[k] / on_all[k]) if on_all[k] > 0 else 0.0
        accent = float(on_sec[k] / on_paint[k]) if on_paint[k] > 0 else 0.0
        if is_grime(mat):
            role = 'grime'
        elif wheels_only:
            role = 'trim'
        elif visible == 0:
            fail(f'multilayer {i} ({stem(mv.masks[i].depot)}) paints no visible texel: its components have no '
                 'multilayered chunk, so no role can be measured')
        elif ungrounded:
            role = 'paint' if k == 0 else 'trim'
        elif k == 0 or paint >= 0.5:
            role = 'accent' if k != 0 and accent >= 0.5 else 'paint'
        else:
            role = 'trim'
        rows.append({'layer': k, 'material': mat, 'colorScale': cv(l['colorScale']), 'opacity': float(l['opacity']),
                     'role': role, 'share': round(float(on_all[k] / max(on_all.sum(), 1e-9)), 4),
                     'onPaint': round(paint, 4), 'onSecondary': round(accent, 4)})
    return rows, texels, visible, ungrounded


def cmd_roles(cfg):
    plan, _spec, dealer = load_common(cfg)
    pal = Palettes(roots_of(cfg))
    out = {'schema': 'open77.vehicle-liveries.layer-roles/1', 'spacing': cfg['spacing'],
           'rule': 'paint: layer 0, or a layer whose contribution lies at least half on the factory-painted body '
                   '(generic mask main or secondary); accent: a paint layer lying at least half on the factory '
                   'secondary region; grime: dust/dirt/rust/...; trim: everything else (kept as vanilla).',
           'models': {}}
    for mp in plan['models']:
        key = mp['key']
        if cfg.get('only') and key not in cfg['only']:
            continue
        model = dealer[key]
        surface, mv = model_views(cfg, model, mp)
        fac = np.zeros(3)
        for g in mv.views.values():
            for c in range(3):
                fac[c] += int((g['body'] & (g['generic'] == c)).sum())
        mrep = {'genericMask': model['tweakdb'].get('genericCustomizationMask'), 'hidden': surface.hidden,
                'factory': {'none': round(fac[0] / max(fac.sum(), 1), 4), 'main': round(fac[1] / max(fac.sum(), 1), 4),
                            'secondary': round(fac[2] / max(fac.sum(), 1), 4), 'texels': int(fac.sum())},
                'multilayers': []}
        for i, ml in enumerate(mp['multilayers']):
            ref = ml['referenceSetups'][0]
            layers = setup_layers(read_json(find_json(roots_of(cfg), ref)))
            wheels_only = bool(ml['affected']) and all(('wheel' in c or 'rim' in c) for c in ml['affected'])
            rows, texels, visible, ungrounded = classify_layers(mv, i, layers, wheels_only)
            # The factory reference: share of the painted body its own paint layers win.
            comp = mv.composite({i: without_grime(layers)}, pal)
            paint_layers = [r['layer'] for r in rows if r['role'] in ('paint', 'accent')]
            won, total, t_won, t_total = 0, 0, 0, 0
            for view, g in mv.views.items():
                win = comp[view][1]
                sel = (g['ml'] == i) & (g['generic'] >= GENERIC_MAIN) & (win >= 0)
                total += int(sel.sum())
                won += int(np.isin(win[sel], paint_layers).sum())
                # the factory's vanilla-material region (generic mask black) of the panels
                tsel = (g['ml'] == i) & g['body'] & (g['generic'] == GENERIC_NONE) & (win >= 0)
                t_total += int(tsel.sum())
                t_won += int(np.isin(win[tsel], paint_layers).sum())
            mrep['multilayers'].append({'mask': ml['mask'], 'reference': ref, 'texels': texels, 'visibleTexels': visible,
                                        'factoryReference': not ungrounded and not wheels_only,
                                        'referencePaintShare': round(won / max(total, 1), 4), 'paintedTexels': total,
                                        'referencePaintOnTrim': round(t_won / max(t_total, 1), 4), 'trimTexels': t_total,
                                        'layers': rows})
            if cfg.get('preview'):
                legend = [(LAYER_COLOURS[r['layer'] % len(LAYER_COLOURS)], f"L{r['layer']} {r['role']} {stem(r['material'])} {r['share']:.1%}")
                          for r in rows if r['share'] >= 0.002]
                panels = [(v, to_image(winner_view(mv, v, comp[v][1]), v)) for v in RENDER_VIEWS]
                save_png(sheet(panels, f'{key}: winning layer of the vanilla reference {stem(ref)} (grime off), multilayer {i}', legend),
                         Path(cfg['preview']) / 'reference' / f'{key}_{i}_layers.png')
        if cfg.get('preview'):
            panels = [(v, to_image(generic_view(mv, v), v)) for v in RENDER_VIEWS]
            save_png(sheet(panels, f'{key}: factory TwinTone generic mask on the visible body (red main, blue secondary, '
                                   f'black vanilla material, grey not painted by it)'),
                     Path(cfg['preview']) / 'reference' / f'{key}_generic.png')
        out['models'][key] = mrep
        f = mrep['factory']
        for i, m in enumerate(mrep['multilayers']):
            roles = ''.join({'paint': 'P', 'accent': 'A', 'trim': 't', 'grime': 'g'}[r['role']] for r in m['layers'])
            print(f"{key:9} ref ml{i} {stem(m['reference']):42} roles {roles:22} factory paint share {m['referencePaintShare']:.1%}"
                  f"  (generic main {f['main']:.0%} sec {f['secondary']:.0%} none {f['none']:.0%})")
    write_json(cfg['rolesOut'], out)
    print(f'LV_ROLES_OK models={len(out["models"])}')


def cmd_check(cfg):
    plan, spec, dealer = load_common(cfg)
    pal = Palettes(roots_of(cfg))
    decals = read_json(cfg['decals'])
    package = read_json(cfg['package'])         # the roles lv_cook.py gave each layer
    designs = {d['id']: d for d in spec['designs']}
    prepared = Path(cfg['preparedDir'])
    # the vanilla reference measurements (layer-roles.json): which multilayers have a factory
    # reference, and how much of the vanilla-material region the reference's own paint wins
    if not cfg.get('rolesOut') or not Path(cfg['rolesOut']).exists():
        fail('check needs rolesOut: the layer-roles.json of the same game data (lv_composite.py roles)')
    ref_models = read_json(cfg['rolesOut'])['models']
    alpha_mode = cfg.get('decalAlpha', 'mask')
    limits = {k: float(cfg.get(k, v)) for k, v in DEFAULT_LIMITS.items()}
    report = {'schema': 'open77.vehicle-liveries.composite/1', 'spacing': cfg['spacing'], 'decalAlpha': alpha_mode,
              'limits': limits, 'models': {}}
    failures = []
    for mp in plan['models']:
        key = mp['key']
        if cfg.get('only') and key not in cfg['only']:
            continue
        model = dealer[key]
        surface, mv = model_views(cfg, model, mp)
        app = next(a for a in model['appearances'] if a['name'] == mp['playerAppearance'])
        in_app = set(app_components(Path(cfg['measureWork']) / 'json' / (Path(app['app'].replace(BS, '/')).name + '.json'),
                                    app['appearanceName']))
        # a component an appearance part brings (partsValues: the Colby Pickup's Kurtz hood scoop)
        # is on the car too; the component table resolved the parts
        in_app |= {c['name'] for c in model.get('components') or [] if c.get('name') and c.get('inPlayerAppearance')}
        visible_paint = {surface.names[c] for c in np.unique(surface.comp[surface.kind == KIND_PAINT])}
        dm = decals['models'][key]
        mrep = {'hidden': surface.hidden, 'designs': {}}
        for did, d in designs.items():
            if cfg.get('designs') and did not in cfg['designs']:
                continue
            stacks = {}
            for i in range(len(mp['multilayers'])):
                depot = f'{cfg["prefix"]}{BS}mlsetups{BS}{key}{BS}{did}_{i}.mlsetup'
                p = prepared / (flat_name(depot) + '.json')
                if not p.exists():
                    fail(f'no prepared {depot}')
                stacks[i] = setup_layers(read_json(p))
            roles = package['models'][key]['profiles'][did]['multilayers'][0]['roles']
            paint_roles = ('primary', 'secondary') if d.get('twoTone') else ('primary',)
            comp = mv.composite(stacks, pal)
            # coverage of the painted body (multilayer 0), all views together
            counts, total = {}, 0
            for view, g in mv.views.items():
                win = comp[view][1]
                sel = (g['ml'] == 0) & (g['generic'] >= GENERIC_MAIN) & (win >= 0)
                vals, cnt = np.unique(win[sel], return_counts=True)
                for v, c in zip(vals.tolist(), cnt.tolist()):
                    counts[v] = counts.get(v, 0) + c
                total += int(sel.sum())
            rows = [{'layer': k, 'role': roles[k] if k < len(roles) else '?', 'share': round(c / max(total, 1), 4)}
                    for k, c in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
            primary = sum(r['share'] for r in rows if r['role'] in paint_roles)
            if primary < limits['minPrimary']:
                failures.append(f'{key}/{did}: the paint wins {primary:.1%} of the painted body (< {limits["minPrimary"]:.0%}); '
                                + ', '.join(f"L{r['layer']} {r['role']} {r['share']:.1%}" for r in rows[:4]))
            # the factory's vanilla-material region (sills, lower bumpers, pillars: generic mask
            # black) must keep its vanilla layers: share of it won by a layer we recoloured
            recol = [k for k, r in enumerate(roles) if r in ('primary', 'secondary')]
            t_won, t_total = 0, 0
            for view, g in mv.views.items():
                win = comp[view][1]
                tsel = (g['ml'] == 0) & g['body'] & (g['generic'] == GENERIC_NONE) & (win >= 0)
                t_total += int(tsel.sum())
                t_won += int(np.isin(win[tsel], recol).sum())
            trim_recol = t_won / max(t_total, 1)
            trim_ref = ref_models[key]['multilayers'][0]['referencePaintOnTrim']
            if trim_recol > trim_ref + limits['maxTrimRecolouredExcess']:
                failures.append(f'{key}/{did}: recoloured layers win {trim_recol:.1%} of the vanilla-material region '
                                f'({t_total} texels); the vanilla reference paint wins {trim_ref:.1%} '
                                f'(> +{limits["maxTrimRecolouredExcess"]:.0%})')
            # the other body multilayers (maimai: hood, trunk, bumpers), on every visible paint texel;
            # asserted only where the factory generic mask paints them (maimai's lie outside it: the
            # factory leaves them to their vanilla material, so their bare-steel trim is not a defect)
            others = {}
            for i in range(1, len(mp['multilayers'])):
                ml = mp['multilayers'][i]
                if ml['affected'] and all(('wheel' in c or 'rim' in c) for c in ml['affected']):
                    continue
                roles_i = package['models'][key]['profiles'][did]['multilayers'][i]['roles']
                paint_i = [k for k, r in enumerate(roles_i) if r in paint_roles]
                won, tot = 0, 0
                for view, g in mv.views.items():
                    win = comp[view][1]
                    sel = (g['ml'] == i) & g['body'] & (win >= 0)
                    tot += int(sel.sum())
                    won += int(np.isin(win[sel], paint_i).sum())
                if tot:
                    # asserted only where the factory reference paints it: a multilayer whose
                    # vanilla stack is all trim (the Colby Pickup's door step) stays trim
                    ref_i = ref_models[key]['multilayers'][i]
                    grounded = bool(ref_i.get('factoryReference', True)) and ref_i.get('paintedTexels', 1) > 0
                    others[str(i)] = {'primaryShare': round(won / tot, 4), 'texels': tot, 'asserted': grounded}
                    if grounded and won / tot < limits['minPrimary']:
                        failures.append(f'{key}/{did}: the paint wins {won / tot:.1%} of multilayer {i} '
                                        f'({stem(ml["mask"])}, {tot} texels) (< {limits["minPrimary"]:.0%})')
            # decals
            comps = sorted(dm['designs'].get(did, []))
            for c in comps:
                if c not in in_app:
                    failures.append(f'{key}/{did}: decal attached to {c}, not a component of {app["name"]}')
                elif c not in visible_paint:
                    failures.append(f'{key}/{did}: decal attached to {c}, which has no visible paint chunk in {app["name"]}')
            dtris, duvs, downer = decal_triangles(dm, surface.frames, comps)
            st = decal_placement(mv, surface, dtris, downer, comps,
                                 {c: dm['components'][c].get('parts') for c in comps if c in dm['components']})
            dstats = {}
            for j, c in enumerate(comps):
                drawn, vis, own, flo = (int(x) for x in st[j])
                r = {'drawn': drawn, 'visible': round(vis / max(drawn, 1), 4), 'onComponent': round(own / max(vis, 1), 4),
                     'floating': round(flo / max(vis, 1), 4)}
                dstats[c] = r
                if drawn == 0:
                    failures.append(f'{key}/{did}: decal on {c} draws nothing in its own view')
                elif (r['visible'] < limits['minDecalVisible'] or r['onComponent'] < limits['minDecalOnComponent']
                      or r['floating'] > limits['maxDecalFloating']):
                    failures.append(f'{key}/{did}: decal on {c}: visible {r["visible"]:.1%}, on its panel {r["onComponent"]:.1%}, '
                                    f'floating {r["floating"]:.1%} of {drawn} texels')
            mrep['designs'][did] = {'primaryShare': round(primary, 4), 'paintedTexels': total,
                                    'trimRecoloured': round(trim_recol, 4), 'trimReference': trim_ref,
                                    'trimTexels': t_total, 'coverage': rows,
                                    'roles': roles, 'otherMultilayers': others, 'decals': dstats}
            dec = None
            if cfg.get('preview') or cfg.get('visibleColour'):
                # what a viewer sees on the painted body once the decals are drawn over it
                dec = decal_render(mv, dtris, duvs, load_atlas(cfg['art'], did), alpha_mode)
                paint_k = [k for k, r in enumerate(roles) if r in paint_roles]
                shows = under = dark = 0
                for view, g in mv.views.items():
                    rgb, win = comp[view]
                    sel = (g['ml'] == 0) & (g['generic'] >= GENERIC_MAIN) & (win >= 0)
                    d_rgb, d_a = dec[view]
                    final = rgb * (1 - d_a[..., None]) + d_rgb * d_a[..., None]
                    lum = final @ np.array([0.2126, 0.7152, 0.0722], np.float32)
                    under += int((sel & (d_a >= 0.5)).sum())
                    shows += int((sel & (d_a < 0.5) & np.isin(win, paint_k)).sum())
                    dark += int((sel & (lum < DARK_LUMINANCE)).sum())
                mrep['designs'][did]['visible'] = {'paint': round(shows / max(total, 1), 4),
                                                   'artwork': round(under / max(total, 1), 4),
                                                   'dark': round(dark / max(total, 1), 4)}
            if cfg.get('preview'):
                base = Path(cfg['preview'])
                panels = [(v, to_image(shade_view(mv, v, comp[v][0], dec[v]), v)) for v in RENDER_VIEWS]
                save_png(sheet(panels, f'{d["label"]} on {mp["label"]} ({key}): multilayer composite + decals ({alpha_mode} alpha); '
                                       f'paint wins {primary:.1%} of the painted body'),
                         base / 'applied' / did / f'{key}.png')
                if did in cfg.get('layerSheets', []):
                    legend = [(LAYER_COLOURS[r['layer'] % len(LAYER_COLOURS)], f"L{r['layer']} {r['role']} {r['share']:.1%}") for r in rows]
                    panels = [(v, to_image(winner_view(mv, v, comp[v][1]), v)) for v in RENDER_VIEWS]
                    save_png(sheet(panels, f'{key}/{did}: winning layer per visible texel (shares: painted body)', legend),
                             base / 'layers' / f'{key}_{did}.png')
        report['models'][key] = mrep
        shares = [r['primaryShare'] for r in mrep['designs'].values()]
        dec = [x for r in mrep['designs'].values() for x in r['decals'].values() if x['drawn']]
        if shares:
            worst = min(mrep['designs'].items(), key=lambda kv: kv[1]['primaryShare'])
            top = ', '.join(f"L{x['layer']} {x['role']} {x['share']:.1%}" for x in worst[1]['coverage'][:3])
            print(f"{key:9} coverage paint min {min(shares):.1%} ({worst[0]}: {top})"
                  f"  trim recoloured max {max(r['trimRecoloured'] for r in mrep['designs'].values()):.1%}"
                  f" (reference {mrep['designs'][worst[0]]['trimReference']:.1%})"
                  + (f"  decal visible min {min(x['visible'] for x in dec):.1%} on-panel min {min(x['onComponent'] for x in dec):.1%}"
                     f" floating max {max(x['floating'] for x in dec):.1%}" if dec else ''))
    write_json(cfg['reportOut'], report)
    for f in failures:
        print(f'lv_composite: FAIL {f}' if not cfg.get('noAssert') else f'composite FAIL {f}')
    if failures and not cfg.get('noAssert'):
        fail(f'{len(failures)} composite check(s) failed')
    print(f'LV_COMPOSITE_OK models={len(report["models"])} failures={len(failures)}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('command', choices=('inputs', 'roles', 'check'))
    ap.add_argument('--cfg', required=True, type=Path)
    a = ap.parse_args()
    cfg = read_json(a.cfg)
    cfg.setdefault('spacing', 0.01)
    {'inputs': cmd_inputs, 'roles': cmd_roles, 'check': cmd_check}[a.command](cfg)


if __name__ == '__main__':
    main()
