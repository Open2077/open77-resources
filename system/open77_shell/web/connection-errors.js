// Safe player-facing explanations. SQL and connection strings stay on the operator's server.
(function(root) {
  "use strict";
  const REASONS = {
    master_unavailable: "Server list unavailable",
    invalid_master_response: "Server list could not be read",
    catalog_request_rejected: "Server list request refused",
    server_not_in_catalog: "Server is no longer listed",
    unsecured_consent: "This server is unsecured. Confirm the warning to join",
    mods_relaunch_required: "This world requires mods. The game must restart through the launcher",
    launcher_not_registered: "The OPEN//77 launcher is not installed on this machine",
    launcher_launch_failed: "The launcher could not be started",
    game_window_close_failed: "The launcher opened, but the game could not close. Close the game window to continue in the launcher.",
    script_bridge_not_attached: "The game is not ready to handle this action. Try again shortly or close its window.",
    relaunch_failed: "The game could not hand over to the launcher",
    connection_already_in_progress: "Already connecting",
    resource_download_failed: "The server's content pack could not be downloaded. Check your connection and try again.",
    connection_refused: "The server refused the connection. It may be offline or restarting.",
    connection_timeout: "The server did not respond in time.",
    invalid_display_name: "Username must contain 1 to 32 UTF-8 bytes",
    identity_update_requires_offline_session: "Disconnect before changing your username",
    identity_master_rejected: "The Master rejected this username",
    identity_update_timeout: "Username update timed out",
    master_change_requires_offline_session: "Disconnect before changing Master",
    unknown_master: "Unknown Master server",
    // ── connection handshake failures ──────────────────────────────────────
    // These are the tokens the network layer sets when a join attempt cannot
    // complete: they must read as an explanation the player can act on.
    unsupported_version: "This server is running a different version of Open//77. Update your mod to the latest build, then try again.",
    unknown_message: "This server is running a different version of Open//77.",
    invalid_magic: "That address is not an Open//77 server.",
    invalid_server_packet: "The server sent data this client could not read — it is most likely running a different Open//77 version.",
    malformed_server_reject: "The server refused the connection but its reply could not be read.",
    connect_timeout: "The server did not respond. It may be offline, full, or unreachable.",
    handshake_timeout: "The connection opened but the server never finished the handshake.",
    server_rejected: "The server rejected your connection.",
    server_welcome_identity_mismatch: "The server could not verify your identity. Try reconnecting.",
    server_lease_invalid: "The server's run lease was rejected by the Master.",
    server_lease_missing: "The server did not present a valid run lease.",
    dns_resolution_failed: "The server address could not be resolved.",
    dns_no_supported_address: "The server address could not be resolved.",
    invalid_server_endpoint: "The server address is not valid.",
    identity_not_registered: "You are not signed in to this Master. Sign in again, then reconnect.",
    session_already_busy: "A connection is already in progress.",
    pristine_load_failed: "Your character could not be loaded. Try reconnecting.",
    character_bootstrap_failed: "Your character could not be prepared for this server.",
    session_ended: "The session ended before you reached the world.",
    server_disconnected: "You were disconnected from the server.",
    // Emitted by the pause menu's Quit Session: a deliberate exit, so the
    // browser greets rather than alarms.
    database_error: "The server could not load your character because its database is unavailable or a database operation failed.",
    database_unavailable: "The server cannot access its character database.",
    database_unreachable: "The server's database is not responding.",
    pristine_load_timeout: "The game did not finish preparing your character in time.",
    launcher_required: "Choose a server in the Open77 launcher first.",
    native_transition_in_progress: "The game is preparing your character. Wait for this transition to finish, or quit the game.",
    connection_lost: "The connection to the server was lost.",
    character_creation_cancelled: "Character creation was cancelled.",
    identity_update_failed: "Your identity could not be verified. Sign in again in the launcher.",
    user_quit: "You left the session."
  };

  function clean(value) {
    return String(value == null ? "" : value).replace(/[\u0000-\u001f\u007f]/g, " ")
      .replace(/\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+\/-]+=*/gi, "[authorization omitted]")
      .replace(/(?:mysql|mariadb):\/\/\S+/gi, "[database address omitted]")
      .replace(/(password|passwd|pwd|token|secret|authorization|api[_-]?key|connectionstring)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^;\s]+)/gi, "$1=[redacted]")
      .replace(/https?:\/\/\S+/gi, text => {try{const u=new URL(text);u.username="";u.password="";u.search="";u.hash="";return u.href;}catch(_){return "[url omitted]";}})
      .slice(0, 800);
  }
  function explain(reason, diagnostic) {
    const raw=clean(reason||"server_disconnected"), token=raw.split(":")[0];
    if (/^database_/.test(token)) return {
      code: token, title: "Server database error",
      message: REASONS[token] || REASONS.database_error,
      action: "This is a server-side problem. Contact the server owner, then retry after they restore the database.",
      owner: "Check Database & persistence in Warden, start MySQL/MariaDB and restart resources whose initialization failed.", fields: []
    };
    const download=root.Open77ResourceErrors?.explain(raw,diagnostic);
    if(download) return {code:token,title:"Resources could not load",message:download.summary,
      action:download.player,owner:download.owner,fields:download.fields.map(([k,v])=>[clean(k),clean(v)])};
    const detail=raw.includes(":")?raw.slice(raw.indexOf(":")+1).trim():"";
    const message=REASONS[raw] || REASONS[detail] || REASONS[token] ||
      (/^server_reject|^kicked|^banned/.test(token)&&detail ? detail : "The session could not continue. Share the details below with the server owner.");
    return {code:raw,title:/version|unknown_message/.test(raw)?"Version mismatch":"Connection interrupted",message,
      action:/version|unknown_message/.test(raw)?"Review client updates in the launcher and check the server version with its owner.":"You can retry this server or choose another one in the launcher.",
      fields:[],owner:""};
  }
  root.Open77ConnectionErrors={explain,clean};
  if(typeof module!=="undefined")module.exports=root.Open77ConnectionErrors;
})(typeof globalThis!=="undefined"?globalThis:window);
