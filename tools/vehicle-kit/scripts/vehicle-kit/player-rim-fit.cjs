#!/usr/bin/env node
// Rim fits of every vanilla player vehicle beyond the base table (lightrp-rims-fit.json),
// per record and per entity appearance. Numbers only: no game file is read here.
//
//   node player-rim-fit.cjs <inventory> <plan> <raw fit> <base fit> <spec> <out>
//
// inventory  docs/generated/vehicle-components-player-<ver>.json (player_components.py)
// plan       the measure-wheels -Dealer input player_components.py --measure-plan wrote:
//            one model per (entity, .app, definition) wheel variant, with variantOf
// raw fit    measure-wheels.ps1 -FitOut of that plan: a fit per variant (keyed by its
//            `record` field, "<record>#<entity appearance>") and its mountTable row
// base fit   specs/lightrp-rims-fit.json: its records are left out (never rewritten) and
//            only compared with this run's measurement of the same appearance
// spec       specs/lightrp-rims.json (rim ids, labels, finishes; fitPolicy.exclude)
//
// Record fit (`fit`): the measure-wheels fit of the record's player appearance, the one a
// spawned car wears: TweakDB appearanceName, else the entity default appearance. When
// neither names an appearance of the entity (playerAppearanceSource "first entity
// appearance": the engine then picks one), the record cannot know which appearance a car
// wears, so its fit also carries:
//   * `hide` widened to the stock rim names of every appearance (the client skips a name
//     the current appearance lacks);
//   * `appearances` entries (contract "Per-appearance fits") for every appearance whose own
//     fit moves a main wheel more than APPEARANCE_TOLERANCE against the record fit: its own
//     offset, scale, per-slot overrides and hide; at most 32, the most common variants first.
// Records with a fixed appearance register the plain fit: their other appearances are only
// reachable through a curated trim, and their measured fits wait in `appearanceFits` (same
// shape as an `appearances` entry; every appearance out of tolerance or with other stock
// rim names) for whoever curates one, as vehicle_kit_trims.lua does for the dealer trims.
// Every appearance is summarised in `appearanceSummary`.
// Quest variants (records named Vehicle.q<digits>_*) are out of the extension by the owner's
// decision of 2026-11-07: the inventory leaves them out, and a record of that form is skipped
// here too, so it never gets a fit, an exclusion or a mount table row. The measure plan may
// still hold their wheel variants (a plan written before the rule): they are simply unused.
'use strict';
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');

