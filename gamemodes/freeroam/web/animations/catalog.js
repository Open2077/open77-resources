/* Pure catalogue projection, shared by the WebUI and Node regression tests. */
(function (root) {
  'use strict';
  // "On the move" lists exactly the layer profiles: upper-body gestures and holds
  // played over the body's own walking. Every other category is a workspot
  // family and stands still (walking cancels it), which its label says.
  const categories = { onthemove: 'On the move', postures: 'Postures (stationary)', gestures: 'Gestures (stationary)', social: 'Social (stationary)', dance: 'Dance (stationary)', emotions: 'Emotions (stationary)', relaxation: 'Relaxation (stationary)', seated: 'Seated (stationary)', consumables: 'Food & drink (stationary)', work: 'Work (stationary)', music: 'Music (stationary)', interactions: 'Interactions (stationary)' };
  const placements = { standing: 'Standing', ground: 'On the ground', chair: 'Needs a chair', wall: 'Needs a wall', bed: 'Needs a bed', counter: 'Needs a counter', barstool: 'Needs a bar stool' };
  const arms = { both: 'both arms', right: 'right arm', left: 'left arm' };
  const aliases = { armscrossed: 'cross arms bras croises', armscrossed2: 'cross arms bras croises', handsup: 'surrender mains levees', handsback: 'hands behind back mains dos', handships: 'hands hips hanches', dance: 'danse dancing', smoke: 'fumer cigarette', drink: 'boire canette', chair: 'assis chaise', sit: 'assis sol', lie: 'allonge dormir', lean: 'mur appuyer', phone: 'telephone', clap: 'applaudir', think: 'reflechir', cry: 'pleurer', guitar: 'guitare',
    smoke_walk: 'fumer cigarette marcher walk', cigar_walk: 'fumer cigare marcher walk', drink_walk: 'boire canette marcher walk', bottle_walk: 'boire bouteille marcher walk', call_walk: 'telephone appel marcher walk', phone_walk: 'telephone marcher walk', handsup_walk: 'surrender mains levees marcher walk', handsback_walk: 'menotte cuffed hands behind back marcher walk', armscrossed_walk: 'bras croises marcher walk', handships_walk: 'hanches marcher walk', pocket_walk: 'poche marcher walk', talk_walk: 'parler gesticuler marcher walk', hold_item_walk: 'tenir objet marcher walk',
    point: 'pointer doigt finger', wave: 'saluer bonjour hello hi', raisehand: 'lever main', beckon: 'viens come here', stop: 'halte halt', thumbsup: 'pouce', shrug: 'hausser epaules', facepalm: 'main visage', scratchhead: 'gratter tete', what: 'quoi', me: 'moi', carry: 'porter caisse crate' };
  // Order inside "On the move": gestures first (they play once), then holds, then the carry family.
  function rankOf(profile) {
    if (profile.kind !== 'layer') return 9;
    if (/^carry/.test(profile.id)) return 2;
    return profile.mode === 'once' ? 0 : 1;
  }
  function variantName(clip, prefix) {
    const suffix = clip.startsWith(prefix) ? clip.slice(prefix.length) : clip;
    return suffix.replace(/^_+/, '').replace(/_+/g, ' ').trim().replace(/\b0+(\d+)\b/g, '$1')
      .replace(/^\w/, value => value.toUpperCase()) || 'Default';
  }
  function entries(catalog) {
    const result = [], seen = new Set();
    for (const profile of Array.isArray(catalog) ? catalog : []) {
      if (!profile || typeof profile.id !== 'string' || !Array.isArray(profile.clips)) continue;
      for (const [index, clip] of profile.clips.entries()) {
        if (typeof clip !== 'string') continue;
        const key = profile.id + ':' + clip;
        if (seen.has(key)) continue;
        seen.add(key);
        const isDefault = clip === profile.clip;
        const layer = profile.kind === 'layer';
        result.push({ key, profile: profile.id, clip, label: String(profile.label || profile.id),
          category: profile.category || 'other', categoryLabel: categories[profile.category] || 'Other',
          variant: variantName(clip, profile.clipPrefix || ''), index: index + 1, isDefault,
          prop: profile.prop || '', placement: profile.placement || 'standing', aliases: aliases[profile.id] || '',
          tested: profile.id === 'smoke' && clip === 'stand__rh_cigarette__01__smoke__01',
          walks: layer && profile.locomotion !== false, once: layer && profile.mode === 'once',
          arms: layer ? (arms[profile.arms] || arms.both) : '', rank: rankOf(profile) });
      }
    }
    return result;
  }
  const normalize = value => String(value || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  function filter(items, category, query, favorites, recents = []) {
    const words = normalize(query).trim().split(/\s+/).filter(Boolean);
    return items.filter(item => (category === 'all' || category === item.category ||
      (category === 'favorites' && favorites.has(item.key)) || (category === 'recent' && recents.includes(item.key))) &&
      words.every(word => normalize(`${item.label} ${item.profile} ${item.variant} ${item.categoryLabel} ${item.clip} ${item.aliases}`).includes(word)));
  }
  function families(items) {
    const groups = new Map();
    for (const item of items) {
      const group = groups.get(item.profile);
      if (!group) groups.set(item.profile, { ...item, variants: 1 });
      else groups.set(item.profile, { ...(item.isDefault ? item : group), variants: group.variants + 1 });
    }
    return [...groups.values()];
  }
  // "On the move" reads by use: gestures, then holds, then carry; other views stay alphabetical.
  function order(items, category) {
    return category === 'onthemove' ? items.sort((a, b) => a.rank - b.rank || a.label.localeCompare(b.label) || a.index - b.index)
      : items.sort((a, b) => a.label.localeCompare(b.label) || a.index - b.index);
  }
  function describe(item) {
    if (!item) return '';
    const parts = [item.walks ? 'Walk while it plays' : (placements[item.placement] || item.placement)];
    if (item.walks) parts.push(item.once ? 'Plays once' : 'Holds until stopped', item.arms);
    if (item.prop) parts.push('Prop: ' + item.prop);
    return parts.join(' \u00b7 ');
  }
  const api = { categories, placements, entries, filter, families, order, describe };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.FreeroamAnimationCatalog = api;
})(typeof window !== 'undefined' ? window : globalThis);
