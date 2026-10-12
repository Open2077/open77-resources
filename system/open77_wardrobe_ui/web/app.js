(function() {
  "use strict";
  const M=WardrobeModel, $=id=>document.getElementById(id), emit=(name,value={})=>Open77.emit(name,value);
  let baseline, draft, confirmed, catalogue=[], lookup={}, mode="equipment", outfit=0, slot="Head", page=0, yaw=180;
  let busy=false, previewPending=false, pendingConfirm=null, favoritesOnly=false, favoritesReady=false, favorites=new Set();
  const PAGE_SIZE=24;
  const errors={save_timeout:"The server has not confirmed the save. You can retry; your draft is still here.",presentation_revision_conflict:"Your saved wardrobe changed elsewhere. The latest saved look has been restored. Please try your changes again.",revision_conflict:"Your saved wardrobe changed elsewhere. The latest saved look has been restored.",presentation_database_error:"Your look could not be saved. Your previous saved wardrobe is safe.",incompatible_body_family:"This item does not fit your current body type.",restricted_record:"This clothing item is not available on this server.",item_unavailable:"This clothing item is unavailable. Your last preview has been restored.",presentation_character_changed:"Your character changed. Close the wardrobe and open it again."};
  function message(text,kind="") { $("status").textContent=text; $("status").className="status "+kind; }
  function reason(text) { return errors[text] || "Could not apply this change ("+String(text || "unknown error").replace(/_/g," ")+")."; }
  function visualValue(value) { return value && (lookup[String(value).toLowerCase()] || {}).nonvisual === true ? false : value; }
  function itemName(value) { value=visualValue(value);return value ? M.title((lookup[String(value).toLowerCase()] || {}).record || value) : "No item equipped"; }
  function currentSlots() { return mode==="equipment"?draft.equipment:draft.wardrobe.outfits[outfit]; }
  function editSlot(value) {
    currentSlots()[slot]=value;
    if(mode==="outfits") draft.wardrobe.active=outfit;
    else {
      // Editing worn clothing must show the selected garment, not an overlay
      // or a full-body suit covering it. These remain unsaved draft changes.
      draft.wardrobe.active=false;
      if(slot!=="Outfit") draft.equipment.Outfit=false;
    }
  }
  function canonical(value) { return value ? ((lookup[String(value).toLowerCase()] || {}).record || value) : value; }
  function dirty() { return baseline && M.dirty(baseline,draft); }
  function updateControls() {
    const changed=dirty();
    $("saved-state").textContent=busy?"SAVING":changed?"UNSAVED PREVIEW":"SAVED";
    $("saved-state").className=changed?"dirty":"";
    $("save").disabled=busy || previewPending || !changed;
    $("save").textContent=busy?"SAVING":"SAVE CHANGES";
    document.querySelectorAll(".item .choose,.slot-actions button,.outfit-actions button,#rename,#disable-overlay").forEach(el=>el.disabled=busy || previewPending);
  }
  function preview(change, text) {
    if(busy || previewPending) return;
    confirmed=M.clone(draft);
    change();
    previewPending=true;
    emit("wardrobe:preview",{equipment:draft.equipment,wardrobe:draft.wardrobe});
    render();
    message(text || "Trying on. Save changes to keep this look.");
  }
  function confirmAction(title,text,action,label="DISCARD") {
    $("confirm-title").textContent=title;$("confirm-text").textContent=text;
    $("confirm-yes").textContent=label;$("confirm").hidden=false;pendingConfirm=action;$("confirm-no").focus();
  }
  function requestClose() {
    if(busy) { confirmAction("SAVE STILL PENDING","The server may still complete your save after closing. Close the fitting room?",()=>emit("wardrobe:close"),"CLOSE"); return; }
    if(dirty()) confirmAction("DISCARD CHANGES?","Your unsaved preview will be removed and your last saved look restored.",()=>emit("wardrobe:close"));
    else emit("wardrobe:close");
  }
  function renderItems() {
    const q=$("search").value.trim().toLowerCase();
    const entries=catalogue.filter(item=>item.slot===slot && (!favoritesOnly || favorites.has(item.record)) && (!q || (M.title(item.record)+" "+item.record).toLowerCase().includes(q)));
    const maxPage=Math.max(0,Math.ceil(entries.length/PAGE_SIZE)-1);page=Math.min(page,maxPage);
    const grid=$("catalogue");grid.replaceChildren();
    entries.slice(page*PAGE_SIZE,(page+1)*PAGE_SIZE).forEach(item=>{
      const row=document.createElement("div");row.className="item";row.setAttribute("role","listitem");
      const selected=canonical(currentSlots()[slot])===item.record;row.classList.toggle("selected",selected);
      const choose=document.createElement("button");choose.className="choose catalog-card";choose.dataset.record=item.record;choose.setAttribute("aria-pressed",String(selected));
      choose.title=M.title(item.record);const title=document.createElement("strong");title.textContent=M.title(item.record);
      const subtitle=document.createElement("small");subtitle.textContent=selected?"SELECTED":M.labels[item.slot].toUpperCase();
      choose.append(title,subtitle);choose.onclick=()=>preview(()=>editSlot(item.record));
      const favorite=document.createElement("button");favorite.className="favorite";favorite.classList.toggle("on",favorites.has(item.record));favorite.textContent=favorites.has(item.record)?"★":"☆";
      favorite.setAttribute("aria-label",(favorites.has(item.record)?"Remove favorite ":"Favorite ")+M.title(item.record));
      favorite.disabled=!favoritesReady;favorite.onclick=()=>{favoritesReady=false;document.querySelectorAll(".favorite").forEach(button=>button.disabled=true);emit("wardrobe:favorite",{record:item.record,enabled:!favorites.has(item.record)});};
      row.append(choose,favorite);grid.append(row);
    });
    if(!entries.length){const empty=document.createElement("p");empty.className="empty";empty.textContent=favoritesOnly?"No favorites in this category. Star clothing to keep it here.":"No matching clothing. Try another search or category.";grid.append(empty);}
    $("count").textContent=entries.length?`${page*PAGE_SIZE+1}–${Math.min(entries.length,(page+1)*PAGE_SIZE)} / ${entries.length} ITEMS`:"0 ITEMS";
    $("previous").disabled=page===0;$("next").disabled=page===maxPage;
  }
  function render() {
    if(!draft)return;
    for(const name of ["equipment","outfits"]){$(name+"-tab").classList.toggle("selected",mode===name);$(name+"-tab").setAttribute("aria-pressed",String(mode===name));}
    $("outfit-tools").hidden=mode!=="outfits";
    const outfits=$("outfits");outfits.replaceChildren();
    for(let i=0;i<7;i++){const b=document.createElement("button");b.textContent=String(i+1).padStart(2,"0");b.title=draft.wardrobe.names[i];b.setAttribute("aria-label",draft.wardrobe.names[i]);b.classList.toggle("selected",i===outfit);b.classList.toggle("active",draft.wardrobe.active===i);b.onclick=()=>{outfit=i;render();};outfits.append(b);}
    $("outfit-name").value=draft.wardrobe.names[outfit];
    const active=draft.wardrobe.active;$("overlay-banner").hidden=active===false;
    $("overlay-text").textContent=active===false?"":"Wearing “"+draft.wardrobe.names[active]+"” over equipment.";
    $("wear").textContent=active===outfit?"OUTFIT ACTIVE":"WEAR OUTFIT";
    const nav=$("slots");nav.replaceChildren();
    M.slots.forEach(name=>{const b=document.createElement("button");b.textContent=M.labels[name].toUpperCase();b.classList.toggle("selected",name===slot);b.setAttribute("aria-pressed",String(name===slot));b.onclick=()=>{slot=name;page=0;render();};nav.append(b);});
    $("slot-label").textContent=M.labels[slot].toUpperCase();
    const value=visualValue(currentSlots()[slot]);$("selected-name").textContent=mode==="outfits" && value===undefined?"Use equipment · "+itemName(draft.equipment[slot]):mode==="outfits" && value===false?"Hidden in this outfit":itemName(value);
    $("inherit").hidden=mode!=="outfits";$("remove").textContent=mode==="outfits"?"HIDE SLOT":"REMOVE";
    $("semantics").textContent=mode==="outfits"?"Hide slot shows nothing. Use equipment lets your worn clothing show through.":"Equipment is what your character wears underneath an outfit.";
    renderItems();updateControls();
  }
  for(const name of ["equipment","outfits"]) $(name+"-tab").onclick=()=>{mode=name;page=0;render();};
  $("search").oninput=()=>{page=0;renderItems();updateControls();};$("filter").onclick=()=>{favoritesOnly=!favoritesOnly;$("filter").textContent=favoritesOnly?"FAVORITES":"ALL CLOTHING";$("filter").setAttribute("aria-pressed",String(favoritesOnly));page=0;renderItems();updateControls();};
  $("previous").onclick=()=>{page--;renderItems();updateControls();};$("next").onclick=()=>{page++;renderItems();updateControls();};
  $("remove").onclick=()=>preview(()=>editSlot(false));
  $("inherit").onclick=()=>preview(()=>{delete currentSlots()[slot];draft.wardrobe.active=outfit;});
  $("wear").onclick=()=>preview(()=>{draft.wardrobe.active=outfit;});
  $("disable-overlay").onclick=()=>preview(()=>{draft.wardrobe.active=false;});
  $("capture").onclick=()=>preview(()=>{const items={};for(const s of M.slots)items[s]=visualValue(draft.equipment[s]) || false;draft.wardrobe.outfits[outfit]=items;draft.wardrobe.active=outfit;},"Worn clothing copied into this outfit. Save changes to keep it.");
  $("delete").onclick=()=>confirmAction("RESET THIS OUTFIT?","This clears its clothing and name. Your equipped items stay in place. Save changes to keep the reset.",()=>preview(()=>{draft.wardrobe.outfits[outfit]={};draft.wardrobe.names[outfit]=`Outfit ${outfit+1}`;if(draft.wardrobe.active===outfit)draft.wardrobe.active=false;}),"RESET OUTFIT");
  $("rename").onclick=()=>{const name=$("outfit-name").value.trim();if(!name || [...name].length>48 || /[\x00-\x1f\x7f]/.test(name)){message("Use an outfit name between 1 and 48 characters.","error");return;}draft.wardrobe.names[outfit]=name;render();message("Name updated. Save changes to keep it.");};
  $("outfit-name").onkeydown=e=>{if(e.key==="Enter"){e.preventDefault();$("rename").click();}};
  $("save").onclick=()=>{if(busy || previewPending || !dirty())return;busy=true;updateControls();message("Saving your look…");emit("wardrobe:save",M.patch(baseline,draft));};
  $("close").onclick=requestClose;$("cancel").onclick=requestClose;
  $("confirm-no").onclick=()=>{$("confirm").hidden=true;pendingConfirm=null;$("cancel").focus();};
  $("confirm-yes").onclick=()=>{const action=pendingConfirm;$("confirm").hidden=true;pendingConfirm=null;if(action)action();};
  function rotate(degrees){yaw=((degrees+180)%360+360)%360-180;emit("wardrobe:orbit",{degrees:yaw});}
  $("front").onclick=()=>rotate(180);$("back").onclick=()=>rotate(0);$("rotate-left").onclick=()=>rotate(yaw-45);$("rotate-right").onclick=()=>rotate(yaw+45);
  for(const name of ["appearance","barber"]) $(name).onclick=()=>{if(busy)return;const action=()=>emit("wardrobe:appearance",{mode:name});if(dirty())confirmAction("DISCARD CHANGES?","Opening the appearance editor restores your saved clothing and discards this preview.",action);else action();};
  let lastActivitySent=-Infinity;
  function activity(){
    if($("room").hidden)return;
    const now=performance.now();
    if(now-lastActivitySent<2000)return;
    lastActivitySent=now;emit("wardrobe:activity");
  }
  for(const name of ["keydown","pointerdown","input","wheel"])
    document.addEventListener(name,activity,{capture:true,passive:true});
  document.addEventListener("keydown",e=>{
    if($("room").hidden)return;
    if(e.key==="Escape"){e.preventDefault();if(!$("confirm").hidden)$("confirm-no").click();else requestClose();}
    if(e.key==="Tab"){const root=$("confirm").hidden?$("room"):$("confirm");const focusable=[...root.querySelectorAll("button:not(:disabled),input,select")].filter(el=>el.offsetParent!==null);const first=focusable[0],last=focusable[focusable.length-1];if(e.shiftKey && document.activeElement===first){e.preventDefault();last?.focus();}else if(!e.shiftKey && document.activeElement===last){e.preventDefault();first?.focus();}}
  });
  Open77.on("wardrobe:open",value=>{
    baseline=M.normalize(value);draft=M.clone(baseline);catalogue=(value.catalogue || []).filter(item=>item.nonvisual !== true);lookup={};
    (value.catalogue || []).forEach(item=>{lookup[item.record.toLowerCase()]=item;if(item.tweakDbId)lookup[item.tweakDbId.toLowerCase()]=item;});
    busy=false;previewPending=false;favoritesReady=false;favorites=new Set();confirmed=null;mode="equipment";outfit=draft.wardrobe.active===false?0:draft.wardrobe.active;slot="Head";page=0;yaw=180;
    $("search").value="";favoritesOnly=false;$("filter").textContent="ALL CLOTHING";$("filter").setAttribute("aria-pressed","false");$("room").hidden=false;$("confirm").hidden=true;
    $("family").textContent=(value.family || "").toUpperCase()+" · "+(value.persistence==="ready"?"CHARACTER WARDROBE":"SESSION WARDROBE");
    $("camera-controls").hidden=!value.orbitAvailable;render();$("search").focus();message("Loading clothing catalogue…");
  });
  Open77.on("wardrobe:favorites",value=>{
    if(!draft)return;
    favorites=new Set(Array.isArray(value.items)?value.items:[]);favoritesReady=value.available===true;
    renderItems();updateControls();
    if(value.error)message(value.error==="favorite_limit"?"You can save up to 256 favorites.":"Favorites could not be saved on this device. Try again after reconnecting.","error");
  });
  Open77.on("wardrobe:catalogue",value=>{
    if(!draft)return;
    const first=catalogue.length===0;
    for(const item of value.items || []){if(item.nonvisual !== true)catalogue.push(item);lookup[item.record.toLowerCase()]=item;if(item.tweakDbId)lookup[item.tweakDbId.toLowerCase()]=item;}
    if(value.complete){catalogue.sort((a,b)=>M.title(a.record).localeCompare(M.title(b.record)));render();if(!dirty())message("Select clothing to try it on. Save when your look is ready.");}
    else if(first)render();
  });
  Open77.on("wardrobe:closed",()=>{$("room").hidden=true;$("confirm").hidden=true;baseline=null;draft=null;busy=false;previewPending=false;});
  Open77.on("wardrobe:status",value=>message(value.message,value.kind));
  Open77.on("wardrobe:previewResult",value=>{if(!draft)return;previewPending=false;if(!value.ok && confirmed){draft=confirmed;message(reason(value.reason),"error");}confirmed=null;render();});
  Open77.on("wardrobe:saveFailed",value=>{busy=false;updateControls();message(reason(value.reason),"error");});
  Open77.on("wardrobe:committed",value=>{if(!draft)return;busy=false;baseline=M.normalize(value.state);draft=M.clone(baseline);render();message(value.ok?"Your look is saved.":reason(value.reason),value.ok?"success":"error");});
  Open77.on("wardrobe:probe",()=>emit("wardrobe:ready"));
  Open77.ready();
  emit("wardrobe:ready");
})();
