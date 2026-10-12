(function () {
  'use strict';
  var host = document.getElementById('server-brand');
  var root = document.documentElement;
  var generation = 0;
  var lastLogo = '';
  function mix(rgb, target, amount) {
    return 'rgb(' + rgb.map(function (v) { return Math.round(v + (target - v) * amount); }).join(',') + ')';
  }
  Open77.on('pause:branding', function (state) {
    var accent = state && state.accentColor;
    if (!/^#[0-9a-f]{6}$/i.test(accent || '')) accent = '#22D8E2';
    var rgb = [1, 3, 5].map(function (i) { return parseInt(accent.slice(i, i + 2), 16); });
    root.style.setProperty('--o-cyan-500', accent);
    root.style.setProperty('--pause-accent-rgb', rgb.join(','));
    root.style.setProperty('--o-cyan-400', mix(rgb, 255, .2));
    root.style.setProperty('--o-cyan-600', mix(rgb, 0, .17));
    root.style.setProperty('--o-cyan-700', mix(rgb, 0, .4));
    root.style.setProperty('--o-cyan-900', mix(rgb, 0, .8));

    var chunks = state && state.logoChunks;
    var logo = Array.isArray(chunks) && chunks.length <= 32 &&
      chunks.every(function (chunk) { return typeof chunk === 'string' && chunk.length <= 48000; }) ? chunks.join('') : '';
    // The host validates paths and file bytes. Keep this DOM sink image-only too.
    if (!/^(https?:\/\/|data:image\/(png|jpeg|webp);base64,)/i.test(logo)) logo = '';
    if (logo === lastLogo) return;
    lastLogo = logo;
    var current = ++generation;
    host.hidden = true;
    host.replaceChildren();
    if (!logo) return;
    var image = new Image();
    image.alt = 'Server logo';
    image.referrerPolicy = 'no-referrer';
    image.onload = function () {
      if (current !== generation) return;
      host.replaceChildren(image);
      host.hidden = false;
    };
    image.onerror = function () {
      if (current !== generation) return;
      host.hidden = true;
      Open77.emit('pause:logo-error', {});
    };
    image.src = logo;
  });
}());
