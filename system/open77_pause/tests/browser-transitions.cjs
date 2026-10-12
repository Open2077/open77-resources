// Run from the repository root with Playwright available (see wardrobe tests).
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const path=require('node:path');const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.OP77_TEST_BROWSER || undefined});
 const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{window.events=[];window.handlers={};window.Open77={ready:()=>{},on:(n,cb)=>handlers[n]=cb,emit:(n,v)=>events.push({n,v})};});
 await page.goto('file:///'+path.resolve('resources/system/open77_pause/web/index.html').replaceAll('\\','/'));
 await page.evaluate(()=>{handlers['pause:open']({generation:1});handlers['pause:close']({generation:2,immediate:true});});
 await page.waitForTimeout(80);assert.equal(await page.locator('body').evaluate(e=>e.classList.contains('open')),false,'close must cancel pending opening frames');
 await page.evaluate(()=>handlers['pause:open']({generation:3}));await page.waitForTimeout(80);
 await page.evaluate(()=>{handlers['pause:close']({generation:4});handlers['pause:open']({generation:5});});
 await page.waitForTimeout(300);assert.equal(await page.locator('body').evaluate(e=>e.classList.contains('open')),true,'old close timer must not close a reopened menu');
 assert.equal(await page.evaluate(()=>events.some(x=>x.n==='pause:closed' && x.v.generation===4)),false,'old close must not acknowledge to the Lua owner');
 await page.evaluate(()=>handlers['pause:close']({generation:6,immediate:true}));await page.waitForTimeout(40);
 assert.equal(await page.locator('body').evaluate(e=>e.classList.contains('open')),false);
 assert.equal(await page.evaluate(()=>events.some(x=>x.n==='pause:closed' && x.v.generation===6)),true);
 assert.deepEqual(errors,[]);console.log('Pause DOM transitions: pending-open cancellation, stale-close acknowledgement suppression, immediate lifecycle cleanup passed.');await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
