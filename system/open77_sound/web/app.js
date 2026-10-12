// open77_sound -- the Web Audio half.
//
// Lua owns policy (who may play what, how many, ownership, lifetime). This file
// owns the mix: decode, gain, pitch, looping and the spatial image. It never
// fetches anything: `connect-src 'none'` in the surface CSP forbids it, and the
// clip bytes arrive as base64 on `sound:clip` instead. `decodeAudioData` takes
// an ArrayBuffer and is not subject to CSP at all, so no URL is ever involved.

(function () {
  'use strict';

  // --- coordinates -------------------------------------------------------
  //
  // The game is Z-up right-handed (X east, Y north, Z up). Web Audio is Y-up
  // right-handed with the listener facing -Z. The mapping below is a pure
  // rotation -- its determinant is +1 -- so handedness is preserved and a
  // source behind you stays behind you rather than flipping to the front:
  //
  //     audio.x =  game.x        (right stays right)
  //     audio.y =  game.z        (up stays up)
  //     audio.z = -game.y        (north becomes "away", i.e. -Z)
  //
  // Applied identically to positions and to the forward vector; the listener's
  // up is the game's +Z, which maps to Web Audio's default (0, 1, 0).
  function toAudio(x, y, z) { return { x: x, y: z, z: -y }; }

  // 64 MiB of decoded PCM. Decoded audio is 32-bit float per channel, so a
  // one-minute stereo clip is about 21 MiB regardless of how small its MP3 was:
  // the file cap on the Lua side bounds transport, this bounds memory.
  var CACHE_BYTES = 64 * 1024 * 1024;
  var RAMP = 0.06; // seconds; matches the 50 ms listener push with headroom.

  var ctx = null;
  var master = null;
  var blocked = false;
  var clock = 0;

  var clips = new Map();    // key -> { buffer, bytes, used, promise }
  var playing = new Map();  // handle -> { source, gain, panner, key, loop, stopped }

  function api() { return window.Open77; }

  function emit(name, payload) {
    var open77 = api();
    if (open77) { open77.emit(name, payload); }
  }

  function decodedBytes(buffer) {
    return buffer.length * buffer.numberOfChannels * 4;
  }

  function cacheSize() {
    var total = 0;
    clips.forEach(function (clip) { total += clip.bytes || 0; });
    return total;
  }

  function inUse(key) {
    var used = false;
    playing.forEach(function (entry) { if (entry.key === key) { used = true; } });
    return used;
  }

  // Least-recently-used first, never a clip a live sound is reading from.
  function evict() {
    while (cacheSize() > CACHE_BYTES) {
      var oldestKey = null;
      var oldest = Infinity;
      clips.forEach(function (clip, key) {
        if (clip.buffer && !inUse(key) && clip.used < oldest) { oldest = clip.used; oldestKey = key; }
      });
      if (oldestKey === null) { return; }
      clips.delete(oldestKey);
      // Lua keeps its own record of what this surface holds; without this it
      // would never re-send the bytes and the next play would hang on a clip
      // that is no longer here.
      emit('sound:evicted', { key: oldestKey });
    }
  }

  function ensureContext() {
    if (ctx) { return ctx; }
    var Ctor = window.AudioContext || window.webkitAudioContext;
    if (!Ctor) { blocked = true; return null; }
    ctx = new Ctor();
    master = ctx.createGain();
    master.gain.value = 1;
    master.connect(ctx.destination);
    return ctx;
  }

  function base64ToBuffer(text) {
    var binary = atob(text);
    var bytes = new Uint8Array(binary.length);
    for (var index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes.buffer;
  }

  function onClip(payload) {
    if (!payload || typeof payload.key !== 'string' || typeof payload.data !== 'string') { return; }
    if (clips.has(payload.key)) { return; }
    var audio = ensureContext();
    if (!audio) { return; }
    var record = { buffer: null, bytes: 0, used: clock += 1, promise: null };
    clips.set(payload.key, record);
    record.promise = audio.decodeAudioData(base64ToBuffer(payload.data)).then(function (buffer) {
      record.buffer = buffer;
      record.bytes = decodedBytes(buffer);
      evict();
      return buffer;
    }).catch(function (error) {
      clips.delete(payload.key);
      emit('sound:error', { reason: 'decode_failed:' + payload.key + ':' + (error && error.name) });
      emit('sound:evicted', { key: payload.key });
      return null;
    });
  }

  function onDrop(payload) {
    if (!payload || typeof payload.key !== 'string') { return; }
    clips.delete(payload.key);
  }

  // --- the listener ------------------------------------------------------
  //
  // Pushed at 20 Hz from Lua. Ramped rather than assigned so a camera whip does
  // not step the image five times a second; Web Audio interpolates the panner
  // continuously between the values we set.
  function setListener(payload) {
    var audio = ensureContext();
    if (!audio) { return; }
    var listener = audio.listener;
    var position = toAudio(payload.x, payload.y, payload.z);
    var forward = toAudio(payload.fx, payload.fy, payload.fz);
    var up = toAudio(0, 0, 1);
    var when = audio.currentTime + RAMP;
    if (listener.positionX) {
      listener.positionX.linearRampToValueAtTime(position.x, when);
      listener.positionY.linearRampToValueAtTime(position.y, when);
      listener.positionZ.linearRampToValueAtTime(position.z, when);
      listener.forwardX.linearRampToValueAtTime(forward.x, when);
      listener.forwardY.linearRampToValueAtTime(forward.y, when);
      listener.forwardZ.linearRampToValueAtTime(forward.z, when);
      listener.upX.linearRampToValueAtTime(up.x, when);
      listener.upY.linearRampToValueAtTime(up.y, when);
      listener.upZ.linearRampToValueAtTime(up.z, when);
    } else {
      // Older Chromium: the deprecated setters, which jump rather than ramp.
      listener.setPosition(position.x, position.y, position.z);
      listener.setOrientation(forward.x, forward.y, forward.z, up.x, up.y, up.z);
    }
  }

  function setPannerPosition(panner, x, y, z) {
    var point = toAudio(x, y, z);
    if (panner.positionX) {
      var when = ctx.currentTime + RAMP;
      panner.positionX.linearRampToValueAtTime(point.x, when);
      panner.positionY.linearRampToValueAtTime(point.y, when);
      panner.positionZ.linearRampToValueAtTime(point.z, when);
    } else {
      panner.setPosition(point.x, point.y, point.z);
    }
  }

  // --- playback ----------------------------------------------------------

  function stopHandle(handle, notify) {
    var entry = playing.get(handle);
    if (!entry) { return; }
    entry.stopped = true;
    playing.delete(handle);
    try { entry.source.stop(); } catch (error) { /* already ended */ }
    try { entry.source.disconnect(); } catch (error) { /* detached */ }
    if (notify) { emit('sound:ended', { handle: handle }); }
  }

  function start(request, buffer) {
    if (!buffer) { return; }
    var audio = ensureContext();
    if (!audio) { return; }

    var source = audio.createBufferSource();
    source.buffer = buffer;
    source.loop = request.loop === true;
    source.playbackRate.value = request.pitch || 1;

    var gain = audio.createGain();
    gain.gain.value = typeof request.volume === 'number' ? request.volume : 1;

    var panner = null;
    if (request.spatial) {
      panner = audio.createPanner();
      // HRTF is what makes "behind you" audible as behind rather than merely
      // quiet; equalpower would only pan left/right.
      panner.panningModel = 'HRTF';
      // Linear reaches exactly zero at maxDistance, which is the behaviour a
      // script means by "audible within 40 m". Inverse never quite gets there.
      panner.distanceModel = 'linear';
      panner.refDistance = request.refDistance || 1;
      panner.maxDistance = request.maxDistance || 40;
      panner.rolloffFactor = 1;
      setPannerPosition(panner, request.x, request.y, request.z);
      source.connect(gain);
      gain.connect(panner);
      panner.connect(master);
    } else {
      source.connect(gain);
      gain.connect(master);
    }

    var entry = {
      source: source, gain: gain, panner: panner, key: request.key,
      loop: source.loop, stopped: false
    };
    playing.set(request.handle, entry);

    source.onended = function () {
      if (entry.stopped) { return; }
      playing.delete(request.handle);
      emit('sound:ended', { handle: request.handle });
    };
    try {
      source.start(0, request.offset || 0);
    } catch (error) {
      playing.delete(request.handle);
      emit('sound:error', { handle: request.handle, reason: 'start_failed:' + (error && error.name) });
    }
  }

  function onPlay(request) {
    if (!request || typeof request.handle !== 'number') { return; }
    var audio = ensureContext();
    if (!audio) {
      emit('sound:error', { handle: request.handle, reason: 'audio_unavailable' });
      return;
    }
    var clip = clips.get(request.key);
    if (!clip) {
      emit('sound:error', { handle: request.handle, reason: 'clip_missing:' + request.key });
      emit('sound:evicted', { key: request.key });
      return;
    }
    clip.used = clock += 1;
    if (clip.buffer) { start(request, clip.buffer); return; }
    // Still decoding. Reserve the handle so a stop that lands first is honoured
    // instead of being overtaken by the decode.
    playing.set(request.handle, { source: { stop: function () {}, disconnect: function () {} },
      gain: null, panner: null, key: request.key, loop: false, stopped: false, pending: true });
    clip.promise.then(function (buffer) {
      var reserved = playing.get(request.handle);
      if (!reserved || !reserved.pending) { return; }
      playing.delete(request.handle);
      if (!buffer) {
        // The decode failed while this play was queued behind it. Lua is
        // holding a record for a sound that will never start, so the failure
        // has to be reported with its handle or that record leaks for the life
        // of the session and counts against the owner's cap.
        emit('sound:error', { handle: request.handle, reason: 'decode_failed:' + request.key });
        return;
      }
      start(request, buffer);
    });
  }

  function onStop(payload) {
    if (payload && typeof payload.handle === 'number') { stopHandle(payload.handle, false); }
  }

  function onVolume(payload) {
    if (!payload || typeof payload.handle !== 'number') { return; }
    var entry = playing.get(payload.handle);
    if (!entry || !entry.gain) { return; }
    entry.gain.gain.linearRampToValueAtTime(payload.volume, ctx.currentTime + RAMP);
  }

  function onPositions(payload) {
    if (!payload || !payload.items) { return; }
    for (var index = 0; index < payload.items.length; index += 1) {
      var item = payload.items[index];
      var entry = playing.get(item.handle);
      if (entry && entry.panner) { setPannerPosition(entry.panner, item.x, item.y, item.z); }
    }
  }

  // --- wiring ------------------------------------------------------------

  function announce() {
    emit('sound:ready', { blocked: blocked });
  }

  function boot() {
    var open77 = api();
    if (!open77) { window.setTimeout(boot, 50); return; }
    open77.on('sound:clip', onClip);
    open77.on('sound:drop', onDrop);
    open77.on('sound:play', onPlay);
    open77.on('sound:stop', onStop);
    open77.on('sound:volume', onVolume);
    open77.on('sound:positions', onPositions);
    open77.on('sound:listener', setListener);
    open77.ready();

    var audio = ensureContext();
    if (!audio) { announce(); return; }
    // This surface is invisible and receives no input, so it can never earn a
    // user gesture. The host therefore runs Chromium with
    // autoplay-policy=no-user-gesture-required; resume() should be immediate.
    // If a future build puts the gate back, the context stays suspended and
    // every play is refused with a NAMED reason rather than going silent.
    var settle = function () {
      blocked = audio.state !== 'running';
      announce();
    };
    if (audio.state === 'running') { settle(); return; }
    audio.resume().then(settle, settle);
  }

  boot();
})();
