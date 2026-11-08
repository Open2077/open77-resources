(() => {
  'use strict';
  const $ = name => document.getElementById('idle-' + name), root = document.getElementById('page-animations');
  const banks = (window.FreeroamAnimationBanks || []).map(path => ({path, search:path.toLowerCase(), name:path.split('\\').pop().replace(/\.anims$/, '')}));
  let bankPage=0, clipPage=0, request=0, total=0, busy=false, loadedBank='', debounce;
  const size=30, emit=(action,data={})=>Open77.emit('idle:action',{action,...data});
  function status(message,error=false) { $('status').textContent=message; $('status').dataset.error=String(error); }
  function tab(idle) {
    $('panel').hidden=!idle; root.querySelector('.anim-library').hidden=idle; root.querySelector('.anim-player').hidden=idle;
    $('tab-emotes').setAttribute('aria-pressed',String(!idle)); $('tab-poses').setAttribute('aria-pressed',String(idle));
    if (idle) { renderBanks(); emit('state'); }
  }
  function renderBanks() {
    const words=$('search').value.toLowerCase().trim().split(/\s+/), filtered=banks.filter(b=>words.every(w=>b.search.includes(w)));
    bankPage=Math.min(bankPage,Math.max(0,Math.ceil(filtered.length/size)-1)); $('bank-list').replaceChildren();
    for (const bank of filtered.slice(bankPage*size,(bankPage+1)*size)) {
      const button=document.createElement('button'), name=document.createElement('strong'), path=document.createElement('small');
      button.type='button'; button.title=bank.path; button.setAttribute('aria-pressed',String(bank.path===$('bank').value));
      name.textContent=bank.name.replaceAll('_',' '); path.textContent=bank.path.split('\\').slice(-3,-1).join(' / ');
      button.append(name,path); button.addEventListener('click',()=>{ $('bank').value=bank.path; $('clip').value=''; $('clip-search').value=''; clipPage=0; renderBanks(); load(); }); $('bank-list').append(button);
    }
    $('bank-count').textContent=`${filtered.length.toLocaleString()} banks · ${bankPage+1}/${Math.max(1,Math.ceil(filtered.length/size))}`;
    $('bank-prev').disabled=bankPage===0; $('bank-next').disabled=(bankPage+1)*size>=filtered.length;
  }
  function load() {
    const bank=$('bank').value.trim(); if (!bank) { status('Choose a bank or paste its depot path.',true); return; }
    request++; loadedBank=bank; $('clip-list').replaceChildren(); const p=document.createElement('p'); p.textContent='Reading clips from the game…'; $('clip-list').append(p);
    $('clip-prev').disabled=$('clip-next').disabled=true;
    emit('clips',{request,bank,query:$('clip-search').value,offset:clipPage*size});
  }
  function buttons() { $('apply').disabled=busy; $('reset').disabled=busy; }
  $('tab-emotes').addEventListener('click',()=>tab(false)); $('tab-poses').addEventListener('click',()=>tab(true));
  $('search').addEventListener('input',()=>{bankPage=0;renderBanks();});
  $('bank-prev').addEventListener('click',()=>{bankPage--;renderBanks();}); $('bank-next').addEventListener('click',()=>{bankPage++;renderBanks();});
  $('load').addEventListener('click',()=>{clipPage=0;load();}); $('bank').addEventListener('keydown',e=>{if(e.key==='Enter'){clipPage=0;load();}});
  $('clip-search').addEventListener('input',()=>{clearTimeout(debounce);debounce=setTimeout(()=>{clipPage=0;load();},250);});
  $('clip-prev').addEventListener('click',()=>{clipPage--;load();}); $('clip-next').addEventListener('click',()=>{clipPage++;load();});
  $('apply').addEventListener('click',()=>{
    const animset=$('bank').value.trim(), clip=$('clip').value.trim();
    if (!animset || !clip) {status('Enter a bank path and a clip name first.',true);return;}
    if (!$('blend').reportValidity() || !$('delay').reportValidity()) return;
    busy=true;buttons();status('Applying idle…');emit('apply',{animset,clip,blendMs:Number($('blend').value),delayMs:Number($('delay').value)});
  });
  $('reset').addEventListener('click',()=>{busy=true;buttons();status('Restoring default idle…');emit('reset');});
  Open77.on('idle:clips',r=>{
    if (!r || r.request!==request || r.bank!==loadedBank) return;
    $('clip-list').replaceChildren(); total=r.total||0;
    if (r.error) {const p=document.createElement('p');p.textContent=r.error;$('clip-list').append(p);status(r.error,true);}
    else for (const clip of r.clips||[]) {
      const button=document.createElement('button'), name=document.createElement('span'), duration=document.createElement('small');button.type='button';
      name.textContent=clip.name;duration.textContent=Number(clip.duration).toFixed(2)+' s';button.append(name,duration);button.setAttribute('aria-pressed',String($('clip').value===clip.name));
      button.addEventListener('click',()=>{ $('clip').value=clip.name; for(const b of $('clip-list').children)b.setAttribute('aria-pressed',String(b===button)); });$('clip-list').append(button);
    }
    if (!r.error && !total) {const p=document.createElement('p');p.textContent='No clips match this search.';$('clip-list').append(p);}
    $('clip-count').textContent=`${total} clips · ${clipPage+1}/${Math.max(1,Math.ceil(total/size))}`;
    $('clip-prev').disabled=clipPage===0; $('clip-next').disabled=(clipPage+1)*size>=total;
  });
  Open77.on('idle:state',r=>{
    if (!r) return; busy=false;buttons(); if(r.error){status(r.error,true);return;}
    const s=r.state; status(s?`${s.options.clip} · ${s.status||'selected'}`:'Default idle · No custom pose selected');
  });
  // Poll only while this panel is visible; a selected pose keeps working with the UI closed.
  setInterval(()=>{if (!$('panel').hidden && document.getElementById('freeroam-menu').classList.contains('open'))emit('state');},1500);
  renderBanks();
})();
