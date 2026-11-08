// Our own plate .inkwidget (design "original"), written from scratch as WolvenKit JSON:
// a library with one item per plate mesh (Car, Moto, MotoTilt, MotoWide), made of
// rectangles and two text widgets only. No logic controller, no style resource, no
// animation: the text is set by client/redscript/Open77VehiclePlate.reds through the widget
// named PlateText, a direct child of the item's root. Fonts are the game's own OFL families
// (Orbitron, Rajdhani), referenced by depot path.
//
// Cover layout: each item has the aspect of the screen quad of its plate mesh, and that
// quad covers the holo rectangle plus a margin (cover.cjs). The design (band, borders,
// text) is drawn inside the holo rectangle; the margin is the design's background colour.
// The quad shows the whole item unstretched, and no factory print shows around it.
'use strict';

const cname = (value) => ({ $type: 'CName', $storage: 'string', $value: value });
const resourceRef = (value, flags = 'Default') => ({
  DepotPath: value ? { $type: 'ResourcePath', $storage: 'string', $value: value } : { $type: 'ResourcePath', $storage: 'uint64', $value: '0' },
  Flags: flags,
});
const vec2 = (x, y) => ({ $type: 'Vector2', X: x, Y: y });
const margin = (left = 0, top = 0, right = 0, bottom = 0) => ({ $type: 'inkMargin', bottom, left, right, top });
const hdr = ([r, g, b, a]) => ({ $type: 'HDRColor', Alpha: a, Blue: b, Green: g, Red: r });
const RESOLUTION = 'UltraHD_3840_2160';
const PACKAGE_TYPE = 'WolvenKit.RED4.Archive.Buffer.RedPackage, WolvenKit.RED4, Version=8.20.0.0, Culture=neutral, PublicKeyToken=null';
const WRAPPER_TYPE = 'WolvenKit.RED4.Archive.Buffer.CR2WWrapper, WolvenKit.RED4, Version=8.20.0.0, Culture=neutral, PublicKeyToken=null';

// Proportions of the design, relative to the height of the holo rectangle it is drawn in:
// the 2026-11-05 items (Car 990x300, Moto 600x540) divided by their height.
const STYLES = {
  car: { band: 58 / 300, bandFont: 44 / 300, border: 8 / 300, textFont: 168 / 300, textTop: 70 / 300 },
  bike: { band: 96 / 540, bandFont: 64 / 540, border: 8 / 540, textFont: 150 / 540, textTop: 110 / 540 },
};
const ITEM_HEIGHT = 400;   // pixels; the width follows the quad's aspect

// An item layout in widget pixels, from the top-left corner: the item is the whole quad,
// the face is the holo rectangle inside it. quad and face are rectangles in metres in the
// plate's reading frame (left, right, bottom, top).
function layoutFor(name, style, quad, face) {
  const S = STYLES[style];
  if (!S) throw new Error(`unknown plate style ${style}`);
  const height = quad.top - quad.bottom;
  const k = ITEM_HEIGHT / height;
  const w = Math.round((quad.right - quad.left) * k), h = ITEM_HEIGHT;
  const fx = Math.round((face.left - quad.left) * k), fy = Math.round((quad.top - face.top) * k);
  const fw = Math.round((face.right - face.left) * k), fh = Math.round((face.top - face.bottom) * k);
  const px = (r) => Math.max(1, Math.round(r * fh));
  return {
    name, style, label: style, w, h, face: { x: fx, y: fy, w: fw, h: fh },
    band: px(S.band), bandFont: px(S.bandFont), border: Math.max(4, px(S.border)), textFont: px(S.textFont), textTop: px(S.textTop), pxPerMetre: Math.round(k),
  };
}

// The superseded items of the fit rule, drawn over the whole item. Only for the before/after
// previews of preview-plates.ps1; never built.
const LEGACY_LAYOUTS = {
  Car: { name: 'Car', style: 'car', label: 'car', w: 990, h: 300, face: { x: 0, y: 0, w: 990, h: 300 }, band: 58, bandFont: 44, border: 8, textFont: 168, textTop: 70 },
  Moto: { name: 'Moto', style: 'bike', label: 'bike', w: 600, h: 540, face: { x: 0, y: 0, w: 600, h: 540 }, band: 96, bandFont: 64, border: 8, textFont: 150, textTop: 110 },
};

class Ids {
  constructor() { this.next = 0; }
  take() { return String(this.next++); }
}

