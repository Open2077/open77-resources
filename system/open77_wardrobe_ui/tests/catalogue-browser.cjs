// Real page pagination/search coverage, not a mock of the catalogue filter.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');const fs=require('node:fs');const path=require('node:path');const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.OP77_TEST_BROWSER || undefined});const page=await browser.newPage({viewport:{width:1920,height:1080}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{window.handlers={};window.Open77={ready:()=>{},on:(n,cb)=>handlers[n]=cb,emit:()=>{}};});
 await page.goto('file:///'+path.resolve('resources/system/open77_wardrobe_ui/web/index.html').replaceAll('\\','/'));
 const nonvisual=new Set([...fs.readFileSync('client/src/game/generated/EmptyClothing.inl','utf8').matchAll(/ULL, \/\/ (Items\.[^\r\n]+)/g)].map(m=>m[1]));
 const all=JSON.parse(fs.readFileSync('docs/generated/clothing-2.31.json','utf8')).items;
 const slots={head:'Head',face:'Face',inner_chest:'InnerChest',outer_chest:'OuterChest',legs:'Legs',feet:'Feet',outfit:'Outfit'};
 for(const family of ['male','female']){
  const records=all.filter(r=>r.defaultSelectable && r['supports'+family[0].toUpperCase()+family.slice(1)]).map(r=>({record:r.record,slot:slots[r.slot],tweakDbId:r.tweakDbId,nonvisual:nonvisual.has(r.record)}));
  const result=await page.evaluate(async({family,records})=>{
   handlers['wardrobe:open']({available:true,characterKey:'coverage',revision:1,family,persistence:'ready',equipment:[],wardrobe:{active:false,outfits:[],names:[]}});
   for(let i=0;i<records.length;i+=64){handlers['wardrobe:catalogue']({items:records.slice(i,i+64),complete:i+64>=records.length});await new Promise(resolve=>setTimeout(resolve,0));}
   const seen=new Set(),missing=[];let searched=0;
   for(const slot of WardrobeModel.slots){
    const category=[...document.querySelectorAll('#slots button')].find(b=>b.textContent===WardrobeModel.labels[slot].toUpperCase());category.click();
    for(let pages=0;pages<100;pages++){
     for(const b of document.querySelectorAll('.choose'))seen.add(b.dataset.record);
     if(document.getElementById('next').disabled)break;
     document.getElementById('next').click();
    }
    for(const row of records.filter(r=>r.slot===slot && !r.nonvisual)){
     const input=document.getElementById('search');input.value=row.record;input.dispatchEvent(new Event('input'));
     if(![...document.querySelectorAll('.choose')].some(b=>b.dataset.record===row.record))missing.push(row.record);
     searched++;if(searched%64===0)await new Promise(resolve=>setTimeout(resolve,0));
    }
    const input=document.getElementById('search');input.value='';input.dispatchEvent(new Event('input'));
   }
   handlers['wardrobe:closed']({});return {paged:[...seen].sort(),missing,searched};
  },{family,records});
  assert.deepEqual(result.paged,records.filter(r=>!r.nonvisual).map(r=>r.record).sort(),family+' pagination must expose every record exactly');assert.deepEqual(result.missing,[],family+' full-record searches must reach every entry');assert.equal(result.searched,1804);console.log(family+': all 1804 exposed records reachable through pagination and search across 7 slots');
 }
 assert.deepEqual(errors,[]);await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