const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
// Over the text with LF line ends: the hash of the committed file, whatever the checkout's
// line endings (the same value vehicle_kit.lua's header records for the base table).
const sha12 = file => crypto.createHash('sha256').update(fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n')).digest('hex').slice(0, 12);
const r4 = x => Math.round(x * 1e4) / 1e4;
const CAR = ['wheel_front_left', 'wheel_front_right', 'wheel_back_left', 'wheel_back_right'];
const BIKE = ['wheel_front', 'wheel_back'];
// E1c's rule for curated trims (vehicle_kit_trims.lua): a wheel that moves more than 1 cm
// or scales more than 3 % against the record fit is out of tolerance.
const APPEARANCE_TOLERANCE = { offset: 0.01, scale: 0.03 };
const MAX_APPEARANCES = 32;
// Same body as the dealer Kusanagi (hubless front ring): the base table's policy reason. The
// pattern is tried on the record name and on the entity template, since the Yaiba Muramasa
// (Vehicle.v_sportbike1_yaiba_muramasa_player) is the Kusanagi entity with the same front ring.
const POLICY_FAMILY = [{ pattern: /yaiba_kusanagi/, policy: 'kusanagi' }];
const QUEST = /^Vehicle\.q\d+_/;

function main(inventoryFile, planFile, rawFile, baseFile, specFile, outFile) {
  const inv = readJson(inventoryFile), plan = readJson(planFile), raw = readJson(rawFile);
  const base = readJson(baseFile), spec = readJson(specFile);
  const policy = (spec.fitPolicy || {}).exclude || {};
  // variant record id -> { model (plan), row (mountTable), fit (raw), excluded }
  const variants = new Map();
  const rowByKey = new Map(raw.mountTable.map(r => [r.key, r]));
  for (const m of plan.models) {
    variants.set(m.record, { key: m.key, plan: m, row: rowByKey.get(m.key), fit: raw.fit[m.record], excluded: raw.excluded[m.record] });
  }
  const variantOf = new Map(); // "<record>#<appearance>" -> variant
  for (const v of variants.values()) for (const o of v.plan.variantOf) variantOf.set(`${o.record}#${o.appearance}`, v);

  const wheelsOf = (v, bike) => Object.fromEntries((bike ? BIKE : CAR).map(s => [s, v.row?.wheels?.[s]]));
  const out = {
    schema: 'open77.vehicle-kit.rim-fit/1',
    resource: base.resource,
    generatedBy: 'scripts/vehicle-kit/player-rim-fit.cjs (measure-wheels.ps1 fit run per appearance)',
    gameVersion: inv.gameVersion,
    extends: { file: path.basename(baseFile), sha256: sha12(baseFile), records: [...Object.keys(base.fit), ...Object.keys(base.excluded)].sort(),
               note: 'records of the base table are never repeated here; a consumer merges this table under the base one (the base wins on a record both name)' },
    conventions: {
      ...base.conventions,
      hide: 'record fit: the stock rim components of the player appearance on the contract slots (never a tyre), plus rim centres on brake slots that reach into the new rim; on a record whose spawned appearance is not fixed (playerAppearanceSource "first entity appearance"), plus the stock rim names of every other appearance (a name the current appearance lacks is skipped by the client); an appearance entry carries its own list only',
      appearances: `only on a record whose spawned appearance is not fixed: entity appearance -> { offset, scale, slots?, extraSlots?, slotNames?, hide }, where one of its main wheels moves more than ${APPEARANCE_TOLERANCE.offset * 100} cm or scales more than ${APPEARANCE_TOLERANCE.scale * 100} % against the record fit (E1c rule); at most ${MAX_APPEARANCES} per record; each entry replaces only the fields it gives (contract "Per-appearance fits")`,
      appearanceFits: 'record -> appearance -> the same entry shape, for every appearance out of tolerance or with other stock rim names: measured data for curated trims, not registered',
      appearanceSummary: 'every entity appearance of the record: its wheel variant (measure plan key), its largest wheel delta against the record fit, within or out of tolerance, otherRimNames when its stock rims carry other names, or none (no rims or tyres on a contract slot: burnt or damaged, or a tyre bound to the rim rather than to a slot)',
    },
    scope: "every Vehicle.*_player* record of the inventory (cars and motorcycles) the base table does not name, except quest variants (Vehicle.q<digits>_*: out of the extension, owner's decision of 2026-11-07)",
    parts: base.parts,
    fit: {},
    excluded: {},
    appearanceFits: {},
    baseCheck: {},
    appearanceSummary: {},
    mountTable: [],
  };

  for (const m of inv.models) {
    if (QUEST.test(m.record)) continue;
    const record = m.record, bike = m.vehicleType !== 'Car';
    const main = bike ? BIKE : CAR;
    const playerVariant = variantOf.get(`${record}#${m.playerAppearance}`);
    if (base.fit[record] || base.excluded[record]) {
      // Compare only: the base table stays as it is.
      const b = base.fit[record];
      if (!b) { out.baseCheck[record] = { base: 'excluded' }; continue; }
      if (!playerVariant?.fit) { out.baseCheck[record] = { base: 'fit', thisRun: playerVariant?.excluded || 'no fit' }; continue; }
      const same = JSON.stringify(normal(b)) === JSON.stringify(normal(playerVariant.fit));
      out.baseCheck[record] = same ? { base: 'fit', thisRun: 'identical' } : { base: 'fit', thisRun: 'differs', measured: playerVariant.fit };
      continue;
    }
    const family = POLICY_FAMILY.find(f => (f.pattern.test(record) || f.pattern.test(m.entity)) && policy[f.policy]);
    if (family) { out.excluded[record] = `${policy[family.policy]} (same body as the base table's ${family.policy})`; summarise(out, m, variantOf, null, main, bike); continue; }
    if (!playerVariant) { out.excluded[record] = `player appearance ${m.playerAppearance} has no wheel variant (definition not found)`; continue; }
    if (!playerVariant.fit) {
      out.excluded[record] = playerVariant.excluded || 'no fit';
      if (playerVariant.row) out.mountTable.push({ ...playerVariant.row, key: m.key, record, label: m.displayName || m.key });
      summarise(out, m, variantOf, null, main, bike);
      continue;
    }
    const fit = clone(playerVariant.fit);
    const ref = wheelsOf(playerVariant, bike);
    const fixed = m.playerAppearanceSource !== 'first entity appearance';
    const entries = summarise(out, m, variantOf, ref, main, bike, fit.hide);
    const entryOf = e => {
      const own = clone(e.fit);
      const entry = { offset: own.offset, scale: own.scale };
      if (own.slots) entry.slots = own.slots;
      if (own.extraSlots) entry.extraSlots = own.extraSlots;
      if (own.slotNames) entry.slotNames = own.slotNames;
      entry.hide = own.hide;
      return entry;
    };
    if (entries.length) out.appearanceFits[record] = Object.fromEntries(entries.map(e => [e.name, entryOf(e)]));
    if (!fixed) {
      // Hide guard: the stock rim names of every appearance (rim role only; a name that is
      // a tyre or another part in some appearance stays out of the record list).
      const clash = new Set(m.rimNameClash || []);
      const hide = new Set(fit.hide);
      for (const a of m.appearances) {
        if (!a.found) continue;
        const v = variantOf.get(`${record}#${a.name}`);
        for (const n of v?.fit?.hide || a.rims || []) if (!clash.has(n)) hide.add(n);
      }
      fit.hide = [...hide].sort();
      const sized = entries.filter(e => e.outOfTolerance);
      const counts = {};
      for (const e of sized) counts[e.variant] = (counts[e.variant] || 0) + 1;
      sized.sort((a, b) => (counts[b.variant] - counts[a.variant]) || a.name.localeCompare(b.name));
      for (const e of sized.slice(MAX_APPEARANCES)) out.appearanceSummary[record][e.name].fit = 'dropped (32 per record)';
      const picked = sized.slice(0, MAX_APPEARANCES).sort((a, b) => a.name.localeCompare(b.name));
      if (picked.length) fit.appearances = Object.fromEntries(picked.map(e => [e.name, entryOf(e)]));
    }
    out.fit[record] = fit;
    out.mountTable.push({ ...playerVariant.row, key: m.key, record, label: m.displayName || m.key });
  }
  fs.writeFileSync(outFile, JSON.stringify(out, null, 2) + '\n');
  // Console table.
  const n = Object.keys(out.fit).length, x = Object.keys(out.excluded).length;
  for (const [record, f] of Object.entries(out.fit)) {
    const s = Object.values(out.appearanceSummary[record] || {});
    const tally = ['out of tolerance', 'within tolerance', 'none'].map(k => `${k} ${s.filter(a => a.fit === k).length}`).join(', ')
      + `${f.appearances ? `, entries ${Object.keys(f.appearances).length}` : ''}`;
    console.log(`FIT  ${record.padEnd(52)} scale ${f.scale.join(',')} offset ${f.offset[0]}${f.slots ? ` slots ${Object.keys(f.slots).length}` : ''}${f.slotNames ? ' slotNames' : ''} hide ${f.hide.length} | ${tally}`);
  }
  for (const [record, why] of Object.entries(out.excluded)) console.log(`EXCL ${record.padEnd(52)} ${why}`);
  for (const [record, c] of Object.entries(out.baseCheck)) console.log(`BASE ${record.padEnd(52)} ${c.base} / this run: ${c.thisRun}`);
  console.log(`VK_PLAYER_FIT_OK records=${n} excluded=${x} base=${Object.keys(out.baseCheck).length} -> ${outFile}`);
}

// Per appearance: variant, delta against the record fit's wheels, and an entry when out of
// tolerance. Returns the out-of-tolerance appearances (name, variant key, fit).
function summarise(out, m, variantOf, ref, main, bike, refHide) {
  const sum = out.appearanceSummary[m.record] = {};
  const entries = [];
  for (const a of m.appearances) {
    if (!a.found) { sum[a.name] = { fit: 'none', why: 'definition not found' }; continue; }
    const v = variantOf.get(`${m.record}#${a.name}`);
    if (!v?.fit) { sum[a.name] = { variant: v?.key, fit: 'none', why: v?.excluded || 'no wheel components' }; continue; }
    if (!ref) { sum[a.name] = { variant: v.key, fit: 'none', why: 'record excluded' }; continue; }
    let dOffset = 0, dScale = 0;
    for (const s of main) {
      const w = v.row?.wheels?.[s], r = ref[s];
      if (!w || !r || w.error || r.error) continue;
      dOffset = Math.max(dOffset, Math.abs(w.offsetX - r.offsetX));
      dScale = Math.max(dScale, ...w.scale.map((k, i) => Math.abs(k / r.scale[i] - 1)));
    }
    const outOfTolerance = dOffset > APPEARANCE_TOLERANCE.offset || dScale > APPEARANCE_TOLERANCE.scale;
    const otherNames = JSON.stringify([...v.fit.hide].sort()) !== JSON.stringify([...(refHide || [])].sort());
    sum[a.name] = { variant: v.key, maxOffsetDelta: r4(dOffset), maxScaleDelta: r4(dScale), fit: outOfTolerance ? 'out of tolerance' : 'within tolerance' };
    if (otherNames) sum[a.name].otherRimNames = true;
    if (outOfTolerance || otherNames) entries.push({ name: a.name, variant: v.key, fit: v.fit, outOfTolerance });
  }
  return entries;
}

function clone(x) { return JSON.parse(JSON.stringify(x)); }
// Key order does not matter for the comparison with the base table.
function normal(x) {
  if (Array.isArray(x)) return x.map(normal);
  if (x && typeof x === 'object') return Object.fromEntries(Object.keys(x).sort().map(k => [k, normal(x[k])]));
  return x;
}

const args = process.argv.slice(2);
if (args.length !== 6) { console.error('usage: player-rim-fit.cjs <inventory> <plan> <raw fit> <base fit> <spec> <out>'); process.exit(2); }
main(...args);
