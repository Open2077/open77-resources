(() => {
  "use strict";

  const body = document.body;
  const byId = id => document.getElementById(id);
  const refs = {
    vitals: byId("vitals"),
    healthFill: byId("health-fill"),
    healthValue: byId("health-value"),
    healthMax: byId("health-max"),
    armor: byId("armor-value"),
    staminaFill: byId("stamina-fill"),
    staminaPercent: byId("stamina-percent"),
    weapons: byId("weapons-hud"),
    vehicleGear: byId("vehicle-gear"),
    vehicleSpeed: byId("vehicle-speed"),
    vehicleSpeedometer: byId("vehicle-speedometer"),
    vehicleSpeedArc: byId("vehicle-speed-arc"),
    vehicleRpm: byId("vehicle-rpm"),
    vehicleRpmFill: byId("vehicle-rpm-fill"),
    vehicleHealth: byId("vehicle-health"),
    vehicleMotion: byId("vehicle-motion"),
  };

  const clamp = (value, min, max) => Math.min(max, Math.max(min, Number(value) || 0));
  const whole = value => Math.max(0, Math.round(Number(value) || 0));
  const ratio = (value, maximum) => {
    const max = Number(maximum) || 0;
    return max > 0 ? clamp(Number(value) / max, 0, 1) : 0;
  };

  // Two persistent cards: updates only change their text and segment classes.
  // Never rebuild the HUD for each 200 ms equipment snapshot.
  const weaponCards = [0, 1].map(() => {
    const node = byId("weapon-template").content.firstElementChild.cloneNode(true);
    node.hidden = true;
    refs.weapons.append(node);
    const fields = Object.fromEntries(Array.from(node.querySelectorAll("[data-field]"))
      .map(element => [element.dataset.field, element]));
    return { node, fields, segmentCount: 0 };
  });

  function renderSegments(card, ammo, capacity) {
    const strip = card.fields["magazine-strip"];
    const cap = Math.max(1, whole(capacity));
    const count = Math.min(40, cap);
    if (count !== card.segmentCount) {
      strip.replaceChildren();
      for (let index = 0; index < count; index += 1)
        strip.append(document.createElement("span"));
      card.segmentCount = count;
    }
    const live = Math.round(clamp(ammo, 0, cap) * count / cap);
    Array.from(strip.children).forEach((segment, index) =>
      segment.classList.toggle("live", index < live));
  }

  function renderWeapon(card, weapon) {
    card.node.hidden = !weapon;
    if (!weapon) return;
    const fields = card.fields;
    const ammoKnown = weapon.ammoKnown === true && Number(weapon.capacity) >= 0;
    const melee = /melee|katana|knife|blade|blunt|machete|bat|hammer/i.test(String(weapon.category || ""));
    const magazine = whole(weapon.magazine);
    const capacity = whole(weapon.capacity);
    const lowAmmo = ammoKnown && capacity > 0 && magazine <= Math.ceil(capacity * 0.25);
    const hand = weapon.hand === "left" || Number(weapon.slot) > 3 ? "LEFT" : "RIGHT";
    card.node.dataset.hand = hand.toLowerCase();
    card.node.setAttribute("aria-label", `${hand.toLowerCase()} hand weapon`);
    card.node.classList.toggle("melee", melee);
    card.node.classList.toggle("low-ammo", lowAmmo);
    card.node.classList.toggle("reloading", weapon.reloading === true);
    fields["weapon-slot"].textContent = String(whole(weapon.slot) || 1);
    fields["weapon-name"].textContent = String(weapon.label || weapon.record || "WEAPON");
    fields["weapon-hand"].textContent = `${hand} HAND`;
    fields["weapon-type"].textContent = String(weapon.category || (melee ? "MELEE" : "RANGED"));
    fields["weapon-state"].textContent = weapon.reloading === true ? "RELOADING"
      : weapon.drawn === true ? "DRAWN" : "HOLSTERED";
    fields["ammo-magazine"].textContent = ammoKnown ? String(magazine) : "--";
    fields["ammo-reserve"].textContent = ammoKnown && weapon.reserveKnown !== false
      ? String(whole(weapon.reserve)) : "--";
    fields["magazine-strip"].hidden = !ammoKnown;
    if (ammoKnown) renderSegments(card, magazine, capacity);
  }

  function render(payload) {
    if (!payload || typeof payload !== "object") return;

    const health = payload.health && typeof payload.health === "object" ? payload.health : {};
    const stamina = payload.stamina && typeof payload.stamina === "object" ? payload.stamina : {};
    const hp = whole(health.value);
    const hpMax = Math.max(1, whole(health.maximum) || 100);
    const hpRatio = ratio(hp, hpMax);
    const staminaRatio = ratio(stamina.value, stamina.maximum);

    refs.healthValue.textContent = String(hp);
    refs.healthMax.textContent = String(hpMax);
    refs.healthFill.style.width = `${(hpRatio * 100).toFixed(2)}%`;
    refs.armor.textContent = String(whole(payload.armor));
    refs.staminaFill.style.width = `${(staminaRatio * 100).toFixed(2)}%`;
    refs.staminaPercent.textContent = String(Math.round(staminaRatio * 100));
    refs.vitals.classList.toggle("critical", hpRatio <= 0.25);

    // Preserve the old one-weapon payload for older resources and previews.
    const weapons = (Array.isArray(payload.weapons) ? payload.weapons : [payload.weapon])
      .filter(weapon => weapon && weapon.equipped === true).slice(0, 2);
    body.dataset.weapon = String(weapons.length > 0);
    refs.weapons.classList.toggle("dual", weapons.length === 2);
    weaponCards.forEach((card, index) => renderWeapon(card, weapons[index]));

    const vehicle = payload.vehicle && typeof payload.vehicle === "object" ? payload.vehicle : {};
    const inVehicle = vehicle.active === true;
    body.dataset.inVehicle = String(inVehicle);
    if (inVehicle) {
      const kph = whole(vehicle.speedKph);
      const speedMaximum = Math.max(1, whole(vehicle.speedMaxKph) || 300);
      const speedRatio = ratio(kph, speedMaximum);
      const rpm = whole(vehicle.rpm);
      const rpmRatio = ratio(vehicle.rpm, vehicle.rpmMax);
      const integrity = Math.round(clamp(vehicle.health, 0, 1) * 100);
      refs.vehicleGear.textContent = String(vehicle.gearLabel || "N");
      refs.vehicleSpeed.textContent = String(Math.min(kph, 999)).padStart(3, "0");
      refs.vehicleSpeedometer.setAttribute("aria-valuemax", String(speedMaximum));
      refs.vehicleSpeedometer.setAttribute("aria-valuenow", String(kph));
      refs.vehicleSpeedArc.style.strokeDasharray = `${(speedRatio * 75).toFixed(2)} 100`;
      refs.vehicleRpm.textContent = rpm.toLocaleString("en-US");
      refs.vehicleRpmFill.style.width = `${(rpmRatio * 100).toFixed(2)}%`;
      refs.vehicleHealth.textContent = `${integrity}% INTEGRITY`;
      refs.vehicleMotion.textContent = vehicle.onGround === false ? "AIRBORNE" : "ON ROAD";
    }

    body.dataset.ready = String(payload.ready === true);
    byId("command-hints").hidden = payload.ready !== true || hp <= 0 || payload.hintsVisible === false;
  }

  if (window.Open77 && typeof window.Open77.on === "function") {
    Open77.on("freeroam:hud", render);
    Open77.ready();
    Open77.emit("freeroam:hud:ready", {});
  } else if (new URLSearchParams(location.search).has("preview")) {
    render({
      ready: true,
      health: { value: 74, maximum: 100 },
      stamina: { value: 62, maximum: 100 },
      armor: 44,
      weapon: { equipped: true, drawn: true, slot: 1, label: "Unity", category: "Power pistol", ammoKnown: true, magazine: 9, capacity: 12, reserve: 96 },
      vehicle: { active: false },
    });
  }
})();
