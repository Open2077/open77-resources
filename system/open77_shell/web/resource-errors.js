// Shared presentation contract for signed resource downloads. No network access.
(function (root) {
  "use strict";
  const clean = (value, limit = 512) => String(value == null ? "" : value)
    .replace(/[\x00-\x1f\x7f]/g, " ").slice(0, limit);
  function explain(reason, diagnostic) {
    let token = clean(reason);
    // A previous download must never mask an unrelated auth/kick/connection error.
    if (!/^(resource_|resources_|package_|cbor_|invalid_resource|unsafe_resource|unsafe_path|too_many_resource|duplicate_resource|unsupported_cbor|indefinite_cbor|invalid_cbor)/.test(token))
      return null;
    token = token.replace(/^resource_(?:download|install)_failed:/, "");
    const d = diagnostic && typeof diagnostic === "object" ? diagnostic : {};
    const code = clean(d.code || token.split(/[ :]/)[0], 96);
    const status = Number(d.httpStatus) || Number((token.match(/^resource_http_status:(\d+)/) || [])[1]) || 0;
    const os = Number(d.osError) || 0;
    let summary = "The server resources could not be installed.";
    let player = "Retry the connection. If it still fails, share the diagnostic details with the server owner.";
    let owner = "Check the public resource URL, TCP firewall/NAT rule and the server resource logs.";
    if (code === "resources_require_https_or_loopback") {
      summary = "This client build blocks the server's HTTP resource downloads.";
      player = "Update the Open77 client. This is not a problem with your internet connection.";
      owner = "Use an updated client supporting signed HTTP resources, or optionally configure a valid HTTPS resource URL.";
    } else if (os === 12007) {
      summary = "The resource server's hostname could not be resolved.";
      owner = "Check DNS and resources.download.publicBaseUrl. The game address and resource address can be different.";
    } else if (os === 12002) {
      summary = "The resource server did not respond in time.";
      owner = "Check the TCP resource port, reverse proxy timeout and upload bandwidth. Opening the UDP game port alone is not enough.";
    } else if (os === 12029 || /resource_http_connect_failed/.test(code)) {
      summary = "The game server is reachable, but its resource download service could not be reached.";
      owner = "Start the resource HTTP listener and forward/open its TCP port (normally 11779). Verify the public URL from another network.";
    } else if (os === 12175) {
      summary = "The resource server's HTTPS certificate could not be verified.";
      owner = "Fix the certificate hostname, expiry and chain, or explicitly advertise a public HTTP URL for signed resources. Do not disable TLS verification.";
    } else if (code === "resource_http_status") {
      summary = "The resource server returned HTTP " + status + ".";
      if (status === 404) owner = "The requested set/package/chunk is missing. Check the public URL path and reverse proxy routing; refresh/re-publish the current resource set.";
      else if (status === 401 || status === 403) owner = "Resource files must be publicly downloadable without login. Check proxy authentication, WAF and file access rules.";
      else if (status >= 300 && status < 400) owner = "The download endpoint redirects. Advertise the final direct resource URL; redirects are not followed.";
      else if (status === 429 || status >= 500) owner = "Check resource service availability, rate limits and reverse proxy logs. Temporary failures are retried automatically.";
    } else if (/signature|identity_mismatch/.test(code)) {
      summary = "The server resources failed authenticity verification.";
      player = "Do not bypass verification. Retry once, then send these details to the server owner.";
      owner = "Check the advertised signing key and preserve Open77-Signature / Open77-Public-Key headers through the proxy. Re-publish a coherent resource set.";
    } else if (/digest_mismatch|generation_mismatch/.test(code)) {
      summary = "The resource content does not match the version advertised by the server.";
      owner = "Check for a changed resource generation, a stale reverse proxy cache or altered files. Refresh/re-publish the set; do not disable hash checks.";
    } else if (/cache|file_create|file_write|generation_commit|previous_generation/.test(code)) {
      summary = "Open77 could not write or activate the local resource cache.";
      player = "Check free disk space, game-folder write access and antivirus quarantine. Close duplicate game instances before retrying; do not delete your server keys.";
      owner = "This report points to the player's local cache, not automatically to your server configuration.";
    } else if (/too_large|too_many|unsafe|cbor|package_manifest|duplicate_resource|invalid_resource_file/.test(code)) {
      summary = "The server resource package is invalid or exceeds a supported limit.";
      owner = "Check the named resource/file, package size and server packaging logs. Update the server and rebuild the resource set.";
    } else if (/invalid_resource.*url|invalid_resource_advertisement/.test(code)) {
      summary = "The server advertised an invalid resource download address.";
      owner = "Set resources.download.publicBaseUrl to a public HTTP(S) base URL, without credentials, query or fragment.";
    }
    let url = "";
    try {
      const parsed = new URL(String(d.url || ""));
      if (parsed.protocol === "http:" || parsed.protocol === "https:") {
        parsed.username = ""; parsed.password = ""; parsed.search = ""; parsed.hash = "";
        url = clean(parsed.href, 2048);
      }
    } catch (_) {}
    const fields = [
      ["Download ID", clean(d.id, 64)], ["Code", code], ["Stage", clean(d.stage, 48)],
      ["Resource", clean(d.resource, 128)], ["File", clean(d.file)],
      ["Download URL", url], ["HTTP status", status ? String(status) : ""],
      ["OS error", os ? String(os) : ""]
    ].filter(row => row[1]);
    const text = [summary, "Player: " + player, "Server owner: " + owner,
      ...fields.map(row => row[0] + ": " + row[1])].join("\n");
    return { summary, player, owner, fields, text };
  }
  root.Open77ResourceErrors = { explain };
  if (typeof module !== "undefined" && module.exports) module.exports = root.Open77ResourceErrors;
})(typeof globalThis !== "undefined" ? globalThis : window);
