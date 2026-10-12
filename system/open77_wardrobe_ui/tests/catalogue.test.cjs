const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
const root=path.resolve(__dirname,'../../../..');const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const raw=JSON.parse(read('docs/generated/clothing-2.31.json'));
const native=[...read('client/src/api/generated/ClothingCatalog.inl').matchAll(/CatalogEntry\{"([^"\n]+)", (0x[0-9A-F]+)ULL, Slot::(\w+), (\d+), "([^"]+)"\}/g)].map(m=>({record:m[1],hash:m[2],slot:m[3],flags:Number(m[4]),scope:m[5]}));
const server=[...read('resources/system/open77_appearance/server/catalog.lua').matchAll(/add\("([^"\n]+)", "(0x[0-9A-F]+)", "(\w+)", (\d+)\)/g)].map(m=>({record:m[1],hash:m[2],slot:m[3],flags:Number(m[4])}));
const slots={head:'Head',face:'Face',inner_chest:'InnerChest',outer_chest:'OuterChest',legs:'Legs',feet:'Feet',outfit:'Outfit'};
test('all 1991 audited records retain exact native and server identity, slots, family and selection policy',()=>{
 assert.equal(raw.items.length,1991);assert.equal(native.length,raw.items.length);assert.equal(server.length,raw.items.length);
 const n=new Map(native.map(x=>[x.record,x])),s=new Map(server.map(x=>[x.record,x]));assert.equal(n.size,1991);assert.equal(s.size,1991);
 for(const r of raw.items){const expected={record:r.record,hash:r.tweakDbId.toUpperCase(),slot:slots[r.slot],flags:(r.supportsMale?1:0)|(r.supportsFemale?2:0)|(r.defaultSelectable?4:0)};const nr=n.get(r.record),sr=s.get(r.record);assert.ok(nr && sr,r.record);assert.equal(nr.scope,r.catalogScope,r.record);assert.deepEqual({...nr,hash:nr.hash.toUpperCase(),scope:undefined},{...expected,scope:undefined},r.record);assert.deepEqual({...sr,hash:sr.hash.toUpperCase()},expected,r.record);}
});
test('every quest/story and expansion item remains selectable; only eight internal fixtures are restricted',()=>{
 const selectable=raw.items.filter(r=>r.defaultSelectable);assert.equal(selectable.length,1983);
 assert.equal(selectable.filter(r=>r.catalogScope==='quest_or_story').length,58);assert.ok(raw.items.filter(r=>r.catalogScope==='quest_or_story').every(r=>r.defaultSelectable));
 assert.equal(selectable.filter(r=>r.introducedIn==='tweakdb_ep1.bin').length,514);assert.ok(raw.items.filter(r=>r.introducedIn==='tweakdb_ep1.bin').every(r=>r.defaultSelectable));
 const restricted=raw.items.filter(r=>!r.defaultSelectable);assert.equal(restricted.length,8);assert.ok(restricted.every(r=>r.catalogScope==='test_or_debug'));
 assert.deepEqual(restricted.map(r=>r.record).sort(),['TEST.ItemPass_FaceArmor','TEST.ItemPass_FeetArmor','TEST.ItemPass_HeadArmor','Items.TestClothing','Items.TightJumpsuit_01_test_01','TEST.ItemPass_InnerChestArmor','TEST.ItemPass_LegArmor','TEST.ItemPass_OuterChestArmor'].sort());
});
for(const family of ['Male','Female'])test(family+' native allowlist retains 1968 compatible records before nonvisual filtering',()=>{
 const rows=raw.items.filter(r=>r.defaultSelectable && r['supports'+family]);assert.equal(rows.length,1968);assert.equal(rows.filter(r=>r.catalogScope==='quest_or_story').length,58);assert.equal(rows.filter(r=>r.introducedIn==='tweakdb_ep1.bin').length,499);
 const counts={};for(const r of rows)counts[slots[r.slot]]=(counts[slots[r.slot]] || 0)+1;assert.deepEqual(counts,{Face:173,Feet:211,Head:296,InnerChest:264,Legs:313,OuterChest:673,Outfit:38});
 const limit=Number(read('resources/system/open77_wardrobe_ui/client/main.lua').match(/equipment\.records\(\{family=value\.family, restricted=false, limit=(\d+)\}/)[1]);assert.ok(rows.length<=limit,'UI query must not truncate any family');
});

const empty=[...read('client/src/game/generated/EmptyClothing.inl').matchAll(/(0x[0-9A-F]+)ULL, \/\/ (Items\.[^\r\n]+)/g)].map(m=>({hash:m[1],record:m[2]}));
test('exact 164 nonvisual templates are classified separately without deleting legacy record identities',()=>{
 assert.equal(empty.length,164);const rawMap=new Map(raw.items.map(r=>[r.record,r]));
 for(const entry of empty){const r=rawMap.get(entry.record);assert.ok(r,entry.record);assert.equal(r.tweakDbId.toUpperCase(),entry.hash.toUpperCase());assert.equal(r.appearanceName,'None',entry.record);assert.equal(r.defaultSelectable,true,'legacy stored identity must remain accepted');}
 const hidden=new Set(empty.map(r=>r.record));
 for(const record of ['Items.Q005_Militech_Suit','Items.Q005_Militech_Suit_Dirty','Items.Q005_Militech_Suit_Filthy','Items.q115_thrusters','Items.q203_samurai_jacket'])assert.equal(hidden.has(record),false,'authored meshes and unresolved quest entities must remain reachable: '+record);const visual=raw.items.filter(r=>r.defaultSelectable && !hidden.has(r.record));assert.equal(visual.length,1819);assert.equal(visual.filter(r=>r.catalogScope==='quest_or_story').length,47);assert.equal(visual.filter(r=>r.introducedIn==='tweakdb_ep1.bin').length,504);
 for(const family of ['Male','Female']){const rows=visual.filter(r=>r['supports'+family]);assert.equal(rows.length,1804);const counts={};for(const r of rows)counts[slots[r.slot]]=(counts[slots[r.slot]] || 0)+1;assert.deepEqual(counts,{Face:153,Feet:195,Head:261,InnerChest:240,Legs:293,OuterChest:626,Outfit:36});}
});
