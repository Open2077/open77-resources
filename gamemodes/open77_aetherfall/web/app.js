/* HUD presentation only: no damage, mana regeneration or cast decisions here. */
(() => {
  'use strict';
  const $=id=>document.getElementById(id), ns='http://www.w3.org/2000/svg';
  const icons={
    bolt:'<path d="M29 3 11 25l11-2-4 22 20-28-12 4z"/><path d="m9 16-4 6m29 11-5 8M34 7l5-4"/>',
    lance:'<path d="m9 41 29-34M5 44l13-7-9-8-4 15ZM38 7l-5 12-7-6 12-6Z"/><path d="m14 12 3 4m17 12 4 3M24 2v6M3 24h6"/>',
    nova:'<path d="M24 3c5 11 3 13 10 16 9 6 9 20-2 23 2-9-3-12-7-17 1 8-8 10-7 18C5 40 7 29 13 23c6-6 7-12 11-20Z"/>',
    ward:'<path d="m24 3 17 8-2 19-15 14L9 30 7 11Z"/><path d="m24 10 10 5-2 13-8 8-8-8-2-13Z M24 10v26m-10-21 10 9 10-9"/>',
    star:'<path d="m24 3 5 15 15 6-15 6-5 15-5-15-15-6 15-6Z"/><circle cx="24" cy="24" r="13"/><path d="m7 7 6 6m22 22 6 6M41 7l-6 6M13 35l-6 6"/>'
  };
  let config={spells:[],arena:{center:{x:2570,y:113},radius:19}},state=null,received=0,lastRevision=-1;
  let noticeUntil=0,feed=[],spellNodes=new Map(),rosterKey='';
  let visiblePanel=null;
  const num=(v,f=0)=>Number.isFinite(v)?v:f;
  const keyLabel=key=>key==='MOUSE1'?'LMB':key==='MOUSE2'?'RMB':String(key||'');
  function setPanel(value){
    visiblePanel=state?.self&&['spellbook','standings','menu'].includes(value?.id)?value.id:null;
    for(const id of ['spellbook','standings','menu'])$(id).hidden=visiblePanel!==id;
    document.body.dataset.panel=visiblePanel||'';
    if(visiblePanel==='menu')renderMenu();
  }
  // The Conclave menu: the duel queue and what this mage may do now (the server decides).
  function renderMenu(){
    const lobby=state?.lobby||{},inDuel=state?.arena==='duel',names=Array.isArray(lobby.queue)?lobby.queue:[];
    const me=state?.roster?.find(p=>p.id===state.self?.id)?.name;
    $('menu-queue').replaceChildren();
    if(!names.length){const li=document.createElement('li');li.className='empty';li.textContent='No mage is waiting yet.';$('menu-queue').append(li);}
    for(const name of names){const li=document.createElement('li');li.textContent=name;if(name===me)li.className='self';$('menu-queue').append(li);}
    $('menu-eyebrow').textContent=inDuel?'IN THE CONCLAVE':'TRAINING GROUNDS';
    let status='';
    if(inDuel)status='A duel is under way. Leaving returns you to the training grounds.';
    else if(lobby.duel)status=`A duel is under way (${lobby.duel.players} mages, round ${Math.max(1,num(lobby.duel.round))}). Wait for it to end to start yours.`;
    else if(lobby.canStart)status='Enough mages are waiting: you may start the duel.';
    else if(lobby.queued)status=`Waiting for ${Math.max(0,num(lobby.minPlayers,2)-names.length)} more mage(s).`;
    else status='Join the queue to duel. Meanwhile, practise on the dummies.';
    $('menu-status').textContent=status;
    $('menu-queue-join').hidden=inDuel||!!lobby.queued;
    $('menu-queue-leave').hidden=inDuel||!lobby.queued;
    $('menu-start').hidden=inDuel;$('menu-start').disabled=!lobby.canStart;
    $('menu-reset').hidden=inDuel;$('menu-forfeit').hidden=!inDuel;
    const own=state?.self;
    $('menu-training').textContent=inDuel?'':own?`Training: ${Math.round(num(own.damage))} damage dealt in ${num(own.hits)} hits, ${num(own.kills)} dummies brought down.`:'';
  }
  function menuAction(action){
    if(!window.Open77)return;
    if(action==='close')Open77.emit('aetherfall:menu:close',{});
    else Open77.emit('aetherfall:menu:action',{action});
  }
  document.addEventListener('click',e=>{const b=e.target.closest?.('.menu-actions button');if(b&&!b.disabled&&visiblePanel==='menu')menuAction(b.dataset.action);});
  document.addEventListener('keydown',e=>{
    if(visiblePanel!=='menu'||!window.Open77)return;
    const key=String(config.panels?.menu||'N').toLowerCase();
    if(e.key==='Escape'||e.key.toLowerCase()===key){e.preventDefault();Open77.emit('aetherfall:menu:close',{});}
  });
  function renderSpellbook(){
    $('spellbook-list').replaceChildren();
    for(const spell of config.spells){
      const row=document.createElement('article');row.className='spell-entry';
      row.style.setProperty('--spell-color',spell.color);
      row.innerHTML='<div class="book-icon"><svg viewBox="0 0 48 48">'+(icons[spell.icon]||icons.star)+'</svg><kbd></kbd></div><div class="book-description"><h3></h3><p></p></div><div class="book-cost"><b></b><span></span></div>';
      row.querySelector('kbd').textContent=keyLabel(spell.key);
      row.querySelector('h3').textContent=spell.name;
      row.querySelector('.book-description p').textContent=spell.description||'';
      row.querySelector('.book-cost b').textContent=spell.cost?spell.cost+' AETHER':'FREE';
      row.querySelector('.book-cost span').textContent=(spell.cooldownMs/1000)+' SEC';
      $('spellbook-list').append(row);
    }
    const book=keyLabel(config.panels?.spellbook||'H'),standings=keyLabel(config.panels?.standings||'K'),menu=keyLabel(config.panels?.menu||'N');
    $('book-key').textContent=book;$('standings-key').textContent=standings;
    $('menu-key').textContent=menu;$('menu-close-hint').textContent=menu+' · CLOSE';
    $('book-close').textContent=book+' · CLOSE';$('standings-close').textContent=standings+' · CLOSE';
  }
  function renderStandings(){
    $('standings-body').replaceChildren();
    const sorted=[...(state?.roster||[])].sort((a,b)=>num(b.wins)-num(a.wins)||num(b.kills)-num(a.kills)||num(b.damage)-num(a.damage)||a.id-b.id);
    for(const p of sorted){
      const row=document.createElement('tr');if(p.id===state.self?.id)row.className='self';
      const status=!p.ready?'ARRIVING':state.phase==='waiting'?'WAITING':
        p.alive?(state.phase==='active'?'DUELING':'READY'):(state.phase==='active'?'ELIMINATED':'NEXT ROUND');
      for(const value of [p.name,num(p.wins),num(p.kills)+' / '+num(p.deaths),Math.round(num(p.damage)),status]){
        const cell=document.createElement('td');cell.textContent=value;row.append(cell);
      }
      $('standings-body').append(row);
    }
  }
  function configure(value){
    if(!value||!Array.isArray(value.spells))return;
    config=value; $('abilities').replaceChildren();spellNodes.clear();
    for(const spell of config.spells){
      const el=document.createElement('div');el.className='spell'+(spell.id==='cataclysm'?' ultimate':'');
      el.dataset.spell=spell.id;el.style.setProperty('--spell-color',spell.color);
      el.setAttribute('aria-label',spell.name+': '+spell.description);
      // All SVG paths are local constants. Server names/key labels use textContent.
      el.innerHTML='<div class="icon"><svg viewBox="0 0 48 48">'+(icons[spell.icon]||icons.star)+'</svg></div><div class="cooldown"></div><div class="seconds"></div><span class="key"></span><span class="cost"></span>';
      el.querySelector('.key').textContent=spell.key==='MOUSE1'?'LMB':spell.key==='MOUSE2'?'RMB':spell.key;
      el.querySelector('.cost').textContent=spell.cost||'';
      $('abilities').append(el);spellNodes.set(spell.id,el);
    }
    renderSpellbook();
  }
  function adopt(value){
    if(!value||typeof value.phase!=='string')return;
    if(value.phase==='off'){state=null;lastRevision=-1;rosterKey='';setPanel(null);document.body.dataset.active='false';return;}
    if(num(value.revision)<lastRevision)return;
    // A new instance (training grounds <-> duel) restarts its own revision count.
    if(state&&state.arena!==value.arena)lastRevision=-1;
    lastRevision=num(value.revision);state=value;received=performance.now();
    document.body.dataset.active=String(!!value.self);
    document.body.dataset.practice=String(!!value.practice);
    renderRoster();
    if(visiblePanel==='menu')renderMenu();
  }
  function renderRoster(){
    const roster=Array.isArray(state?.roster)?state.roster:[],self=state?.self?.id;
    const key=JSON.stringify([state.phase,self,roster.map(p=>[p.id,p.name,p.wins,p.kills,p.deaths,p.damage,p.alive,p.hp,p.shield,p.ready])]);
    if(key!==rosterKey){
      rosterKey=key;$('roster').replaceChildren();
      for(const p of roster){
        const row=document.createElement('div');row.className='mage'+(p.id===self?' self':'')+(!p.alive?' dead':'');
        row.innerHTML='<span class="sigil">✧</span><span class="name"></span><span class="points"></span><i class="hp"></i>';
        row.querySelector('.name').textContent=p.name;row.querySelector('.points').textContent=p.wins;
        row.querySelector('.hp').style.width=(Math.max(0,Math.min(1,p.hp/p.maxHp))*100)+'%';
        $('roster').append(row);
      }
      renderStandings();
    }
    $('map-players').replaceChildren();
    for(const p of roster){
      if(!p.position||!p.ready)continue;
      const marker=document.createElementNS(ns,'circle');marker.setAttribute('class','map-player');
      marker.setAttribute('cx',String(num(p.position.x)-config.arena.center.x));
      marker.setAttribute('cy',String(-(num(p.position.y)-config.arena.center.y)));
      marker.setAttribute('r',p.id===self?'1.2':'.9');marker.setAttribute('fill',p.id===self?'#a9f8dc':p.alive?'#d5b6fc':'#677080');
      $('map-players').append(marker);
    }
    const me=roster.find(p=>p.id===self);
    if(me){$('player-name').textContent=me.name;$('score').textContent=me.kills+' / '+me.deaths;
      $('damage').textContent=Math.round(me.damage);$('wins').textContent=me.wins+' / '+state.firstTo;}
  }
  function flash(id){const el=$(id);el.classList.remove('flash');void el.offsetWidth;el.classList.add('flash');}
  function event(value){
    if(!state||!value)return;
    if(value.kind==='hit'){
      if(value.attacker===state.self?.id){flash('hitmarker');showNotice(value.absorbed>0?`${value.absorbed} absorbed · ${value.amount} damage`:`${value.amount} damage`,800);}
      if(value.player===state.self?.id&&value.amount>0)flash('damage-vignette');
    }
    if(value.kind==='cast'&&value.player===state.self?.id){
      const el=spellNodes.get(value.spell);if(el){el.classList.add('casting');setTimeout(()=>el.classList.remove('casting'),220);}
    }
    if(value.kind==='eliminated'){
      const names=new Map([...state.roster,...(state.dummies||[])].map(p=>[p.id,p.name]));
      feed.unshift({at:performance.now(),winner:names.get(value.attacker)||'The seal',loser:names.get(value.player)||'Mage'});
      feed=feed.slice(0,4);paintFeed();
    }
  }
  function paintFeed(){
    $('feed').replaceChildren();
    for(const entry of feed){const el=document.createElement('div');el.className='feed-entry';
      const a=document.createElement('strong'),b=document.createElement('b');a.textContent=entry.winner;b.textContent=entry.loser;
      el.append(a,document.createTextNode('  ✧  '),b);$('feed').append(el);}
  }
  function showNotice(text,duration=2200){$('notice').textContent=String(text||'');noticeUntil=performance.now()+duration;}
  const refusal={mana:'Not enough aether',cooldown:'Spell is recharging',casting:'Finish your incantation',position_unavailable:'Waiting for your world position'};
  function frame(){
    const now=performance.now();
    if(now>noticeUntil)$('notice').textContent='';
    if(feed.some(entry=>now-entry.at>6500)){feed=feed.filter(entry=>now-entry.at<=6500);paintFeed();}
    if(state?.self){
      const own=state.self,elapsed=Math.max(0,now-received),stale=elapsed>2500;
      const remaining=Math.max(0,num(state.remainingMs)-elapsed);
      const practice=!!state.practice;
      $('round').textContent=practice?'TRAINING':'ROUND '+Math.max(1,num(state.round));
      $('format').textContent=practice?((state.dummies||[]).filter(d=>d.alive).length+' DUMMIES STANDING'):'FIRST TO '+num(state.firstTo,3);
      const seconds=Math.ceil(remaining/1000);
      $('clock').textContent=practice||state.phase==='waiting'||state.phase==='finished'?'—':`${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;
      $('phase').textContent=practice?(state.lobby?.duel?'A DUEL IS UNDER WAY':state.lobby?.queued?'IN THE DUEL QUEUE':'TRAINING GROUNDS'):
        ({waiting:'GATHERING MAGES',preparing:'ENTERING THE CONCLAVE',countdown:'PREPARE YOUR SPELLS',active:'DUEL IN PROGRESS',intermission:'ROUND COMPLETE',results:'CONCLAVE COMPLETE',finished:'RETURNING TO THE GROUNDS'})[state.phase]||'';
      $('health-fill').style.width=100*Math.max(0,Math.min(1,own.hp/own.maxHp))+'%';
      $('shield-fill').style.width=100*Math.min(.5,num(own.shield)/own.maxHp)+'%';
      $('health-label').textContent=Math.ceil(own.hp)+' / '+own.maxHp+(own.shield?' + '+own.shield:'');
      $('mana-fill').style.width=100*Math.max(0,Math.min(1,own.mana/own.maxMana))+'%';
      $('mana-label').textContent=Math.floor(own.mana)+' / '+own.maxMana;
      $('connection').textContent=stale?'WAITING FOR SERVER':'CONCLAVE LINKED';
      const casting=Math.max(0,num(own.castMs)-elapsed);$('castbar').style.opacity=casting>0?'1':'0';
      $('castbar').firstElementChild.style.width=Math.min(100,casting/1700*100)+'%';
      for(const spell of config.spells){
        const el=spellNodes.get(spell.id);if(!el)continue;
        const cd=Math.max(0,num(own.cooldowns?.[spell.id])-elapsed);
        el.querySelector('.cooldown').style.transform=`scaleY(${Math.min(1,cd/spell.cooldownMs)})`;
        el.querySelector('.seconds').textContent=cd>0?(cd<1000?(cd/1000).toFixed(1):Math.ceil(cd/1000)):'';
        el.classList.toggle('disabled',own.mana<spell.cost||!own.alive||(state.phase!=='active'&&!practice)||stale);
      }
      const winner=state.roster.find(p=>p.id===state.winner)?.name||'The Conclave';
      let eyebrow='',title='',detail='';
      if(stale){eyebrow='CONNECTION INTERRUPTED';title='The weave is holding';detail='Waiting for authoritative arena state.';}
      else if(practice){/* The training grounds: no announcement; the Conclave menu says the rest. */}
      else if(state.phase==='finished'){eyebrow='THE CONCLAVE CLOSES';title=state.winner?winner:'A celestial stalemate';detail='Returning to the training grounds.';}
      else if(state.phase==='waiting'){eyebrow='THE GATES ARE OPEN';title='A challenger awaits';detail='A second mage must enter to begin. First to three round victories.';}
      else if(state.phase==='preparing'){eyebrow='THE ASTRAL CONCLAVE';title='Taking your place';detail='The duel begins when every mage has arrived.';}
      else if(state.phase==='countdown'){eyebrow='ROUND '+state.round;title=String(Math.max(1,Math.ceil(remaining/1000)));detail=config.spells.map(s=>(s.key==='MOUSE1'?'LMB':s.key==='MOUSE2'?'RMB':s.key)+' '+s.name).join(' · ');}
      else if(state.phase==='intermission'||state.phase==='results'){eyebrow=state.phase==='results'?'CONCLAVE CHAMPION':'ROUND COMPLETE';title=state.winner?winner:'A celestial stalemate';detail=state.phase==='results'?'The stars have chosen. A new conclave begins shortly.':'Gather your aether. The next round approaches.';}
      else if(!own.alive){eyebrow='YOUR WEAVE IS BROKEN';title='Eliminated';detail='Watch the remaining mages. You return next round.';}
      else if(own.outsideMs!=null){eyebrow='RETURN TO THE SEAL';title=(Math.max(0,own.outsideMs-elapsed)/1000).toFixed(1);detail='The outer void consumes all magic.';}
      $('announcement-eyebrow').textContent=eyebrow;$('announcement-title').textContent=title;$('announcement-detail').textContent=detail;
      $('announcement').style.opacity=title?'1':'0';
    }
    requestAnimationFrame(frame);
  }
  if(window.Open77){
    Open77.on('aetherfall:config',configure);Open77.on('aetherfall:state',adopt);Open77.on('aetherfall:event',event);
    Open77.on('aetherfall:notice',value=>showNotice(value?.text));
    Open77.on('aetherfall:panel',setPanel);
    Open77.on('aetherfall:refused',value=>{if(refusal[value?.reason])showNotice(refusal[value.reason]);});
    Open77.ready();
  }
  // Explicit browser art-direction preview. Never enabled by the in-game bridge.
  if(!window.Open77&&new URLSearchParams(location.search).has('preview')){
    document.body.classList.add('preview');$('preview-label').hidden=false;
    const descriptions={bolt:'A swift ember. Lead moving targets.',lance:'A piercing arc of astral energy. 48 damage.',
      nova:'Mark a circle ahead. It erupts after a short warning.',ward:'Absorb 65 damage for 2.2 seconds. Time it against a lance.',
      cataclysm:'Call down a falling star. A wide warning precedes 90 damage.'};
    configure({arena:config.arena,spells:[['bolt','Emberbolt','MOUSE1','bolt','#ffb36c',0,650],['lance','Astral Lance','V','lance','#82ddff',25,4500],['nova','Cinder Nova','E','nova','#ff786e',30,8500],['ward','Prismatic Ward','R','ward','#9cf0d0',20,7000],['cataclysm','Starfall','F','star','#d7adff',70,22000]].map(([id,name,key,icon,color,cost,cooldownMs])=>({id,name,key,icon,color,cost,cooldownMs,description:descriptions[id]}))});
    const sample={revision:1,phase:'active',remainingMs:67000,round:2,firstTo:3,winner:0,arena:'duel',
      lobby:{queue:['Orion'],queued:false,minPlayers:2,canStart:false,duel:{phase:'active',round:2,players:2}},
      self:{id:1,hp:156,maxHp:200,mana:68,maxMana:100,shield:24,alive:true,ready:true,cooldowns:{lance:2400,cataclysm:14000}},
      roster:[{id:1,name:'Seraphine',wins:1,kills:1,deaths:0,damage:244,alive:true,ready:true,hp:156,maxHp:200,position:{x:2570,y:105}},{id:2,name:'Vesper',wins:0,kills:0,deaths:1,damage:112,alive:true,ready:true,hp:112,maxHp:200,position:{x:2574,y:119}}]};
    adopt(sample);setInterval(()=>{sample.revision++;adopt(sample);},500);
    document.addEventListener('keydown',event=>{
      const id=event.key.toLowerCase()==='h'?'spellbook':event.key.toLowerCase()==='k'?'standings':event.key.toLowerCase()==='n'?'menu':null;
      if(id&&!event.repeat)setPanel({id:visiblePanel===id?null:id});
    });
  }
  requestAnimationFrame(frame);
})();
