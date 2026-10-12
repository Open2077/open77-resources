(() => {
  const get=id=>document.getElementById(id);
  Open77.on('freecam:state',s=>{
    get('hud').hidden=!s||s.phase==='off';
    if(!s||s.phase==='off')return;
    get('status').textContent=s.phase==='active'?'Body stays in place':'Preparing full body…';
    get('speed').textContent=Number(s.speed).toFixed(1)+' m/s';
    get('lens').textContent='FOV '+Math.round(s.fov)+'°';
    get('range').textContent=Math.round(s.distance)+' / '+s.limit+' m';
    const labels={FORWARD:'W/Z',BACK:'S',STRAFE_LEFT:'A/Q',STRAFE_RIGHT:'D'};
    const k=Object.fromEntries(Object.entries(s.keys).map(([name,key])=>[name,labels[key.toUpperCase()]||key]));
    get('keys').textContent=`${k.forward}/${k.left}/${k.back}/${k.right} Move · ${k.up}/${k.down} Height · Mouse Look · Wheel Speed · ${k.slow}+Wheel FOV · ${k.boost} Boost · ${k.exit} Exit`;
  });
  Open77.ready();Open77.emit('freecam:ready',{});
})();
