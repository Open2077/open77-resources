const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.OP77_TEST_BROWSER || undefined });
  try {
    const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.addInitScript(() => {
      window.events = []; window.handlers = {};
      window.Open77 = { ready() {}, on: (n, cb) => handlers[n] = cb, emit: (n, v) => events.push({ n, v }) };
    });
    await page.goto(pathToFileURL(path.resolve('resources/system/open77_pause/web/index.html')).href);
    await page.evaluate(() => {
      handlers['settings:tabs']({ tabs: [{ id: 'keybinds' }, { id: 'voice' }] });
      handlers['pause:open']({ generation: 1 });
    });
    await page.locator('[data-action=settings]').click();
    async function load(tab) {
      await page.locator(`[data-tab=${tab}]`).click();
      await page.evaluate(tab => handlers['settings:values']({ tab, done: true, sections: [{ group: tab, title: tab,
        entries: Array.from({ length: tab === 'voice' ? 1 : 30 }, (_, i) => ({
          name: tab === 'voice' ? 'PushToTalkKey' : 'resource:action' + i, label: 'Action ' + i,
          type: 'keybind', value: 'K', default: 'K', rebound: true })) }] }), tab);
    }
    const sets = () => page.evaluate(() => events.filter(e => e.n === 'settings:set'));
    const binding = page.locator('.keybind').first();
    for (const tab of ['keybinds', 'voice']) {
      await load(tab);
      for (const [button, key] of [['left', 'MOUSE1'], ['right', 'MOUSE2'], ['middle', 'MOUSE3'], ['back', 'MOUSE4'], ['forward', 'MOUSE5']]) {
        const before = (await sets()).length;
        await binding.click();
        assert.equal((await sets()).length, before, 'arming click must not bind itself');
        if (button === 'back' || button === 'forward') {
          await page.evaluate(button => {
            handlers['webui:mouse-button']({ button, mouseUp: false });
            handlers['webui:mouse-button']({ button, mouseUp: true });
          }, button === 'back' ? 3 : 4);
        } else {
          // Click over another control: binding must not activate that control.
          await page.locator('#settings-back').hover();
          await page.mouse.click(...Object.values(await page.locator('#settings-back').evaluate(e => {
            const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
          })), { button });
        }
        const changes = await sets();
        assert.equal(changes.length, before + 1);
        assert.deepEqual(changes.at(-1).v, { group: tab, name: tab === 'voice' ? 'PushToTalkKey' : 'resource:action0', value: key });
        assert.equal(await page.locator('body').evaluate(e => e.classList.contains('settings-open')), true);
        assert.equal(await page.locator('.keybind--capture').count(), 0);
      }
    }
    await load('keybinds');
    await binding.click();
    await page.evaluate(() => handlers['settings:values']({ tab: 'keybinds', done: true, sections: [{ group: 'keybinds', entries: [
      { name: 'resource:action0', label: 'Refreshed action', type: 'keybind', value: 'K', default: 'K' }
    ] }] }));
    assert.equal(await page.locator('.keybind--capture').count(), 1, 'capture survives asynchronous refresh');
    await page.keyboard.press('a');
    assert.equal((await sets()).at(-1).v.value, 'A');
    await binding.click();
    const beforeCancel = (await sets()).length;
    await page.keyboard.press('Escape');
    assert.equal((await sets()).length, beforeCancel);
    assert.equal(await page.locator('.keybind--capture').count(), 0);
    assert.equal(await page.locator('body').evaluate(e => e.classList.contains('settings-open')), true);
    await binding.click();
    await page.evaluate(() => handlers['pause:close']({ generation: 2, immediate: true }));
    await page.evaluate(() => handlers['webui:mouse-button']({ button: 4, mouseUp: false }));
    assert.equal((await sets()).length, beforeCancel, 'closed menu cannot apply a stale capture');
    await page.evaluate(() => handlers['pause:open']({ generation: 3 }));
    await page.locator('[data-action=settings]').click();
    await load('keybinds');
    await page.locator('#settings-list').hover();
    await page.mouse.wheel(0, 600);
    await page.waitForFunction(() => document.getElementById('settings-list').scrollTop > 0);
    await page.locator('.keybind-reset').first().click();
    assert.equal((await sets()).at(-1).v.value, '__default__');
    assert.deepEqual(errors, []);
    console.log('WebUI pause: five mouse buttons in bindings and voice, no click-through, refresh, keyboard, cancel/close, wheel and reset passed.');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });
