// Preferences live in the trusted bootstrap's device-local KVP, not the
// per-process Chromium profile. No music or preferences are sent to a server.
(() => {
  "use strict";
  const $ = id => document.getElementById(id), audio = $("lobbyAudio");
  let enabled = true, volume = .12, visible = false, ready = false, blocked = false, saveTimer;
  audio.volume = volume;
  function paint() {
    $("musicVolume").value = String(Math.round(volume * 100));
    $("musicLevel").textContent = Math.round(volume * 100) + "%";
    const label = !enabled || blocked ? "Play lobby music" : "Pause lobby music";
    $("musicToggle").setAttribute("aria-label", label); $("musicToggle").title = label;
    $("musicIcon").setAttribute("d", !enabled || blocked ? "M7 4v16l14-8z" : "M7 5h3v14H7zM14 5h3v14h-3z");
    $("musicPlaying").classList.toggle("active", !audio.paused && volume > 0 && visible);
    $("musicStatus").textContent = audio.error ? "Audio unavailable" : blocked ? "Click play to start" : !enabled ? "Paused" : volume === 0 ? "Muted" : !ready ? "Loading preferences" : audio.paused ? "Standby" : "Playing · looping";
  }
  async function sync() {
    audio.volume = volume;
    if (!visible || !ready || !enabled || document.body.dataset.view === "notice") { audio.pause(); paint(); return; }
    try { await audio.play(); blocked = false; }
    catch (error) { if (error.name !== "AbortError") blocked = true; }
    // A late play promise must not resume audio after world entry.
    if (!visible || !enabled) audio.pause();
    paint();
  }
  async function save() {
    try {
      const result = await Open77.invoke("music:preferences", { enabled, volume });
      if (!result?.accepted) throw new Error("not_saved");
      $("musicSaveError").hidden = true;
    } catch (_) {
      $("musicSaveError").textContent = "Settings could not be saved. This session keeps your choice.";
      $("musicSaveError").hidden = false;
    }
  }
  $("musicToggle").onclick = () => { enabled = blocked || !enabled; blocked = false; sync(); clearTimeout(saveTimer); save(); };
  $("musicVolume").oninput = event => {
    volume = Math.max(0, Math.min(1, Number(event.target.value) / 100));
    audio.volume = volume; paint(); clearTimeout(saveTimer); saveTimer = setTimeout(save, 200);
  };
  $("musicVolume").onchange = () => { clearTimeout(saveTimer); save(); };
  for (const event of ["playing", "pause", "error", "volumechange"]) audio.addEventListener(event, paint);
  for (const event of ["playing", "pause", "error"]) audio.addEventListener(event, () => {
    Open77.emit("music:playback", { playing: !audio.paused, volume, error: audio.error?.code || null });
  });
  Open77.on("music:preferences", prefs => {
    enabled = prefs?.enabled !== false;
    volume = typeof prefs?.volume === "number" && Number.isFinite(prefs.volume) ? Math.max(0, Math.min(1, prefs.volume)) : .12;
    ready = true; sync();
  });
  Open77.on("music:visibility", value => { visible = value?.visible === true; sync(); });
  Open77.on("shell:notice", () => { visible = false; sync(); });
  window.addEventListener("pagehide", () => { audio.pause(); });
  paint();
})();
