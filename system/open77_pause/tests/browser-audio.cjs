const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const {pathToFileURL}=require('node:url');
const path=require('node:path');
const assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
const fixture=JSON.parse(execFileSync(process.env.OP77_TEST_PYTHON || 'python',
 [path.join(__dirname,'audio-fixture.py')],{encoding:'utf8'}));
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.OP77_TEST_BROWSER || undefined});
 try {
  const page=await browser.newPage({viewport:{width:1920,height:1080}}), errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{
   window.events=[];window.handlers={};
   window.Open77={ready(){},on:(n,cb)=>handlers[n]=cb,emit:(n,v)=>events.push({n,v})};
  });
  await page.goto(pathToFileURL(path.resolve('resources/system/open77_pause/web/index.html')).href);
  await page.evaluate(strings=>{
   handlers['pause:strings'](strings);
   handlers['settings:tabs']({tabs:[{id:'audio'}]});
   handlers['pause:open']({generation:1});
  },fixture.strings);
  await page.locator('[data-action=settings]').click();
  await page.locator('[data-tab=audio]').click();
  await page.evaluate(section=>handlers['settings:values']({tab:'audio',done:true,sections:[section]}),fixture.section);
  assert.match(await page.locator('.section__title').textContent(),/WEBUI AUDIO/);
  const range=page.locator('input[type=range]');
  assert.equal(await range.inputValue(),'35');
  // Pointer coordinates must be measured after the settings-panel transition.
  await page.waitForTimeout(600);
  const box=await range.boundingBox();
  await page.mouse.click(box.x+1,box.y+box.height/2);
  await page.waitForTimeout(250);
  assert.equal(await range.inputValue(),'0');
  assert.deepEqual(await page.evaluate(()=>events.filter(e=>e.n==='settings:set').at(-1).v),
   {group:'webui_audio',name:'WebUiVolume',value:0});
  await page.mouse.click(box.x+box.width-1,box.y+box.height/2); await page.waitForTimeout(250);
  assert.equal(await range.inputValue(),'100');
  assert.equal(await page.evaluate(()=>events.filter(e=>e.n==='settings:set').at(-1).v.value),100);
  await page.screenshot({path:process.env.OP77_AUDIO_SCREENSHOT || 'artifacts/webui-audio-settings.png'});
  await page.evaluate(()=>handlers['settings:feedback']({tab:'audio',ok:false,message:'Could not save WebUI volume.'}));
  assert.equal(await page.locator('.settings-note--error').textContent(),'Could not save WebUI volume.');
  assert.deepEqual(errors,[]);
  console.log('Pause WebUI audio: rendered, pointer mute/full volume, native event values and save failure feedback passed');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
