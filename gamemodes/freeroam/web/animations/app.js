(() => {
  'use strict';
  const $ = id => document.getElementById('anim-' + id);
  const body = document.getElementById('freeroam-menu');
  const model = FreeroamAnimationCatalog, pageSize = 60;
  const storageKey = 'open77.freeroam.animationFavorites.v1', recentKey = 'open77.freeroam.animationRecents.v1';
  function read(key, max) {
    try { const saved = JSON.parse(localStorage.getItem(key) || '[]');
      return Array.isArray(saved) ? [...new Set(saved.filter(x => typeof x === 'string' && x.length < 256))].slice(0, max) : [];
    } catch (_) { return []; }
  }
  function save(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) {} }
  let items = [], selected = '', category = 'all', busy = false, loaded = false, current = null, signature = '', page = 0;
  let favorites = new Set(read(storageKey, 100)), recents = read(recentKey, 24), lastPlayback = '';
  let catalogBatch = null, catalogRevision = -1;
  const emit = (action, data = {}) => Open77.emit('animations:action', { action, ...data });
  // Decorative category symbols, not fictitious previews of game clips.
  const paths = {
    all: 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z',
    onthemove: 'M13 4a2 2 0 1 0 4 0 2 2 0 1 0-4 0M8 21l3-8 3 2v6M11 13l-1-5 5-1 3 4 3-1M10 8l-4 3 1 4',
    favorites: 'm12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2-5.6-3-5.6 3 1.1-6.2L3 9.6l6.2-.9Z',
    recent: 'M3 11a9 9 0 1 1 2 7M3 4v7h7M12 7v5l3 2',
    postures: 'M9 4a3 3 0 1 0 6 0 3 3 0 1 0-6 0M8 22v-8l-3-3 4-3h6l4 3-3 3v8M8 12l8 2M12 15v7',
    gestures: 'M8 21 3 12l3-1 3 4V4h3v7-9h3v9-7h3v10-6h3v8l-4 5Z',
    social: 'M3 4h18v12H9l-6 5ZM7 8h10M7 12h6',
    dance: 'M10 4a2 2 0 1 0 4 0 2 2 0 1 0-4 0M12 7l-2 7 5 3 3 5M10 14l-5 7M4 6l5 3h7l4-5',
    emotions: 'M3 12a9 9 0 1 0 18 0 9 9 0 1 0-18 0M8 9h1M15 9h1M7 14q5 7 10 0',
    relaxation: 'M10 4a2 2 0 1 0 4 0 2 2 0 1 0-4 0M12 7v7M5 9l7 3 7-3M12 14l-9 5h18Z',
    seated: 'M6 3v12h13V9M4 15h17M6 15v7M19 15v7',
    consumables: 'M4 5h12v9a6 6 0 0 1-12 0ZM16 7h3a3 3 0 0 1 0 6h-3M3 22h15',
    work: 'M14 4a6 6 0 0 0-7 8L2 18l4 4 6-6a6 6 0 0 0 8-7l-4 4-5-5Z',
    music: 'M9 18V5l11-3v14M9 8l11-3M3 19a3 2 0 1 0 6 0 3 2 0 1 0-6 0M14 17a3 2 0 1 0 6 0 3 2 0 1 0-6 0',
    interactions: 'M2 10 7 5l5 2 5-2 5 5-5 9-5-3-4 3ZM7 5l-3-2M17 5l3-2M7 12l5-5 5 5-3 3',
  };
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor'); svg.setAttribute('stroke-width', '1.6');
    svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(svg.namespaceURI, 'path'); path.setAttribute('d', paths[name] || paths.all); svg.append(path); return svg;
  }
  function select(key) {
    selected = key;
    for (const button of $('grid').querySelectorAll('[data-animation]')) {
      button.setAttribute('aria-pressed', String(button.dataset.animation === key ||
        (button.dataset.group && button.dataset.group === items.find(x => x.key === key)?.profile)));
    }
    renderSelection();
  }
  function renderSelection() {
    const item = items.find(x => x.key === selected), siblings = item ? items.filter(x => x.profile === item.profile) : [];
    $('selected').textContent = item ? item.label + ' · ' + item.variant : 'Choose an animation';
    $('selected').title = $('selected').textContent;
    $('detail').textContent = model.describe(item);
    $('tested').textContent = item?.tested ? 'Default cigarette: local male check recorded' : 'Asset-verified · Runtime coverage experimental';
    $('clip').textContent = item?.clip || '';
    $('play').disabled = !item || busy; $('play').textContent = busy ? 'Starting…' : '▶ Play';
    $('favorite').disabled = !item;
    $('favorite').textContent = favorites.has(selected) ? '★' : '☆';
    $('favorite').setAttribute('aria-pressed', String(favorites.has(selected)));
    $('variant-count').textContent = siblings.length ? (siblings.findIndex(x => x.key === selected) + 1) + '/' + siblings.length : '—';
    $('variant-prev').disabled = $('variant-next').disabled = siblings.length < 2 || busy;
  }
  function renderFilters() {
    const fragment = document.createDocumentFragment();
    const definitions = { all: 'All animations', favorites: 'Favourites', recent: 'Recent', ...model.categories };
    if (items.some(x => x.category === 'other')) definitions.other = 'Other';
    for (const [key, label] of Object.entries(definitions)) {
      const subset = model.filter(items, key, '', favorites, recents);
      if (!['all', 'favorites', 'recent'].includes(key) && !subset.length) continue;
      const button = document.createElement('button'); button.type = 'button';
      button.setAttribute('aria-label', label); button.title = label; button.dataset.category = key;
      const title = document.createElement('span'); title.textContent = label;
      const count = document.createElement('small'); count.textContent = ['favorites', 'recent'].includes(key) ? subset.length : new Set(subset.map(x => x.profile)).size;
      button.append(icon(key), title, count); button.setAttribute('aria-pressed', String(key === category));
      button.addEventListener('click', () => { category = key; page = 0; renderFilters(); renderCards(true); });
      fragment.append(button);
    }
    $('filters').replaceChildren(fragment);
  }
  function renderCards(resetScroll = false) {
    let visible = model.filter(items, category, $('search').value, favorites, recents);
    const grouped = !$('variants').checked && !$('search').value.trim() && !['favorites', 'recent'].includes(category);
    if (category === 'recent') visible.sort((a,b) => recents.indexOf(a.key) - recents.indexOf(b.key));
    if (grouped) visible = model.families(visible);
    if (category !== 'recent') model.order(visible, category);
    const pages = Math.max(1, Math.ceil(visible.length / pageSize));
    page = Math.min(page, pages - 1);
    $('pagination').hidden = pages < 2;
    $('page').textContent = (page + 1) + ' / ' + pages;
    $('prev').disabled = page === 0; $('next').disabled = page + 1 === pages;
    $('total').textContent = loaded ? items.length : '—';
    $('count').textContent = loaded ? visible.length + (grouped ? ' animations' : ' variants') : 'Loading collection…';
    $('loading').hidden = loaded;
    $('empty').hidden = visible.length > 0 || !loaded; $('grid').hidden = !visible.length;
    $('empty-title').textContent = category === 'favorites' ? 'YOUR FAVOURITES' : category === 'recent' ? 'RECENT ANIMATIONS' : 'NO MATCHES';
    $('empty-text').textContent = category === 'favorites' ? 'Star a variant to find it here.' : category === 'recent' ? 'Successfully started animations appear here.' : 'Try another name or reset the filters.';
    const fragment = document.createDocumentFragment();
    const pageItems = visible.slice(page * pageSize, (page + 1) * pageSize);
    const selectedProfile = items.find(x => x.key === selected)?.profile;
    if (!pageItems.some(x => x.key === selected || (grouped && x.profile === selectedProfile)))
      selected = pageItems[0]?.key || '';
    for (const item of pageItems) {
      const card = document.createElement('article'); card.className = 'anim-card';
      const button = document.createElement('button'); button.type = 'button'; button.className = 'anim-card-select';
      button.dataset.animation = item.key; if (grouped) button.dataset.group = item.profile;
      button.title = item.label + ' · ' + item.variant;
      const title = document.createElement('strong'); title.textContent = item.label;
      const subtitle = document.createElement('small'); subtitle.textContent = grouped ? item.variants + (item.variants === 1 ? ' variant' : ' variants') : item.variant;
      button.append(icon(item.category), title, subtitle);
      button.addEventListener('click', () => select(item.key));
      button.addEventListener('dblclick', () => { select(item.key); play(); });
      const star = document.createElement('button'); star.type = 'button'; star.className = 'anim-star'; star.append(icon('favorites'));
      star.setAttribute('aria-label', 'Favourite ' + item.label + ', ' + item.variant);
      star.setAttribute('aria-pressed', String(favorites.has(item.key)));
      star.addEventListener('click', () => {
        if (favorites.has(item.key)) favorites.delete(item.key);
        else { if (favorites.size >= 100) favorites.delete(favorites.values().next().value); favorites.add(item.key); }
        save(storageKey, [...favorites]); renderFilters();
        if (category === 'favorites') { renderCards(); $('search').focus(); }
        else star.setAttribute('aria-pressed', String(favorites.has(item.key)));
      });
      card.append(button, star); fragment.append(card);
    }
    $('grid').replaceChildren(fragment);
    if (resetScroll) $('grid').scrollTop = 0;
    if (!items.some(x => x.key === selected)) selected = visible[0]?.key || '';
    select(selected);
  }
  function renderCurrent() {
    const step = (Array.isArray(current?.steps) ? current.steps : [])[Number(current?.step) || 0];
    const action = items.find(x => x.profile === step?.profile && x.clip === step?.clip);
    $('status').textContent = busy ? 'STARTING' : current?.active ? 'PLAYING' : 'READY';
    $('current').textContent = current?.active ? action?.label || step?.profile || 'Role-play action' : 'No active animation';
    $('stop').disabled = !busy && !current?.active;
    $('current').closest('.anim-current').classList.toggle('active', busy || !!current?.active);
    // History records authoritative acceptance, never a failed click.
    const playback = current?.active && action ? current.playbackId + ':' + action.key : '';
    if (playback && playback !== lastPlayback) {
      lastPlayback = playback; recents = [action.key, ...recents.filter(x => x !== action.key)].slice(0,24);
      save(recentKey, recents); renderFilters(); if (category === 'recent') renderCards();
    }
    renderSelection();
  }
  function play() {
    const item = items.find(x => x.key === selected); if (!item || busy) return;
    busy = true; renderCurrent();
    emit('play', { profile:item.profile, clip:item.clip, loop:$('loop').checked, durationMs:Number($('duration').value) });
  }
  function open() {
    body.dispatchEvent(new CustomEvent('freeroam:navigate', { detail: 'animations' }));
    $('search').focus({ preventScroll:true });
  }
  $('search').addEventListener('input', () => { page = 0; renderCards(true); });
  $('variants').addEventListener('change', () => { page = 0; renderCards(true); });
  $('reset').addEventListener('click', () => { category='all'; page=0; $('search').value=''; renderFilters(); renderCards(true); $('search').focus(); });
  $('retry').addEventListener('click', () => emit('refresh'));
  $('favorite').addEventListener('click', () => {
    if (!items.some(x => x.key === selected)) return;
    if (favorites.has(selected)) favorites.delete(selected);
    else { if (favorites.size >= 100) favorites.delete(favorites.values().next().value); favorites.add(selected); }
    save(storageKey, [...favorites]); renderFilters(); renderCards();
  });
  $('prev').addEventListener('click', () => { page--; renderCards(true); });
  $('next').addEventListener('click', () => { page++; renderCards(true); });
  for (const [id, direction] of [['variant-prev',-1],['variant-next',1]]) $(id).addEventListener('click', () => {
    const item=items.find(x=>x.key===selected), siblings=items.filter(x=>x.profile===item?.profile);
    if (siblings.length && !busy) select(siblings[(siblings.findIndex(x=>x.key===selected)+direction+siblings.length)%siblings.length].key);
  });
  $('loop').addEventListener('change', () => { $('duration-wrap').hidden=$('loop').checked; });
  for (const button of $('duration-wrap').querySelectorAll('[data-duration]')) button.addEventListener('click', () => {
    $('duration').value=button.dataset.duration;
    for (const option of $('duration-wrap').querySelectorAll('[data-duration]')) option.setAttribute('aria-pressed',String(option===button));
  });
  $('close').addEventListener('click', () => Open77.emit('freeroam:close',{}));
  $('back').addEventListener('click', () => body.querySelector('.tab[data-tab=vehicles]').click());
  $('stop').addEventListener('click', () => emit('stop')); $('play').addEventListener('click', play);
  document.addEventListener('keydown', event => {
    if (!body.classList.contains('open') || !body.classList.contains('animation-mode')) return;
    if (event.key==='/' && !['INPUT','TEXTAREA'].includes(document.activeElement?.tagName)) { event.preventDefault(); $('search').focus(); }
  });
  Open77.on('animations:open', open);
  Open77.on('animations:catalog', message => {
    if (!message || !Number.isSafeInteger(message.revision) || message.revision <= catalogRevision ||
        !Number.isInteger(message.total) || message.total < 1 || message.total > 256 ||
        !Number.isInteger(message.batch) || message.batch < 1 || message.batch > message.total ||
        !Array.isArray(message.profiles) || message.profiles.length > 4) return;
    if (catalogBatch && message.revision < catalogBatch.revision) return;
    if (!catalogBatch || catalogBatch.revision !== message.revision)
      catalogBatch = { revision:message.revision, total:message.total, pages:new Map() };
    if (catalogBatch.total !== message.total) return;
    catalogBatch.pages.set(message.batch, message.profiles);
    if (catalogBatch.pages.size !== catalogBatch.total) return;
    const catalog=[];
    for (let i=1;i<=catalogBatch.total;i++) catalog.push(...catalogBatch.pages.get(i));
    catalogRevision=message.revision; catalogBatch=null; updateCatalog(catalog); loaded=true;
    renderFilters(); renderCards(); renderCurrent();
  });
  function updateCatalog(catalog) {
    signature=JSON.stringify(catalog); items=model.entries(catalog);
    if (!items.some(x=>x.key===selected)) selected=(items.find(x=>x.profile==='armscrossed'&&x.isDefault)||items[0])?.key||'';
  }
  Open77.on('animations:state', state => {
    if (!state || typeof state!=='object') return;
    const next=state.catalog === undefined ? signature : JSON.stringify(state.catalog||[]), loadChanged=loaded!==(state.loaded===true);
    loaded=state.loaded===true && (catalogRevision>=0 || state.catalog!==undefined); busy=state.busy===true; current=state.current||null;
    if (next!==signature||loadChanged) {
      if (state.catalog!==undefined) updateCatalog(state.catalog);
      renderFilters(); renderCards();
    }
    $('message').textContent=String(state.message||''); $('message').hidden=!state.message;
    renderCurrent();
  });
  renderFilters(); renderCards(); Open77.emit('animations:ready',{});
})();
