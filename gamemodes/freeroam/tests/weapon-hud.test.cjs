// PLAYWRIGHT_PATH may point at an existing Playwright installation.
const { chromium } = require(process.env.PLAYWRIGHT_PATH || 'playwright');
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

(async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    for (const [width, height] of [[1920, 1080], [1280, 720]]) {
      const page = await browser.newPage({ viewport: { width, height } });
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.addInitScript(() => {
        window.handlers = {};
        window.Open77 = { on: (name, fn) => handlers[name] = fn, ready() {}, emit() {} };
      });
      await page.goto(pathToFileURL(path.resolve(__dirname, '../web/hud.html')).href);
      const base = { ready: true, health: { value: 100, maximum: 100 } };
      const right = { equipped: true, drawn: true, hand: 'right', slot: 1, label: 'Lexington', category: 'Handguns',
        ammoKnown: true, magazine: 18, capacity: 20, reserve: 120 };
      const left = { ...right, hand: 'left', slot: 4, label: 'Nue', magazine: 2, capacity: 10, reloading: true };
      const show = data => page.evaluate(payload => handlers['freeroam:hud'](payload), { ...base, ...data });
      await show({ weapons: [right, left] });
      const cards = page.locator('.weapon-hud:visible');
      assert.equal(await cards.count(), 2);
      assert.deepEqual(await cards.locator('[data-field="ammo-magazine"]').allTextContents(), ['18', '2']);
      assert.deepEqual(await cards.locator('[data-field="weapon-state"]').allTextContents(), ['DRAWN', 'RELOADING']);
      assert.equal(await cards.nth(0).locator('.magazine-strip .live').count(), 18);
      assert.equal(await cards.nth(1).locator('.magazine-strip .live').count(), 2);
      assert(!await cards.nth(0).evaluate(node => node.classList.contains('low-ammo')));
      assert(await cards.nth(1).evaluate(node => node.classList.contains('low-ammo')));
      await page.waitForTimeout(400);
      const box = await page.locator('#combat-hud').boundingBox();
      assert(box.x >= 0 && box.y >= 0 && box.x + box.width <= width && box.y + box.height <= height);
      if (process.env.HUD_EVIDENCE_DIR)
        await page.screenshot({ path: path.join(process.env.HUD_EVIDENCE_DIR, `hud-dual-${width}.png`) });
      await show({ weapons: [right, { ...left, reloading: false, magazine: 10 }] });
      assert.equal(await cards.nth(1).locator('.magazine-strip .live').count(), 10);
      assert.equal(await cards.nth(1).locator('[data-field="weapon-state"]').textContent(), 'DRAWN');
      await show({ weapon: { ...right, drawn: false } }); // old payload
      assert.equal(await cards.count(), 1);
      assert.equal(await cards.locator('[data-field="weapon-state"]').textContent(), 'HOLSTERED');
      assert(!await page.locator('.weapons-hud').evaluate(node => node.classList.contains('dual')));
      await show({ weapons: [{ ...right, ammoKnown: false, reserveKnown: false }] });
      assert.equal(await cards.locator('[data-field="ammo-magazine"]').textContent(), '--');
      assert(!await cards.locator('.magazine-strip').isVisible());
      await show({ weapon: { ...right, category: 'Katana' } });
      assert(!await cards.locator('.weapon-ammo').isVisible());
      assert(await cards.locator('.weapon-melee').isVisible());
      await show({ weapons: [right, left], vehicle: { active: true } });
      assert.equal(await cards.count(), 0);
      await show({ weapons: [] });
      assert.equal(await cards.count(), 0);
      assert.deepEqual(errors, []);
      await page.close();
    }
    console.log('freeroam-weapon-hud-browser-ok');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
