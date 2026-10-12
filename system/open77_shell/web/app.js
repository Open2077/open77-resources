// Launcher-owned destination, game-owned connection. No server directory or polling.
(function () {
  "use strict";
  const $=id=>document.getElementById(id), safe=Open77ConnectionErrors.clean;
  window.addEventListener("mousemove",event=>{
    $("virtualCursor").style.transform="translate3d("+Math.max(0,Math.min(innerWidth-1,event.clientX))+"px,"+Math.max(0,Math.min(innerHeight-1,event.clientY))+"px,0)";
    $("virtualCursor").classList.add("visible");
  },{passive:true});
  let target=null, client={}, server={}, attempt=0, started=0, failure=null, resourceDiagnostic=null;
  let checkpoint=-1, connecting=false, terminal=false, stage="standby", report="", busy=false;
  const privacy = window.Open77AddressPrivacy;
  Open77.on("privacy:state", value => privacy.setVisible(value?.visible === true));
  window.addEventListener("address-privacy:request", event => Open77.emit("privacy:set", event.detail));
  window.addEventListener("address-privacy:changed", () => renderReport());
  const phases={
    enrolling:[0,"Verifying identity"],resolving:[1,"Resolving server"],connecting:[1,"Connecting"],
    handshaking:[1,"Verifying connection"],active:[2,"Preparing server resources"],
    manifest:[2,"Reading resource manifest"],downloading:[2,"Downloading resources"],
    retrying:[2,"Retrying resource download"],verifying:[2,"Verifying resources"],
    ready:[3,"Preparing character"],creating_character:[3,"Create your character"],
    world:[4,"Loading Night City"]
  };
  function view(next, source) {
    const before=document.body.dataset.view;
    if(before===next)return;
    document.body.dataset.view=next;
    Open77.emit("shell:trace",{view:next,from:before,source});
  }
  function paintTarget() {
    privacy.remember(target);
    $("serverName").textContent=safe(target?.name||target?.endpoint||"No server selected");
    $("endpoint").textContent=safe(target?.endpoint||"Choose your destination in the launcher.");
    $("master").textContent=target?.master ? safe(target.master).toUpperCase()+" / MASTER" : "LAUNCHER MANAGED";
    $("retry").disabled=!target?.endpoint||connecting||busy;
    $("retryHint").textContent=!target?.endpoint?"No connection to retry yet.":connecting?"Connection in progress.":"Retries only this destination. Use the launcher to change servers.";
  }
  function paintSteps(failed=false) {
    for(const li of $("steps").children) {
      const index=Number(li.dataset.step);
      li.className=index<checkpoint?"done":index===checkpoint?(failed?"failed":"current"):"";
      if(index===checkpoint)li.setAttribute("aria-current","step");else li.removeAttribute("aria-current");
    }
    $("checkpoint").textContent=checkpoint<0?"":String(checkpoint+1).padStart(2,"0")+" / 05";
  }
  function progress(done,total) {
    const known=Number.isFinite(Number(total))&&Number(total)>0;
    const percent=known?Math.min(100,Math.max(0,Math.round((Number(done)||0)/Number(total)*100))):null;
    $("track").classList.toggle("busy",!known);
    $("percent").textContent=known?percent+"%":"";
    $("fill").style.width=known?percent+"%":"";
    if(known)$("track").setAttribute("aria-valuenow",String(percent));else $("track").removeAttribute("aria-valuenow");
  }
  function phase(name,detail) {
    if(terminal)return;
    connecting=true;stage=name;
    const entry=phases[name]||[Math.max(checkpoint,1),"Preparing session"];
    checkpoint=Math.max(checkpoint,entry[0]);paintSteps();
    $("phase").textContent=entry[1];
    $("headline").textContent=name==="creating_character"?"Make it your character.":"Connecting to your world.";
    $("stateLabel").textContent="SESSION IN PROGRESS";
    $("signal").textContent="CONNECTING";
    $("message").textContent=name==="creating_character"?"Finish character creation to continue into Night City.":"Your connection, resources and character are being prepared.";
    $("nextStep").textContent="You will enter the world when the server and game are ready.";
    $("progress").hidden=false;$("cancel").hidden=false;
    // Cancelling a live engine load cannot cancel LoadSavedGame. Offer quit instead.
    $("cancel").disabled=name==="world"||name==="creating_character";
    $("connectionStatus").textContent=name==="enrolling"?"VERIFYING":"CONNECTING";
    $("progressDetail").textContent=safe(detail||"");
    view("loading","phase:"+name);paintTarget();
  }
  function begin(value) {
    failure=null;terminal=false;busy=false;resourceDiagnostic=null;server={};
    target=value.target||target;attempt=value.attempt||attempt+1;started=Date.now();checkpoint=-1;
    $("diagnostics").hidden=true;$("details").hidden=true;$("report").hidden=true;
    $("toggleDetails").textContent="Show details";$("toggleDetails").setAttribute("aria-expanded","false");
    $("actionError").hidden=true;$("copy").textContent="Copy report";
    phase(value.phase||"enrolling");progress(0,0);
  }
  function renderReport() {
    if(!failure)return;
    const f=failure.explanation;
    const proto=p=>p.protocolMajor==null||p.protocolMinor==null?"not provided":p.protocolMajor+"."+p.protocolMinor;
    const rows=[
      ["Reason",f.code],["Time (UTC)",failure.time],["Server",safe(target?.name||"not provided")],
      ["Endpoint",safe(target?.endpoint||server.endpoint||"not provided")],["Connection attempt",String(attempt)],
      ["Last checkpoint",phases[stage]?.[1]||stage],
      ["Client runtime",safe(client.version||"not provided")],["Client protocol",proto(client)],
      ["Server protocol",proto(server)],["Game build",safe(client.gameBuild||"not provided")],
      ...f.fields
    ];
    if(f.owner)rows.push(["For the server owner",f.owner]);
    $("diagnosticRows").replaceChildren();
    for(const [label,value] of rows){const dt=document.createElement("dt"),dd=document.createElement("dd");dt.textContent=label;dd.textContent=value;$("diagnosticRows").append(dt,dd);}
    report=privacy.text([f.message,f.action,...rows.map(([k,v])=>k+": "+v)].join("\n"));
    $("report").value=report;
  }
  function fail(reason) {
    const f=Open77ConnectionErrors.explain(reason,resourceDiagnostic);
    // Native shell reveal/end events may repeat during teardown: retain the
    // original failure, timestamp, expanded details and keyboard focus.
    if(failure){view("failed","failure_retained");return;}
    failure={explanation:f,time:new Date().toISOString()};terminal=true;connecting=false;busy=false;
    $("headline").textContent=f.title+".";$("message").textContent=f.message;$("nextStep").textContent=f.action;
    $("stateLabel").textContent="SESSION INTERRUPTED";$("signal").textContent="ACTION REQUIRED";
    $("progress").hidden=true;$("cancel").hidden=true;$("connectionStatus").textContent="DISCONNECTED";
    $("failureCode").textContent=f.code;$("diagnostics").hidden=false;
    $("elapsed").textContent="CONNECTION STOPPED";paintSteps(true);paintTarget();renderReport();
    view("failed","connection_failure");
  }
  function idle(reason) {
    terminal=true;connecting=false;busy=false;
    $("headline").textContent=reason==="user_quit"?"You left the session.":"Connection cancelled.";
    $("stateLabel").textContent="SESSION ENDED";$("signal").textContent="STANDBY";
    $("message").textContent="Return to the launcher to choose a server, or retry your last destination.";
    $("nextStep").textContent="Your server selection and downloads are managed in the launcher.";
    $("progress").hidden=true;$("cancel").hidden=true;$("connectionStatus").textContent="OFFLINE";
    $("elapsed").textContent="NO ACTIVE SESSION";view("idle","intentional_disconnect");paintTarget();
  }
  async function action(name,button) {
    if(busy)return;
    busy=true;button.disabled=true;paintTarget();$("actionError").hidden=true;
    try {
      const result=await Open77.invoke(name,{});
      if(!result?.accepted)throw new Error(result?.reason||"action_failed");
    } catch(error) {
      $("actionError").textContent=Open77ConnectionErrors.explain(error.message).message;
      $("actionError").hidden=false;
    } finally {busy=false;button.disabled=false;paintTarget();}
  }
  $("retry").onclick=()=>action("connection:retry",$("retry"));
  $("cancel").onclick=()=>action("connection:cancel",$("cancel"));
  $("launcher").onclick=()=>action("shell:launcher",$("launcher"));
  $("quit").onclick=()=>action("shell:quit",$("quit"));
  $("toggleDetails").onclick=()=>{
    const open=$("details").hidden;$("details").hidden=!open;
    $("toggleDetails").textContent=open?"Hide details":"Show details";
    $("toggleDetails").setAttribute("aria-expanded",String(open));
  };
  $("copy").onclick=async()=>{
    try{await navigator.clipboard.writeText(report);$("copy").textContent="Copied";}
    catch(_){$("details").hidden=false;$("report").hidden=false;$("report").focus();$("report").select();
      $("toggleDetails").textContent="Hide details";$("toggleDetails").setAttribute("aria-expanded","true");$("copy").textContent="Press Ctrl+C";}
  };
  Open77.on("shell:state",value=>{
    client=value?.client||client;target=value?.target||target;
    $("build").textContent=client.protocolMajor!=null?"PROTOCOL "+client.protocolMajor+"."+client.protocolMinor:"";
    paintTarget();renderReport();
  });
  Open77.on("connection:begin",begin);
  Open77.on("shell:actionError",value=>{
    $("actionError").textContent=Open77ConnectionErrors.explain(value?.reason||"action_failed").message;
    $("actionError").hidden=false;
  });
  Open77.on("connection:update",value=>{
    if(!value)return;
    if(value.serverProfile)server=value.serverProfile;
    if(value.endpoint){target=target||{};target.endpoint=value.endpoint;target.name=value.server||value.endpoint;}
    if(["failed","rejected","offline","disconnecting","unknown"].includes(value.phase)){fail(value.reason||"server_disconnected");return;}
    phase(value.phase,value.detail||"");progress(0,0);
  });
  Open77.on("resources:loading",value=>{
    if(!value||terminal)return;
    if(value.diagnostic)resourceDiagnostic=value.diagnostic;
    if(value.phase==="failed"){fail(value.message||"resource_download_failed");return;}
    const bytes=n=>((Number(n)||0)/1048576).toFixed(1)+" MB";
    const parts=[value.resource,value.totalFiles?value.completedFiles+"/"+value.totalFiles+" files":"",
      value.total?bytes(value.received)+" / "+bytes(value.total):""].filter(Boolean);
    phase(value.phase,parts.join(" · "));progress(value.received,value.total);
  });
  Open77.on("world:loading:begin",()=>{phase("world","Streaming the world");progress(0,0);});
  Open77.on("world:loading",value=>{if(!terminal){phase("world","Streaming the world");progress(value?.progress,1);}});
  Open77.on("session:ended",value=>{
    const reason=value?.reason||"server_disconnected";
    if(failure){view("failed","session_ended_preserves_error");return;}
    if(["user_quit","connection_cancelled","client_disconnect"].includes(reason))idle(reason);else fail(reason);
  });
  Open77.on("shell:cover",()=>{if(!terminal)view("loading","shell_cover");});
  Open77.on("shell:reveal",()=>{
    if(failure){view("failed","shell_reveal_preserves_error");return;}
    if(!connecting)view("idle","shell_reveal");
  });
  Open77.on("shell:notice",value=>{$("noticeMessage").textContent=safe(value?.message||"Your session ended while creating a character.");view("notice","creator_orphaned");});
  Open77.on("loading:theme",value=>{
    // No server-controlled markup or external assets.
    if(value?.strap&&!terminal)$("footerStatus").textContent=safe(value.strap);
    if(typeof value?.accent==="string"&&/^#[0-9a-f]{6}$/i.test(value.accent))document.body.style.setProperty("--o-cyan-500",value.accent);
  });
  setInterval(()=>{if(connecting&&started)$("elapsed").textContent="ELAPSED "+Math.floor((Date.now()-started)/1000)+"s";},1000);
  paintTarget();Open77.emit("shell:ready",{});Open77.ready();
})();