function common(ids, self, parent, type, name, o) {
  return {
    $type: type,
    affectsLayoutWhenHidden: 0,
    backendData: { HandleId: ids.take(), Data: { $type: 'inkWidgetBackendData', boundLibraryItemName: cname('None'), isHiddenInEditor: 0, isLocked: 0, owner: { HandleRefId: self } } },
    canSupportFocus: 0,
    effects: [],
    fitToContent: 0,
    isInteractive: 0,
    layout: {
      $type: 'inkWidgetLayout', anchor: 'TopLeft', anchorPoint: vec2(0, 0), HAlign: o.fill ? 'Fill' : 'Left',
      margin: margin(o.x || 0, o.y || 0), padding: margin(), sizeCoefficient: 1, sizeRule: 'Fixed', VAlign: o.fill ? 'Fill' : 'Top',
    },
    logicController: null,
    name: cname(name),
    opacity: 1,
    parentWidget: parent ? { HandleRefId: parent } : null,
    propertyManager: null,
    renderTransform: { $type: 'inkUITransform', rotation: 0, scale: vec2(1, 1), shear: vec2(0, 0), translation: vec2(0, 0) },
    renderTransformPivot: vec2(0.5, 0.5),
    secondaryControllers: [],
    size: vec2(o.w, o.h),
    state: cname('Default'),
    style: null,
    tintColor: hdr(o.color || [1, 1, 1, 1]),
    userData: [],
    visible: 1,
  };
}

function rect(ids, parent, name, o) {
  const self = ids.take();
  return { HandleId: self, Data: common(ids, self, parent, 'inkRectangleWidget', name, o) };
}

function text(ids, parent, name, o) {
  const self = ids.take();
  const base = common(ids, self, parent, 'inkTextWidget', name, o);
  // Field order as WolvenKit writes it, alphabetical.
  const data = {
    ...base,
    aligmentConverted: 1,
    contentHAlign: 'Fill',
    contentVAlign: 'Fill',
    font: null,
    fontFamily: resourceRef(o.family),
    fontSize: o.size,
    fontStyle: cname(o.style),
    justification: 'Center',
    letterCase: 'UpperCase',
    lineHeightPercentage: 1,
    localizationString: { unk1: '0', value: o.text },
    lockFontInGame: 0,
    scrollDelay: 30,
    scrollTextSpeed: 5,
    text: o.text,
    textHorizontalAlignment: 'Center',
    textIdKey: cname('None'),
    textOverflowPolicy: 'AdjustToSize',
    textVerticalAlignment: 'Center',
    tracking: o.tracking || 0,
    wrappingInfo: { $type: 'textWrappingInfo', autoWrappingEnabled: 0, forceMinimumWidthToWrappingAtPosition: 0, wrappingAtPosition: 0, wrappingPolicy: 'Default' },
  };
  return { HandleId: self, Data: Object.fromEntries(Object.entries(data).sort(([a], [b]) => a.localeCompare(b, 'en', { sensitivity: 'base' }))) };
}

// L: a layout of layoutFor. The background fills the whole item (the quad, margin
// included); everything else is drawn inside the face (the holo rectangle).
function itemTree(ids, L, design) {
  const c = design.colors;
  const F = L.face;
  const rootId = ids.take();
  const root = common(ids, rootId, null, 'inkCanvasWidget', 'Root', { w: L.w, h: L.h, fill: true });
  const childrenId = ids.take();
  const kids = [];
  kids.push(rect(ids, rootId, 'Background', { w: L.w, h: L.h, color: c.background }));
  kids.push(rect(ids, rootId, 'Band', { x: F.x, y: F.y, w: F.w, h: L.band, color: c.band }));
  kids.push(text(ids, rootId, 'Region', { x: F.x, y: F.y, w: F.w, h: L.band, family: design.fonts.region.family, style: design.fonts.region.style, size: L.bandFont, text: design.regionLabel[L.label], color: c.region, tracking: 6 }));
  kids.push(rect(ids, rootId, 'BorderTop', { x: F.x, y: F.y + L.band, w: F.w, h: L.border, color: c.border }));
  kids.push(rect(ids, rootId, 'BorderBottom', { x: F.x, y: F.y + F.h - L.border, w: F.w, h: L.border, color: c.border }));
  kids.push(rect(ids, rootId, 'BorderLeft', { x: F.x, y: F.y, w: L.border, h: F.h, color: c.border }));
  kids.push(rect(ids, rootId, 'BorderRight', { x: F.x + F.w - L.border, y: F.y, w: L.border, h: F.h, color: c.border }));
  const pad = L.border * 3;
  kids.push(text(ids, rootId, design.textPath, { x: F.x + pad, y: F.y + L.textTop, w: F.w - 2 * pad, h: F.h - L.textTop - pad, family: design.fonts.text.family, style: design.fonts.text.style, size: L.textFont, text: '', color: c.text, tracking: 4 }));
  root.children = { HandleId: childrenId, Data: { $type: 'inkMultiChildren', children: kids } };
  root.childOrder = 'Forward';
  root.childMargin = margin();
  root.userData = [{ HandleId: ids.take(), Data: { $type: 'inkRootWidgetIdentifier' } }];
  const sorted = Object.fromEntries(Object.entries(root).sort(([a], [b]) => a.localeCompare(b, 'en', { sensitivity: 'base' })));
  return { $type: 'inkWidgetLibraryItemInstance', gameController: null, rootResolution: RESOLUTION, rootWidget: { HandleId: rootId, Data: sorted } };
}

