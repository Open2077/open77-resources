(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const workspace = $('workspace'), menu = $('menu'), actions = $('actions'), status = $('status'), eye = $('eye');
  let epoch = 0, opened = false, anchor = {x: .5, y: .5}, busy = false, scale = 1, showGroups = false, pointerFrame = 0;
  // Local vector glyphs: no icon font, remote asset or provider-supplied markup.
  const paths = {
    interact: ['M8 12V5a2 2 0 0 1 4 0v6', 'M12 9h3l4 4v4l-3 4h-5l-6-7a2 2 0 0 1 3-2Z'],
    person: ['M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z', 'M4 21v-3a8 8 0 0 1 16 0v3'],
    vehicle: ['M4 10l2-6h12l2 6', 'M3 10h18v8H3Z', 'M5 18v3m14-3v3M6 14h2m8 0h2'],
    info: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z', 'M12 11v6m0-10v.2'],
    lock: ['M6 10V7a6 6 0 0 1 12 0v3', 'M4 10h16v11H4ZM12 14v3'],
    tool: ['M14 3a6 6 0 0 0-6 8l-6 6 5 5 6-6a6 6 0 0 0 8-7l-4 4-5-5 4-4Z'],
    location: ['M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0Z', 'M15 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z'],
  };
  const emit = (name, data = {}) => Open77.emit(name, {...data, epoch});
  const clamp = (v, low, high) => Math.max(low, Math.min(high, v));
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    for (const [k, v] of Object.entries({viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.8', 'stroke-linecap': 'round', 'stroke-linejoin': 'round'})) svg.setAttribute(k, v);
    for (const d of paths[name] || paths.interact) {
      const path = document.createElementNS(svg.namespaceURI, 'path'); path.setAttribute('d', d); svg.append(path);
    }
    return svg;
  }
  function appearance(value) {
    const color = typeof value?.accentColor === 'string' && /^#[\da-f]{6}$/i.test(value.accentColor) ? value.accentColor : '#18d6e7';
    scale = typeof value?.scale === 'number' && Number.isFinite(value.scale) ? clamp(value.scale, .75, 1.5) : 1;
    showGroups = value?.showGroups === true;
    const rgb = [1, 3, 5].map(i => parseInt(color.slice(i, i + 2), 16));
    document.documentElement.style.setProperty('--accent', color);
    document.documentElement.style.setProperty('--accent-rgb', rgb.join(', '));
    document.documentElement.style.setProperty('--ui-scale', String(scale));
  }
  function place() {
    const x = anchor.x * innerWidth, y = anchor.y * innerHeight, half = 12 * scale, gap = 8 * scale;
    eye.style.left = clamp(x - half, 8, innerWidth - half * 2 - 8) + 'px';
    eye.style.top = clamp(y - half, 8, innerHeight - half * 2 - 8) + 'px';
    if (menu.hidden) return;
    const right = x + half + gap;
    const left = right + menu.offsetWidth > innerWidth - 8 ? x - half - gap - menu.offsetWidth : right;
    menu.style.left = clamp(left, 8, innerWidth - menu.offsetWidth - 8) + 'px';
    menu.style.top = clamp(y - half, 8, innerHeight - menu.offsetHeight - 8) + 'px';
  }
  function message(text, loading = false, error = false) {
    status.replaceChildren(); status.title = ''; status.classList.toggle('error', error);
    if (loading) { const spinner = document.createElement('span'); spinner.className = 'spinner'; spinner.setAttribute('aria-hidden', 'true'); status.append(spinner); }
    status.append(document.createTextNode(String(text || ''))); place();
  }
  Open77.on('context:open', p => {
    epoch = p.epoch; opened = true; busy = false; anchor = {x: .5, y: .5};
    appearance(p.appearance); workspace.hidden = false; menu.hidden = true;
    actions.replaceChildren(); message(''); eye.classList.remove('available');
    workspace.setAttribute('aria-label', 'Hold ' + (p.key || 'ALT') + ', click a target. Release or press Escape to close.');
    place();
  });
  Open77.on('context:close', () => {
    opened = false; busy = false; workspace.hidden = true; menu.hidden = true;
    actions.replaceChildren(); eye.classList.remove('available');
  });
  Open77.on('context:loading', p => {
    if (!opened || !Number.isSafeInteger(p.epoch) || p.epoch < epoch) return;
    epoch = p.epoch; busy = true; anchor = {x: p.x, y: p.y}; menu.hidden = false;
    actions.replaceChildren(); eye.classList.remove('available'); message('Looking…', true);
  });
  Open77.on('context:empty', p => {
    if (!opened || p.epoch !== epoch) return;
    busy = false; message('No target'); status.title = String(p.message || 'Click another object or surface.');
  });
  Open77.on('context:menu', p => {
    if (!opened || p.epoch !== epoch) return;
    busy = false; actions.replaceChildren(); message(''); let group = '';
    for (const action of Array.isArray(p.actions) ? p.actions : []) {
      if (showGroups && action.group !== group) {
        group = action.group; const heading = document.createElement('div'); heading.className = 'group'; heading.textContent = group; actions.append(heading);
      }
      const button = document.createElement('button'); button.className = 'action' + (action.danger ? ' danger' : ''); button.setAttribute('role', 'menuitem');
      button.dataset.token = action.token;
      const glyph = document.createElement('span'); glyph.className = 'icon'; glyph.setAttribute('aria-hidden', 'true'); glyph.append(icon(action.icon));
      const label = document.createElement('span'); label.className = 'label'; label.textContent = action.label;
      // Details stay available on hover/accessibility, without adding another row.
      button.title = action.description ? action.label + ' — ' + action.description : String(action.label || '');
      if (action.description) button.setAttribute('aria-description', action.description);
      button.append(glyph, label);
      button.addEventListener('click', event => {
        event.stopPropagation(); if (busy) return; busy = true;
        for (const b of actions.querySelectorAll('button')) b.disabled = true;
        emit('context:select', {token: action.token});
      });
      actions.append(button);
    }
    const first = actions.querySelector('button'); eye.classList.toggle('available', !!first);
    if (!first) message('No actions');
    menu.classList.remove('keyboard');
    place(); menu.focus({preventScroll: true});
  });
  Open77.on('context:busy', p => {
    if (!opened || p.epoch !== epoch) return;
    busy = true;
    const button = [...actions.querySelectorAll('button')].find(b => b.dataset.token === String(p.token));
    if (button) {
      button.classList.add('pending'); const glyph = button.querySelector('.icon');
      const spinner = document.createElement('span'); spinner.className = 'spinner'; glyph.replaceChildren(spinner);
    }
  });
  Open77.on('context:error', p => {
    if (!opened || p.epoch !== epoch) return;
    busy = false;
    for (const b of actions.querySelectorAll('button')) { b.disabled = false; b.classList.remove('pending'); }
    for (const spinner of actions.querySelectorAll('.spinner')) spinner.replaceWith(icon('info'));
    message('Action unavailable', false, true); status.title = String(p.message || 'Try again.');
  });
  document.addEventListener('mousemove', event => {
    menu.classList.remove('keyboard');
    if (!opened || !menu.hidden) return;
    anchor = {x: event.clientX / innerWidth, y: event.clientY / innerHeight};
    if (!pointerFrame) pointerFrame = requestAnimationFrame(() => { pointerFrame = 0; if (opened) place(); });
  });
  document.addEventListener('click', event => {
    if (opened && !busy && !menu.contains(event.target)) emit('context:pick', {x: event.clientX / innerWidth, y: event.clientY / innerHeight});
  });
  document.addEventListener('contextmenu', event => { event.preventDefault(); if (opened) emit('context:cancel'); });
  document.addEventListener('keydown', event => {
    if (!opened) return;
    if (event.key === 'Escape') { event.preventDefault(); emit('context:cancel'); }
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault(); const buttons = [...actions.querySelectorAll('button:not(:disabled)')]; if (!buttons.length) return;
      const current = buttons.indexOf(document.activeElement);
      const index = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : current < 0 ? (event.key === 'ArrowUp' ? buttons.length - 1 : 0) : (current + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length;
      menu.classList.add('keyboard');
      buttons[index].focus();
    }
  });
  window.addEventListener('resize', place);
  window.addEventListener('blur', () => { if (opened) emit('context:cancel'); });
  Open77.ready(); Open77.emit('context:ready', {});
})();
