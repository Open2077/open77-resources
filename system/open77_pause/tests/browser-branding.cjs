// Run from repo root with PLAYWRIGHT_MODULE pointing to playwright/core.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const path=require('node:path'); const fs=require('node:fs'); const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.OP77_TEST_BROWSER || undefined});
 try {
 const page=await browser.newPage({viewport:{width:1920,height:1080}}); const errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{window.events=[];window.handlers={};window.Open77={ready:()=>{},on:(n,cb)=>handlers[n]=cb,emit:(n,v)=>events.push({n,v})};});
 await page.goto('file:///'+path.resolve('resources/system/open77_pause/web/index.html').replaceAll('\\','/'));
 await page.evaluate(()=>handlers['pause:open']({generation:1}));
 const logo=await page.evaluate(()=>{
   const canvas=document.createElement('canvas');canvas.width=320;canvas.height=80;
   const c=canvas.getContext('2d');c.fillStyle='#ffcc00';c.font='bold 38px sans-serif';c.fillText('NIGHT CITY RP',4,54);
   return canvas.toDataURL('image/png');
 });
 if(process.env.OP77_LOGO_FIXTURE) fs.writeFileSync(process.env.OP77_LOGO_FIXTURE,Buffer.from(logo.split(',')[1],'base64'));
 await page.evaluate(logo=>handlers['pause:branding']({accentColor:'#FFCC00',logoChunks:[logo]}),logo);
 await page.waitForFunction(()=>!document.getElementById('server-brand').hidden);
 assert.equal(await page.locator('.mast__crop img').getAttribute('src'),'open77.png');
 assert.equal(await page.locator('#server-brand img').count(),1);
 assert.equal(await page.locator('#server-brand img').evaluate(e=>e.naturalWidth),320);
 await page.locator('[data-action=resume]').hover();
 assert.equal(await page.locator('[data-action=resume]').evaluate(e=>getComputedStyle(e).backgroundColor),'rgba(255, 204, 0, 0.08)');
 assert.equal(await page.locator('.mast__chip').evaluate(e=>getComputedStyle(e).display),'none');
 // Changing only the accent must not reload the logo.
 await page.evaluate(logo=>{window.imageBefore=document.querySelector('#server-brand img');handlers['pause:branding']({accentColor:'#AA44CC',logoChunks:[logo]});},logo);
 assert.equal(await page.evaluate(()=>imageBefore===document.querySelector('#server-brand img')),true);
 const bounds=await page.locator('#server-brand').boundingBox(); assert.ok(bounds.width>100 && bounds.height===40);
 // Multi-chunk data transport, without increasing the normal string quota.
 await page.evaluate(logo=>handlers['pause:branding']({accentColor:'#AA44CC',logoChunks:[logo.slice(0,60),logo.slice(60)]}),logo);
 assert.equal(await page.locator('#server-brand img').count(),1);
 await page.route('https://branding.invalid/**',route=>route.request().url().endsWith('broken.png') ? route.abort() : route.fulfill({contentType:'image/png',body:Buffer.from(logo.split(',')[1],'base64')}));
 await page.evaluate(()=>handlers['pause:branding']({accentColor:'#00FF88',logoChunks:['https://branding.invalid/server.png']}));
 await page.waitForFunction(()=>!document.getElementById('server-brand').hidden);
 assert.equal(await page.locator('#server-brand img').getAttribute('src'),'https://branding.invalid/server.png');
 await page.evaluate(()=>handlers['pause:branding']({accentColor:'#00FF88',logoChunks:['https://branding.invalid/broken.png']}));
 await page.waitForFunction(()=>events.some(x=>x.n==='pause:logo-error'));
 assert.equal(await page.locator('#server-brand').isVisible(),false);
 assert.equal(await page.locator('.mast__crop img').isVisible(),true);
 await page.evaluate(()=>handlers['pause:branding']({accentColor:'bad',logoChunks:['javascript:alert(1)']}));
 assert.equal(await page.locator('html').evaluate(e=>e.style.getPropertyValue('--o-cyan-500')),'#22D8E2');
 assert.equal(await page.locator('#server-brand img').count(),0);
 // A pending image must not resurrect branding after reset/disconnect.
 await page.evaluate(logo=>{handlers['pause:branding']({accentColor:'#FFCC00',logoChunks:[logo]});handlers['pause:branding']({accentColor:'#22D8E2',logoChunks:[]});},logo);
 await page.waitForTimeout(100);
 assert.equal(await page.locator('#server-brand').isVisible(),false);
 assert.equal(await page.locator('#server-brand img').count(),0);
 assert.deepEqual(errors,[]);
 console.log('Pause DOM branding: accents, additive logo, local/remote, chunks, invalid image and stale-load reset passed.');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