// layouts: one per library item, in library order (layoutFor).
function library(depotPath, design, header, layouts) {
  const ids = new Ids();
  const items = layouts.map((L) => {
    // The cooked item carries its tree twice, as the game's own libraries do: once in the
    // embedded CR2W package and once in the compiled package data.
    const wrapped = itemTree(ids, L, design);
    const compiled = itemTree(ids, L, design);
    return {
      $type: 'inkWidgetLibraryItem',
      name: cname(L.name),
      package: { Flags: 0, Type: WRAPPER_TYPE, Data: { File: { Version: 195, BuildVersion: 0, RootChunk: wrapped, EmbeddedFiles: [] } } },
      packageData: { BufferId: '0', Flags: 0, Type: PACKAGE_TYPE, Data: { Version: 4, Sections: 7, CruidIndex: 0, CruidDict: {}, Chunks: [compiled] } },
    };
  });
  let buffer = 0;
  for (const item of items) item.packageData.BufferId = String(buffer++);
  return {
    Header: header,
    Data: {
      Version: 195, BuildVersion: 0,
      RootChunk: {
        $type: 'inkWidgetLibraryResource',
        animationLibraryResRef: resourceRef(null, 'Soft'),
        cookingPlatform: 'PLATFORM_PC',
        externalDependenciesForInternalItems: [resourceRef(design.fonts.text.family, 'Soft'), resourceRef(design.fonts.region.family, 'Soft')],
        externalLibraries: [],
        libraryItems: items,
        rootDefinitionIndex: 0,
        rootResolution: RESOLUTION,
        sequences: [],
        version: 'Default',
      },
      EmbeddedFiles: [],
    },
  };
}

// Round-trip check of the cooked library: every item at its layout size, PlateText where
// the script looks for it, and no resource but the two font families.
function validate(root, design, layouts) {
  const fail = (m) => { throw new Error(`inkwidget: ${m}`); };
  const fonts = new Set([design.fonts.text.family, design.fonts.region.family]);
  const names = root.libraryItems.map((i) => i.name.$value);
  if (JSON.stringify(names) !== JSON.stringify(layouts.map((L) => L.name))) fail(`items ${names}`);
  const visit = (n) => {
    if (Array.isArray(n)) { n.forEach(visit); return; }
    if (!n || typeof n !== 'object') return;
    if (n.$type === 'ResourcePath' && n.$storage === 'string' && !fonts.has(n.$value)) fail(`unexpected resource ${n.$value}`);
    if (n.$type && /Controller$/.test(n.$type)) fail(`unexpected controller ${n.$type}`);
    Object.values(n).forEach(visit);
  };
  visit(root);
  for (const item of root.libraryItems) {
    const trees = [item.packageData.Data.Chunks[0], item.package && item.package.Data && item.package.Data.File && item.package.Data.File.RootChunk].filter(Boolean);
    if (!trees.length) fail(`${item.name.$value}: no tree`);
    for (const t of trees) {
      const kids = t.rootWidget.Data.children.Data.children.map((k) => k.Data);
      const field = kids.find((k) => k.name.$value === design.textPath);
      if (!field || field.$type !== 'inkTextWidget') fail(`${item.name.$value}: no ${design.textPath} text widget under the root`);
      if (field.fontFamily.DepotPath.$value !== design.fonts.text.family) fail(`${item.name.$value}: ${design.textPath} font ${field.fontFamily.DepotPath.$value}`);
      const L = layouts.find((x) => x.name === item.name.$value);
      const size = t.rootWidget.Data.size;
      if (size.X !== L.w || size.Y !== L.h) fail(`${item.name.$value}: root ${size.X}x${size.Y}, layout ${L.w}x${L.h}`);
    }
  }
}

module.exports = { library, validate, layoutFor, LEGACY_LAYOUTS, STYLES, ITEM_HEIGHT };
