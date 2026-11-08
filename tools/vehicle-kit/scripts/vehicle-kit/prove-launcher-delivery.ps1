#requires -Version 7.0
<#
.SYNOPSIS
    Repeatable proof that the vehicle customization packs reach a player through the
    Open77 launcher (plan P3.11): an install without the packs, a Connect, the download,
    the projection into the game folder and the load by ArchiveXL / TweakXL.

.DESCRIPTION
    Run the phases one at a time, in this order. Each one prints what it did, and stops
    with the exact remedy when something is wrong.

      prepare   Read-only against the lab and the game folder. Builds the launcher from the
                launcher repository's HEAD into the work folder, snapshots the lab's
                required-mod manifest, downloads and checks every blob (200, size,
                SHA-256), predicts the projection file by file, checks port 8090.
      strip     Backs up, then removes, the hand-installed files of the selected packs
                (one hard link each, checked with fsutil). Refuses while the game runs.
      launch    Moves the player's launcher session aside, seeds a stand-in session,
                starts a stand-in master on 127.0.0.1:8090 and an isolated launcher
                (own settings, mod store, instance) with a Direct Connect deep link to
                the lab. The operator accepts the consent dialog in the launcher window.
      verify    Steps 1, 2, 3 and 5 of "Verifying that a mod loaded" (wiki/mods.md):
                launcher log, files on disk, loader logs, server side.
      restore   Puts back exactly what strip removed, verified by hash, and undoes the
                launch footprint (session, webview folder, identity, log tail, open77://).

    Two more phases exist. selftest checks the stand-in master, the session seed and the
    file-in-use probe without leaving the work folder. serve-master is internal: launch
    starts it in its own window.

    Design notes and expected output: scripts/vehicle-kit/docs/launcher-proof.md

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\scripts\vehicle-kit\prove-launcher-delivery.ps1 -Phase prepare

.EXAMPLE
    # Prove the plates and the two loaders too.
    pwsh -File .\scripts\vehicle-kit\prove-launcher-delivery.ps1 -Phase strip `
        -Packages lightrp_vehicle_stages,lightrp_vk_body,lightrp_vk_liveries,lightrp_vk_rims,open77_vehicle_tint,open77_vehicle_plates
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('prepare', 'strip', 'launch', 'verify', 'restore', 'selftest', 'serve-master')]
    [string] $Phase,

    # Everything the proof writes lives here, except the game files it strips/restores and
    # the launch footprint it restores (see the doc).
    [string] $WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'op77-vc-launcher-proof'),

    [string] $GameDirectory,
    # The Open77 launcher repository. Default: OP77_LAUNCHER_DIR (process, then user), else
    # a `launcher` folder next to this repository's folder.
    [string] $LauncherRepo,
    [string] $LabEndpoint = '127.0.0.1:11855',
    # The lab server's folder (server.jsonc, logs). Default: OP77_VC_LAB_DIR. Optional:
    # without it prepare skips the auth settings check and verify the lab log line.
    [string] $LabRoot,

    # Resource names (or manifest ids "<name>-assets") whose files strip removes.
    [string[]] $Packages = @(
        'lightrp_vehicle_stages', 'lightrp_vk_body', 'lightrp_vk_liveries',
        'lightrp_vk_rims', 'open77_vehicle_tint'),

    # The lab's feature client. Its hash is recorded by strip and checked by verify/restore;
    # give a prefix here to have prepare check it too (another session may deploy over it).
    [string] $ExpectedClientSha256Prefix,

    [string] $Instance = 'vcproof',
    [string] $PlayerName = 'VcLauncherProof',

    # prepare: reuse the work folder's launcher build of HEAD, or skip the build.
    [switch] $Rebuild,
    [switch] $SkipBuild,

    # strip: accept selected files that are already absent. restore: close the isolated
    # launcher even when it has no window to close.
    [switch] $Force,

    # serve-master only.
    [string] $RunDirectory
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Fixed on purpose: the client's open77_shell resource enrolls the "development" master at
# http://127.0.0.1:8090 (MASTERS.development.catalog), whatever the launcher was told.
$MasterPort = 8090
$MasterBase = "http://127.0.0.1:$MasterPort/"
$StandinHeader = 'X-Open77-Standin'
$SessionEntropy = [Text.Encoding]::UTF8.GetBytes('OP77LauncherSessionV1')
$KnownGameBuilds = @{
    'd36e74c47592e9c656ae250078cb40b2be63c782af5bfbeff2280d43e653fab4' = '2.5'
    'a7de82945c03e041fc7339fcf9066224d98db2f5d80fea50f7947bb350a60991' = '2.31'
}
# ModRootPolicy.Roots in the launcher: where a world package may write.
$ModRoots = @(
    'bin/x64/plugins/cyber_engine_tweaks/mods', 'r6/storages/RedscriptConfigFramework',
    'red4ext/plugins', 'bin/x64/plugins', 'archive/pc/mod', 'r6/audioware', 'r6/scripts',
    'r6/tweaks', 'r6/input', 'r6/config', 'engine/config', 'engine/tools', 'mods', 'bin/x64')
# ScriptCacheRepair artefacts the launcher resets when a world projection changes files.
$ScriptCacheFiles = @(
    'r6/cache/final.redscripts.modded', 'r6/cache/final.redscripts.modded.bk',
    'r6/cache/final.redscripts.ts', 'r6/cache/redscript.ts',
    'r6/cache/modded/final.redscripts', 'r6/cache/modded/final.redscripts.bk',
    'r6/cache/modded/final.redscripts.ts', 'r6/cache/modded/redscript.ts')
# Files whose bytes must not change during the proof (the lab's client and loader chain).
$GuardedFiles = @(
    'red4ext/plugins/Open77/Open77.dll', 'red4ext/RED4ext.dll', 'red4ext/config.ini',
    'bin/x64/winmm.dll', 'bin/x64/version.dll')

# A variable set at user scope is invisible to a shell opened before it (agent sessions).
function Get-ConfiguredPath([string] $Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($Name, 'User') }
    $value
}
if (-not $LauncherRepo) { $LauncherRepo = Get-ConfiguredPath 'OP77_LAUNCHER_DIR' }
if (-not $LauncherRepo) { $LauncherRepo = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'launcher' }
if (-not $LabRoot) { $LabRoot = Get-ConfiguredPath 'OP77_VC_LAB_DIR' }

$script:Failures = 0
$script:Warnings = 0
# Phases print the next command; carry -WorkDir along when the caller gave one.
$WorkDirArg = if ($PSBoundParameters.ContainsKey('WorkDir')) { " -WorkDir `"$WorkDir`"" } else { '' }

# ── Output ─────────────────────────────────────────────────────────────────────────────

function Write-Step([string] $Title) { Write-Host ''; Write-Host "== $Title" -ForegroundColor Cyan }
function Write-Ok([string] $Message) { Write-Host "[  OK  ] $Message" -ForegroundColor Green }
function Write-Info([string] $Message) { Write-Host "[ INFO ] $Message" }
function Write-Warn([string] $Message, [string] $Remedy) {
    $script:Warnings++
    Write-Host "[ WARN ] $Message" -ForegroundColor Yellow
    if ($Remedy) { Write-Host "         remedy: $Remedy" -ForegroundColor Yellow }
}
function Write-Fail([string] $Message, [string] $Remedy) {
    $script:Failures++
    Write-Host "[ FAIL ] $Message" -ForegroundColor Red
    if ($Remedy) { Write-Host "         remedy: $Remedy" -ForegroundColor Red }
}
function Stop-Phase([string] $Message, [string] $Remedy) {
    Write-Fail $Message $Remedy
    Write-Host ''
    Write-Host "phase $($Phase): REFUSED. Nothing after this point was done." -ForegroundColor Red
    exit 2
}
function Complete-Phase([string] $Next) {
    Write-Host ''
    if ($script:Failures -gt 0) {
        Write-Host "phase $($Phase): FAILED ($($script:Failures) failure(s), $($script:Warnings) warning(s))." -ForegroundColor Red
        exit 1
    }
    Write-Host "phase $($Phase): OK ($($script:Warnings) warning(s))." -ForegroundColor Green
    if ($Next) { Write-Host "next: $Next" }
    exit 0
}

# ── Small helpers ──────────────────────────────────────────────────────────────────────

function Get-Paths {
    $w = [IO.Path]::GetFullPath($WorkDir)
    [pscustomobject]@{
        Work        = $w
        LauncherSrc = Join-Path $w 'launcher-src'
        LauncherBin = Join-Path $w 'launcher-bin'
        Origin      = Join-Path $w 'origin'
        OriginBlobs = Join-Path $w 'origin\blobs'
        Prepare     = Join-Path $w 'prepare.json'
        Strip       = Join-Path $w 'strip'
        StripState  = Join-Path $w 'strip\strip.json'
        Runs        = Join-Path $w 'runs'
        LaunchState = Join-Path $w 'launch.json'
    }
}

function Get-Sha256([string] $Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Get-BytesSha256([byte[]] $Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-Short([string] $Sha) { if ($Sha) { $Sha.Substring(0, [Math]::Min(12, $Sha.Length)) } else { '-' } }

function Save-Json([string] $Path, $Value) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $temporary = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Read-Json([string] $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }

function ConvertTo-ModPath([string] $Path) { $Path.Replace('\', '/').Trim('/') }
function ConvertTo-GamePath([string] $Game, [string] $Relative) { Join-Path $Game ($Relative -replace '/', '\') }

function Get-ModRoot([string] $Path) {
    foreach ($root in $ModRoots) {
        if ($Path.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $root }
        if ($Path.Length -gt $root.Length -and $Path[$root.Length] -eq '/' -and
            $Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $root }
    }
    return $null
}

# Mirror of ModRootPolicy.ArchivePrefix: strip a wrapper folder only when no entry already
# starts at a recognised root and every entry does once the wrapper is removed.
function Get-ArchivePrefix([string[]] $Paths) {
    if ($Paths.Count -eq 0) { return '' }
    foreach ($p in $Paths) { if (Get-ModRoot $p) { return '' } }
    $first = $Paths[0]
    for ($slash = $first.IndexOf('/'); $slash -ge 0; $slash = $first.IndexOf('/', $slash + 1)) {
        $prefix = $first.Substring(0, $slash + 1)
        if (@($Paths | Where-Object { -not $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { break }
        if (@($Paths | Where-Object { -not (Get-ModRoot $_.Substring($prefix.Length)) }).Count -eq 0) { return $prefix }
    }
    return ''
}

function Get-LinkCount([string] $Path) {
    $output = & fsutil.exe hardlink list $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fsutil hardlink list '$Path' failed: $output" }
    return @($output | Where-Object { "$_".Trim() }).Count
}

function Test-ReparsePoint([string] $Path) {
    ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Resolve-GameDirectory {
    $candidates = @($GameDirectory, $env:OP77_GAME_DIR,
        [Environment]::GetEnvironmentVariable('OP77_GAME_DIR', 'User'),
        'C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077') | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\x64\Cyberpunk2077.exe')) {
            return [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        }
    }
    Stop-Phase "Cyberpunk 2077 not found (tried: $($candidates -join '; '))" `
        'pass -GameDirectory "<install folder>" or set OP77_GAME_DIR at user scope'
}

function Get-LabInfo {
    if ($LabEndpoint -notmatch '^(?<h>127\.0\.0\.1|localhost):(?<p>\d{1,5})$') {
        Stop-Phase "lab endpoint '$LabEndpoint' is not a loopback host:port" `
            'this proof never leaves 127.0.0.1: pass -LabEndpoint 127.0.0.1:<port>'
    }
    $port = [int]$Matches.p
    [pscustomobject]@{
        Endpoint = $LabEndpoint
        Port     = $port
        # DirectServerMods.ManifestUri: the resource HTTP port is the game port + 1.
        ModsBase = "http://$($Matches.h):$($port + 1)/mods/v1/"
    }
}

function Get-OpenDirectory { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Open77' }

function Get-GameProcesses { @(Get-Process -Name Cyberpunk2077 -ErrorAction SilentlyContinue) }
# With -Game, only a Cyberpunk2077 started from that install counts (an unreadable path
# counts too). Without it, any running game refuses: the launcher's own GameFileSafety
# check is global, so launch must be.
function Assert-GameClosed([string] $Game) {
    $running = @(Get-GameProcesses)
    if ($Game) {
        $prefix = $Game.TrimEnd('\') + '\'
        $running = @($running | Where-Object { -not $_.Path -or $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    }
    if ($running.Count -gt 0) {
        Stop-Phase "Cyberpunk2077 is running (pid $($running.Id -join ', '))" `
            'quit the game (and wait until Get-Process Cyberpunk2077 returns nothing), then rerun this phase'
    }
}

$script:Http = $null
function Get-Http {
    if (-not $script:Http) {
        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.UseProxy = $false          # loopback only, never through a proxy
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
        $script:Http = [System.Net.Http.HttpClient]::new($handler)
        $script:Http.Timeout = [TimeSpan]::FromSeconds(120)
    }
    $script:Http
}

# GET a URL. With -OutFile the body streams to disk; otherwise it is returned in memory.
function Invoke-Get([string] $Uri, [string] $OutFile) {
    $response = (Get-Http).GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
        $status = [int]$response.StatusCode
        $declared = $response.Content.Headers.ContentLength
        $headers = @{}
        foreach ($h in $response.Headers) { $headers[$h.Key] = ($h.Value -join ',') }
        if ($OutFile) {
            if ($status -ne 200) { return [pscustomobject]@{ Status = $status; Declared = $declared; Bytes = $null; Headers = $headers } }
            $partial = "$OutFile.part"
            $file = [IO.File]::Create($partial)
            try { $response.Content.ReadAsStream().CopyTo($file) } finally { $file.Dispose() }
            Move-Item -LiteralPath $partial -Destination $OutFile -Force
            return [pscustomobject]@{ Status = $status; Declared = $declared; Bytes = $null; Headers = $headers }
        }
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{ Status = $status; Declared = $declared; Bytes = $bytes; Headers = $headers }
    }
    finally { $response.Dispose() }
}

function Test-TcpListening([int] $Port) {
    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return @($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
}
function Get-TcpOwner([int] $Port) {
    try {
        $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        return "pid $($connection.OwningProcess) $(if ($process) { $process.ProcessName })"
    }
    catch { return 'unknown owner' }
}
function Test-PortExcluded([int] $Port) {
    $text = & netsh.exe int ipv4 show excludedportrange protocol=tcp 2>$null
    foreach ($line in $text) {
        if ($line -match '^\s*(\d+)\s+(\d+)') {
            if ($Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return "$($Matches[1])-$($Matches[2])" }
        }
    }
    return $null
}

function Find-NewestLog([string] $Directory, [string] $Filter, [datetime] $After) {
    if (-not (Test-Path -LiteralPath $Directory)) { return $null }
    $floor = if ($After -gt [datetime]::MinValue.AddMinutes(1)) { $After.AddSeconds(-5) } else { $After }
    Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $floor -and $_.Name -notlike '*.err.log' } |
        Sort-Object LastWriteTime | Select-Object -Last 1
}

function Read-SharedBytes([string] $Path) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { $buffer = [IO.MemoryStream]::new(); $stream.CopyTo($buffer); $buffer.ToArray() }
    finally { $stream.Dispose() }
}
function Get-PrefixSha256([byte[]] $Bytes, [long] $Length) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToHexString($sha.ComputeHash($Bytes, 0, [int]$Length)).ToLowerInvariant() } finally { $sha.Dispose() }
}

function Read-Shared([string] $Path) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8); $reader.ReadToEnd() }
    finally { $stream.Dispose() }
}

# ── Native helpers: stand-in master and file-in-use probe ──────────────────────────────

$NativeSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace VcProof
{
    public sealed class Request
    {
        public string Method = "";
        public string Target = "";
        public string Path = "";
        public byte[] Body = new byte[0];
    }

    public sealed class Response
    {
        public int Status;
        public string ContentType = "application/json";
        public byte[] Body = new byte[0];
    }

    // The smallest master the launcher and the client accept for a loopback, devLocalAuth
    // lab. It never logs a header or a body: the launcher sends its session as a Bearer
    // token and the client sends it to /identities/enroll.
    public static class StandinMaster
    {
        const int MaxHeaderBytes = 32 * 1024;
        const int MaxBodyBytes = 1024 * 1024;
        static readonly byte[] EnrollMagic = Encoding.ASCII.GetBytes("CYIDENR1");
        static readonly byte[] ReplyMagic = Encoding.ASCII.GetBytes("CYIDACK1");
        static readonly object LogLock = new object();
        static readonly byte[] MasterKey = RandomNumberGenerator.GetBytes(32);
        public static string LogPath = "";
        public static string DefaultName = "VcLauncherProof";
        public static string AccountId = Guid.Empty.ToString();

        public static void Run(int port, string logPath, string stopFile)
        {
            LogPath = logPath;
            var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            Log("listening http://127.0.0.1:" + port + "/ (stand-in master, loopback only)");
            try
            {
                while (!File.Exists(stopFile))
                {
                    if (!listener.Pending()) { Thread.Sleep(50); continue; }
                    var client = listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(_ => Serve(client));
                }
            }
            finally
            {
                listener.Stop();
                Log("stopped (stop file seen)");
            }
        }

        static void Serve(TcpClient client)
        {
            using (client)
            {
                try
                {
                    client.ReceiveTimeout = 10000;
                    client.SendTimeout = 10000;
                    var stream = client.GetStream();
                    Handle(stream, stream);
                    client.Client.Shutdown(SocketShutdown.Send);
                }
                catch (Exception e) { Log("connection error: " + e.GetType().Name + ": " + e.Message); }
            }
        }

        public static void Handle(Stream input, Stream output)
        {
            Request request = null;
            Response response;
            try { request = ReadRequest(input, output); response = Route(request); }
            catch (IOException) { throw; }
            catch (Exception e) { response = Json(400, "{\"error\":\"bad_request\"}"); Log("bad request: " + e.GetType().Name + ": " + e.Message); }
            WriteResponse(output, response);
            Log((request == null ? "? ?" : request.Method + " " + request.Target) + " -> " + response.Status + " " + response.Body.Length + "B");
        }

        public static Response Route(Request r)
        {
            string p = r.Path.TrimEnd('/').ToLowerInvariant();
            string m = r.Method.ToUpperInvariant();
            if (m == "GET" && p == "/healthz") return Json(200, "{\"status\":\"ok\",\"standin\":\"vc-launcher-proof\"}");
            // Launcher directory and the client's catalog: empty. Loopback rows are refused anyway.
            if (m == "GET" && p == "/api/v1/servers") return Json(200, "{\"page\":1,\"pageSize\":100,\"total\":0,\"items\":[]}");
            // No verdict for any hash: the direct, unsecured world asks the player instead.
            if (m == "POST" && p == "/api/v1/mods/attest") return Json(200, "{\"results\":[]}");
            // Empty: the launcher falls back to its built-in game builds.
            if (m == "GET" && p == "/api/v1/builds/manifest") return Json(200, "[]");
            if (m == "GET" && p == "/api/v1/accounts/game-ownership")
                return Json(200, "{\"required\":false,\"allowed\":true,\"steamAvailable\":false,\"gogAvailable\":false,\"providers\":[],\"adminApproved\":true,\"epicAvailable\":false}");
            if (m == "GET" && p == "/api/v1/accounts/discord")
                return Json(200, "{\"configured\":false,\"connection\":{\"revision\":0,\"profile\":null,\"linkedAtUtc\":null}}");
            if (m == "POST" && p == "/api/v1/accounts/login")
                return Json(200, "{\"token\":\"" + Token() + "\",\"expiresAtUtc\":\"" + DateTimeOffset.UtcNow.AddHours(12).ToString("o")
                    + "\",\"accountId\":\"" + AccountId + "\",\"displayName\":\"" + DefaultName + "\",\"role\":\"player\",\"emailVerified\":true}");
            if (m == "POST" && p == "/api/v1/identities/enroll") return Enroll(r.Body);
            return Json(404, "{\"error\":\"not_found\"}");
        }

        // Request layout (ClientIdentity::Enroll): "CYIDENR1" userId[16] publicKey[64]
        // nonce[16] u64be time u16be nameLength name signature[64].
        // Reply: "CYIDACK1" userId[16] certificate[64] masterKey[32] u16be nameLength name.
        // The client stores the certificate without checking it, and a loopback catalog is
        // exempt from the master-key pin; the devLocalAuth lab accepts any identity.
        public static Response Enroll(byte[] b)
        {
            const int fixedBytes = 8 + 16 + 64 + 16 + 8 + 2 + 64;
            const int nameOffset = 8 + 16 + 64 + 16 + 8;
            if (b.Length < fixedBytes) return Json(400, "{\"error\":\"malformed_enrollment\"}");
            for (int i = 0; i < EnrollMagic.Length; i++)
                if (b[i] != EnrollMagic[i]) return Json(400, "{\"error\":\"malformed_enrollment\"}");
            int nameLength = (b[nameOffset] << 8) | b[nameOffset + 1];
            if (b.Length != fixedBytes + nameLength) return Json(400, "{\"error\":\"malformed_enrollment\"}");
            byte[] name = new byte[nameLength];
            Array.Copy(b, nameOffset + 2, name, 0, nameLength);
            if (name.Length == 0 || name.Length > 32) name = Encoding.UTF8.GetBytes(DefaultName);
            var reply = new MemoryStream();
            reply.Write(ReplyMagic, 0, ReplyMagic.Length);
            reply.Write(b, 8, 16);
            reply.Write(new byte[64], 0, 64);
            reply.Write(MasterKey, 0, MasterKey.Length);
            reply.WriteByte((byte)(name.Length >> 8));
            reply.WriteByte((byte)(name.Length & 0xFF));
            reply.Write(name, 0, name.Length);
            return new Response { Status = 200, ContentType = "application/octet-stream", Body = reply.ToArray() };
        }

        public static Request ReadRequest(Stream input, Stream output)
        {
            var head = new MemoryStream();
            int matched = 0;
            while (matched < 4)
            {
                int value = input.ReadByte();
                if (value < 0) throw new InvalidDataException("connection closed inside the headers");
                head.WriteByte((byte)value);
                if (head.Length > MaxHeaderBytes) throw new InvalidDataException("headers too large");
                matched = (value == (matched % 2 == 0 ? '\r' : '\n')) ? matched + 1 : (value == '\r' ? 1 : 0);
            }
            string[] lines = Encoding.ASCII.GetString(head.ToArray()).Split(new[] { "\r\n" }, StringSplitOptions.None);
            string[] start = lines[0].Split(' ');
            if (start.Length < 3) throw new InvalidDataException("bad request line");
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < lines.Length; i++)
            {
                int colon = lines[i].IndexOf(':');
                if (colon > 0) headers[lines[i].Substring(0, colon).Trim()] = lines[i].Substring(colon + 1).Trim();
            }
            var request = new Request { Method = start[0], Target = start[1] };
            int query = request.Target.IndexOf('?');
            request.Path = query >= 0 ? request.Target.Substring(0, query) : request.Target;

            string expect;
            if (headers.TryGetValue("Expect", out expect) && expect.Equals("100-continue", StringComparison.OrdinalIgnoreCase))
            {
                byte[] proceed = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");
                output.Write(proceed, 0, proceed.Length);
                output.Flush();
            }
            string encoding, length;
            if (headers.TryGetValue("Transfer-Encoding", out encoding) && encoding.IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0)
                request.Body = ReadChunked(input);
            else if (headers.TryGetValue("Content-Length", out length))
            {
                int size;
                if (!int.TryParse(length, out size) || size < 0 || size > MaxBodyBytes) throw new InvalidDataException("bad Content-Length");
                request.Body = ReadExactly(input, size);
            }
            return request;
        }

        static byte[] ReadChunked(Stream input)
        {
            var body = new MemoryStream();
            while (true)
            {
                string line = ReadLine(input);
                int semicolon = line.IndexOf(';');
                if (semicolon >= 0) line = line.Substring(0, semicolon);
                int size;
                if (!int.TryParse(line.Trim(), System.Globalization.NumberStyles.AllowHexSpecifier, null, out size) || size < 0)
                    throw new InvalidDataException("bad chunk size");
                if (size == 0)
                {
                    while (ReadLine(input).Length > 0) { }
                    return body.ToArray();
                }
                if (body.Length + size > MaxBodyBytes) throw new InvalidDataException("body too large");
                byte[] chunk = ReadExactly(input, size);
                body.Write(chunk, 0, chunk.Length);
                ReadLine(input);
            }
        }

        static string ReadLine(Stream input)
        {
            var line = new StringBuilder();
            while (true)
            {
                int value = input.ReadByte();
                if (value < 0) throw new InvalidDataException("connection closed inside a chunk");
                if (value == '\n') return line.ToString().TrimEnd('\r');
                if (line.Length > 1024) throw new InvalidDataException("line too long");
                line.Append((char)value);
            }
        }

        static byte[] ReadExactly(Stream input, int size)
        {
            byte[] buffer = new byte[size];
            int read = 0;
            while (read < size)
            {
                int n = input.Read(buffer, read, size - read);
                if (n <= 0) throw new InvalidDataException("connection closed inside the body");
                read += n;
            }
            return buffer;
        }

        static void WriteResponse(Stream s, Response r)
        {
            string head = "HTTP/1.1 " + r.Status + " " + (r.Status == 200 ? "OK" : r.Status == 404 ? "Not Found" : "Bad Request") + "\r\n"
                + "Date: " + DateTime.UtcNow.ToString("R") + "\r\n"
                + "Content-Type: " + r.ContentType + "\r\n"
                + "Content-Length: " + r.Body.Length + "\r\n"
                + "Cache-Control: no-store\r\n"
                + "X-Open77-Standin: vc-launcher-proof\r\n"
                + "Connection: close\r\n\r\n";
            byte[] bytes = Encoding.ASCII.GetBytes(head);
            s.Write(bytes, 0, bytes.Length);
            s.Write(r.Body, 0, r.Body.Length);
            s.Flush();
        }

        static Response Json(int status, string json) { return new Response { Status = status, Body = Encoding.UTF8.GetBytes(json) }; }

        static string Token()
        {
            return Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        public static void Log(string message)
        {
            string line = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + " " + message;
            lock (LogLock)
            {
                Console.WriteLine(line);
                if (LogPath.Length > 0) File.AppendAllText(LogPath, line + Environment.NewLine);
            }
        }
    }

    // Which processes hold a file open, from the Restart Manager. Read-only: it never asks
    // anyone to close anything (no RmShutdown).
    public static class FileHolders
    {
        [StructLayout(LayoutKind.Sequential)]
        struct RmUniqueProcess { public int ProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME StartTime; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct RmProcessInfo
        {
            public RmUniqueProcess Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string AppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string ServiceShortName;
            public int ApplicationType;
            public uint AppStatus;
            public uint SessionId;
            [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        static extern int RmStartSession(out uint session, int flags, StringBuilder key);
        [DllImport("rstrtmgr.dll")]
        static extern int RmEndSession(uint session);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        static extern int RmRegisterResources(uint session, uint fileCount, string[] files, uint appCount, RmUniqueProcess[] apps, uint serviceCount, string[] services);
        [DllImport("rstrtmgr.dll")]
        static extern int RmGetList(uint session, out uint needed, ref uint count, [In, Out] RmProcessInfo[] infos, ref uint rebootReasons);

        public static int[] Holders(string path)
        {
            uint session;
            int rc = RmStartSession(out session, 0, new StringBuilder(64));
            if (rc != 0) throw new InvalidOperationException("RmStartSession failed: " + rc);
            try
            {
                rc = RmRegisterResources(session, 1, new[] { path }, 0, null, 0, null);
                if (rc != 0) throw new InvalidOperationException("RmRegisterResources failed: " + rc);
                uint needed, count = 0, reasons = 0;
                rc = RmGetList(session, out needed, ref count, null, ref reasons);
                if (rc == 0) return new int[0];
                if (rc != 234) throw new InvalidOperationException("RmGetList failed: " + rc);
                var infos = new RmProcessInfo[needed];
                count = needed;
                rc = RmGetList(session, out needed, ref count, infos, ref reasons);
                if (rc != 0) throw new InvalidOperationException("RmGetList failed: " + rc);
                var pids = new int[count];
                for (int i = 0; i < count; i++) pids[i] = infos[i].Process.ProcessId;
                return pids;
            }
            finally { RmEndSession(session); }
        }
    }
}
'@

function Initialize-Native {
    if (-not ('VcProof.StandinMaster' -as [type])) { Add-Type -TypeDefinition $NativeSource -Language CSharp }
}

# ── Launcher session (DPAPI, CurrentUser) ──────────────────────────────────────────────

function Initialize-ProtectedData {
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
    }
}

# Same shape as LauncherSession (JsonSerializerDefaults.Web), so both the launcher and the
# client's ReadLauncherAccountToken accept it. The token is random and only ever reaches
# the stand-in master.
function Write-SeededSession([string] $Path, [string] $AccountId, [string] $DisplayName, [string] $GameSha) {
    Initialize-ProtectedData
    $token = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $json = [ordered]@{
        accountId       = $AccountId
        displayName     = $DisplayName
        sessionToken    = $token
        expiresAtUtc    = [DateTimeOffset]::UtcNow.AddHours(12).ToString('o')
        gameBuildSha256 = $GameSha
    } | ConvertTo-Json -Compress
    $plain = [Text.Encoding]::UTF8.GetBytes($json)
    $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $SessionEntropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [Array]::Clear($plain)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllBytes($Path, $protected)
}

# The account id inside a session file, or $null. Never returns or prints the token.
function Get-SessionAccountId([string] $Path) {
    Initialize-ProtectedData
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $SessionEntropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $session = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json -AsHashtable
        [Array]::Clear($plain)
        return [string]$session['accountId']
    }
    catch { return $null }
}

# ── open77:// scheme snapshot (HKCU) ───────────────────────────────────────────────────

$SchemeKey = 'Software\Classes\open77'
$SchemeSubKeys = @('shell', 'shell\open', 'shell\open\command')

function Get-SchemeSnapshot {
    $root = [Microsoft.Win32.Registry]::CurrentUser
    $snapshot = [ordered]@{ Exists = $false; Named = [ordered]@{}; SubKeys = [ordered]@{}; Command = $null; CommandExists = $false }
    $key = $root.OpenSubKey($SchemeKey)
    if (-not $key) { return $snapshot }
    try {
        $snapshot.Exists = $true
        foreach ($name in @('', 'URL Protocol')) {
            $value = $key.GetValue($name, $null)
            $snapshot.Named[$(if ($name) { $name } else { '(default)' })] = $value
        }
    }
    finally { $key.Dispose() }
    foreach ($sub in $SchemeSubKeys) {
        $k = $root.OpenSubKey("$SchemeKey\$sub")
        $snapshot.SubKeys[$sub] = [bool]$k
        if ($k) {
            if ($sub -eq 'shell\open\command') { $snapshot.Command = $k.GetValue('', $null); $snapshot.CommandExists = $null -ne $snapshot.Command }
            $k.Dispose()
        }
    }
    return $snapshot
}

function Restore-Scheme($Snapshot) {
    $root = [Microsoft.Win32.Registry]::CurrentUser
    if (-not $Snapshot.Exists) {
        if ($root.OpenSubKey($SchemeKey)) { $root.DeleteSubKeyTree($SchemeKey, $false); return 'removed (it did not exist before)' }
        return 'absent, as before'
    }
    $key = $root.CreateSubKey($SchemeKey)
    try {
        foreach ($name in @('(default)', 'URL Protocol')) {
            $registryName = if ($name -eq '(default)') { '' } else { $name }
            $value = $Snapshot['Named'][$name]
            if ($null -eq $value) { $key.DeleteValue($registryName, $false) } else { $key.SetValue($registryName, [string]$value) }
        }
    }
    finally { $key.Dispose() }
    foreach ($sub in @($SchemeSubKeys | Sort-Object Length -Descending)) {
        if (-not $Snapshot.SubKeys[$sub] -and $root.OpenSubKey("$SchemeKey\$sub")) { $root.DeleteSubKeyTree("$SchemeKey\$sub", $false) }
    }
    if ($Snapshot.SubKeys['shell\open\command']) {
        $command = $root.CreateSubKey("$SchemeKey\shell\open\command")
        try {
            if ($Snapshot.CommandExists) { $command.SetValue('', [string]$Snapshot.Command) } else { $command.DeleteValue('', $false) }
        }
        finally { $command.Dispose() }
    }
    return "restored to $(if ($Snapshot.CommandExists) { $Snapshot.Command } else { '(no command)' })"
}

# ── Manifest and blobs ─────────────────────────────────────────────────────────────────

# Mirror of DirectServerMods.Parse + Digest: what the launcher accepts from a direct server.
function Test-DirectManifest($Manifest, [byte[]] $Bytes) {
    $problems = [Collections.Generic.List[string]]::new()
    if ($Bytes.Length -gt 256KB) { $problems.Add('manifest larger than 256 KiB') }
    if ($Manifest['version'] -ne 1) { $problems.Add("version is '$($Manifest['version'])', expected 1") }
    if ($Manifest['enabled'] -isnot [bool]) { $problems.Add('enabled is not a boolean') }
    $mods = @($Manifest['mods'])
    if ($mods.Count -gt 64) { $problems.Add("$($mods.Count) mods, the launcher accepts 64") }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $mods) {
        $id = [string]$m['id']
        if ($id -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$' -or -not $ids.Add($id)) { $problems.Add("bad or duplicate id '$id'") }
        if ($m['source'] -eq 'hosted') {
            $sha = [string]$m['sha256']
            if ($sha -cnotmatch '^[0-9a-f]{64}$') { $problems.Add("$($id): sha256 is not 64 lower-case hex") }
            if (-not $m['version'] -or $m['version'] -notmatch '^[0-9]+(\.[0-9]+){0,3}(-[0-9A-Za-z.-]{1,32})?$') { $problems.Add("$($id): bad version") }
            if ($null -ne $m['minVersion']) { $problems.Add("$($id): hosted entries carry no minVersion") }
            if ($m['sizeBytes'] -le 0 -or $m['sizeBytes'] -gt 512MB) { $problems.Add("$($id): sizeBytes out of range") }
            if ($m['url'] -cne "blobs/$sha") { $problems.Add("$($id): url '$($m['url'])' is not 'blobs/<sha256>'") }
        }
        elseif ($m['source'] -ne 'indexed') { $problems.Add("$($id): unknown source '$($m['source'])'") }
    }
    if (-not $Manifest['enabled'] -and $mods.Count -gt 0) { $problems.Add('disabled manifest lists mods') }
    $digest = Get-ManifestDigest $mods
    if ($digest -cne [string]$Manifest['digest']) { $problems.Add("digest $($Manifest['digest']) does not match the packages ($digest)") }
    return [pscustomobject]@{ Problems = $problems; Digest = $digest }
}

function Get-ManifestDigest($Mods) {
    $byId = @{}
    foreach ($m in $Mods) { $byId[[string]$m['id']] = $m }
    $ids = [string[]]@($byId.Keys)
    [Array]::Sort($ids, [StringComparer]::Ordinal)
    $text = [Text.StringBuilder]::new()
    foreach ($id in $ids) {
        $m = $byId[$id]
        $version = if ($m['version']) { [string]$m['version'] } elseif ($m['minVersion']) { [string]$m['minVersion'] } else { '' }
        $sha = if ($m['sha256']) { [string]$m['sha256'] } else { '' }
        [void]$text.Append("$id$([char]0x1f)$($version.ToLowerInvariant())$([char]0x1f)$sha`n")
    }
    Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($text.ToString()))
}

function Get-LabManifest($Lab) {
    $uri = "$($Lab.ModsBase)manifest"
    try { $response = Invoke-Get $uri }
    catch {
        Stop-Phase "the lab does not answer $uri ($($_.Exception.Message))" `
            "start the lab server ($(if ($LabRoot) { "$LabRoot, " })UDP $($Lab.Port), resource HTTP $($Lab.Port + 1)) the usual way; this script never starts it"
    }
    if ($response.Status -ne 200) { Stop-Phase "$uri answered HTTP $($response.Status)" 'check requiredMods.enabled in the lab server.jsonc' }
    $manifest = [Text.Encoding]::UTF8.GetString($response.Bytes) | ConvertFrom-Json -AsHashtable
    [pscustomobject]@{ Uri = $uri; Bytes = $response.Bytes; Manifest = $manifest }
}

# Lists the files a package declares, game-relative, with their SHA-256, the way the
# launcher's WorldModFetcher.InspectAndRegister reads them.
function Get-PackageFiles([string] $Zip) {
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($archive.Entries | Where-Object { -not ($_.FullName.EndsWith('/') -or $_.FullName.EndsWith('\')) })
        $names = [string[]]@($entries | ForEach-Object { ConvertTo-ModPath $_.FullName })
        $prefix = Get-ArchivePrefix $names
        foreach ($entry in $entries) {
            $stream = $entry.Open()
            try { $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
            finally { $stream.Dispose() }
            $path = (ConvertTo-ModPath $entry.FullName).Substring($prefix.Length)
            [pscustomobject]@{ Path = $path; Sha256 = $sha; Size = $entry.Length; Root = (Get-ModRoot $path) }
        }
    }
    finally { $archive.Dispose() }
}

function Resolve-SelectedIds($ManifestMods) {
    $ids = @($ManifestMods | ForEach-Object { [string]$_['id'] })
    $selected = foreach ($name in $Packages) {
        $match = @($ids | Where-Object { $_ -eq $name -or $_ -eq "$name-assets" })
        if ($match.Count -ne 1) {
            Stop-Phase "package '$name' is not in the lab manifest (ids: $($ids -join ', '))" `
                'pass -Packages with resource names the lab announces, or load the resource on the lab'
        }
        $match[0]
    }
    @($selected | Select-Object -Unique)
}

function Get-PrepareState([object] $P) {
    if (-not (Test-Path -LiteralPath $P.Prepare)) {
        Stop-Phase "no prepare snapshot in $($P.Work)" "run -Phase prepare first (same -WorkDir)"
    }
    Read-Json $P.Prepare
}

# ═══ prepare ═══════════════════════════════════════════════════════════════════════════

function Invoke-Prepare {
    $P = Get-Paths
    $game = Resolve-GameDirectory
    $lab = Get-LabInfo
    New-Item -ItemType Directory -Force -Path $P.Work, $P.OriginBlobs | Out-Null
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    Write-Host 'prove-launcher-delivery: prepare (read-only against the lab and the game folder)'
    Write-Info "work folder   $($P.Work)"
    Write-Info "game folder   $game"
    Write-Info "lab           $($lab.Endpoint), required mods at $($lab.ModsBase)"

    # 1. Game install ------------------------------------------------------------------
    Write-Step '1. Game install'
    $exe = Join-Path $game 'bin\x64\Cyberpunk2077.exe'
    $exeSha = Get-Sha256 $exe
    $gameBuild = $KnownGameBuilds[$exeSha]
    if ($gameBuild) { Write-Ok "Cyberpunk2077.exe is game $gameBuild ($(Get-Short $exeSha))" }
    else { Write-Fail "Cyberpunk2077.exe $(Get-Short $exeSha) is neither 2.5 nor 2.31" 'the launcher refuses an unknown build without a master manifest; use the supported game build' }
    if (Test-Path -LiteralPath (Join-Path $game 'archive\pc\ep1')) { Write-Ok 'Phantom Liberty present (archive\pc\ep1)' }
    else { Write-Fail 'archive\pc\ep1 is missing' 'the launcher requires Phantom Liberty before any connect' }
    foreach ($required in @('red4ext/RED4ext.dll', 'red4ext/plugins/Open77/Open77.dll',
            'red4ext/plugins/Open77/web/Open77.WebHost.exe', 'red4ext/plugins/Open77/web/libcef.dll')) {
        $full = ConvertTo-GamePath $game $required
        if (-not (Test-Path -LiteralPath $full)) { Write-Fail "$required is missing" 'deploy the lab client first (CompatibilityCheck requires it)'; continue }
        if (Test-ReparsePoint $full) { Write-Fail "$required is a reparse point" 'the launcher refuses linked client files; deploy a real copy' }
    }
    $client = ConvertTo-GamePath $game 'red4ext/plugins/Open77/Open77.dll'
    $clientSha = if (Test-Path -LiteralPath $client) { Get-Sha256 $client } else { $null }
    if ($clientSha -and -not $ExpectedClientSha256Prefix) {
        Write-Info "feature client Open77.dll $(Get-Short $clientSha) (pass -ExpectedClientSha256Prefix to check it)"
    }
    elseif ($clientSha -and $clientSha.StartsWith($ExpectedClientSha256Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Ok "feature client Open77.dll $(Get-Short $clientSha) (expected $ExpectedClientSha256Prefix…)"
    }
    elseif ($clientSha) {
        Write-Warn "Open77.dll is $(Get-Short $clientSha), not the expected $ExpectedClientSha256Prefix…" `
            'another session may have deployed over the lab client; redeploy the feature client or pass -ExpectedClientSha256Prefix'
    }
    $config = ConvertTo-GamePath $game 'red4ext/config.ini'
    if (Test-Path -LiteralPath $config) {
        $ini = Get-Content -LiteralPath $config -Raw
        if ($ini -match '(?ms)^\s*\[plugins\][^\[]*?^\s*enabled\s*=\s*false') { Write-Fail 'red4ext/config.ini disables plugins' 'set [plugins] enabled = true' }
        elseif ($ini -match '(?ms)^\s*\[plugins\][^\[]*?^\s*ignored\s*=\s*\[[^\]]*(ArchiveXL|TweakXL)') { Write-Fail 'red4ext/config.ini ignores ArchiveXL or TweakXL' 'remove them from [plugins] ignored (the launcher refuses the world otherwise)' }
        else { Write-Ok 'red4ext/config.ini: plugins enabled, ArchiveXL/TweakXL not ignored' }
    }
    $game77 = @(Get-GameProcesses)
    if ($game77.Count) { Write-Info "Cyberpunk2077 is running now (pid $($game77.Id -join ', ')); strip and launch will refuse until it is closed" }
    $launchers = @(Get-Process -Name Open77Launcher -ErrorAction SilentlyContinue)
    if ($launchers.Count) { Write-Info "Open77Launcher is running now (pid $($launchers.Id -join ', ')); launch will refuse until it is closed" }

    # 2. Launcher build ----------------------------------------------------------------
    Write-Step '2. Launcher (built from the launcher repository HEAD into the work folder)'
    $launcherBuild = $null
    $commit = (& git -C $LauncherRepo rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $commit) { Stop-Phase "$LauncherRepo is not a git checkout" 'pass -LauncherRepo <path to the Open77 launcher repository>' }
    $commit = $commit.Trim()
    $short = $commit.Substring(0, 12)
    $subject = (& git -C $LauncherRepo log -1 --format='%h %cs %s' $commit).Trim()
    Write-Info "launcher commit $subject"
    $dirty = @(& git -C $LauncherRepo status --porcelain --untracked-files=no 2>$null)
    if ($dirty.Count) { Write-Info "the checkout has $($dirty.Count) uncommitted change(s); they are NOT in this build (HEAD only)" }
    $bin = Join-Path $P.LauncherBin $short
    $exePath = Join-Path $bin 'Open77Launcher.exe'
    if ($SkipBuild) {
        Write-Warn 'build skipped (-SkipBuild)' 'run prepare without -SkipBuild before -Phase launch'
    }
    elseif ((Test-Path -LiteralPath $exePath) -and -not $Rebuild) {
        Write-Ok "already built: $exePath"
    }
    else {
        $src = Join-Path $P.LauncherSrc $short
        if (Test-Path -LiteralPath $src) { Remove-Item -LiteralPath $src -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        $tar = Join-Path $P.LauncherSrc "$short.tar"
        & git -C $LauncherRepo archive --format=tar -o $tar $commit src/Open77.Launcher global.json
        if ($LASTEXITCODE -ne 0) { Stop-Phase 'git archive failed' "check that $LauncherRepo is readable" }
        & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $tar -C $src
        if ($LASTEXITCODE -ne 0) { Stop-Phase "tar could not extract $tar" 'check free space in the work folder' }
        Remove-Item -LiteralPath $tar -Force
        $dotnet = @((Get-Command dotnet -ErrorAction SilentlyContinue).Source, 'C:\Program Files\dotnet\dotnet.exe') |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if (-not $dotnet) { Stop-Phase 'dotnet not found' 'install the .NET SDK pinned by the launcher global.json (10.0.3xx)' }
        $saved = @{ SystemDrive = $env:SystemDrive; ALLUSERSPROFILE = $env:ALLUSERSPROFILE; DOTNET_CLI_TELEMETRY_OPTOUT = $env:DOTNET_CLI_TELEMETRY_OPTOUT; DOTNET_NOLOGO = $env:DOTNET_NOLOGO }
        if (-not $env:SystemDrive) { $env:SystemDrive = 'C:' }
        if (-not $env:ALLUSERSPROFILE) { $env:ALLUSERSPROFILE = 'C:\ProgramData' }
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
        $buildLog = Join-Path $P.LauncherBin "$short-build.log"
        New-Item -ItemType Directory -Force -Path $P.LauncherBin | Out-Null
        Write-Info "dotnet build -c Release -o $bin (log: $buildLog)"
        try {
            $output = & $dotnet build (Join-Path $src 'src\Open77.Launcher\Open77.Launcher.csproj') -c Release -o $bin `
                --disable-build-servers -nologo -v:minimal 2>&1
            $code = $LASTEXITCODE
        }
        finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $output | Set-Content -LiteralPath $buildLog -Encoding utf8NoBOM
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $exePath)) {
            $output | Select-Object -Last 25 | ForEach-Object { Write-Host "         $_" }
            Stop-Phase "the launcher build failed (exit $code)" "read $buildLog; the launcher source is untouched, only $src was built"
        }
        Write-Ok "built $exePath"
    }
    if (Test-Path -LiteralPath $exePath) {
        $launcherBuild = [ordered]@{
            Commit = $commit; Exe = $exePath; Sha256 = (Get-Sha256 $exePath)
            Version = (Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion
        }
        Write-Info "Open77Launcher.exe $(Get-Short $launcherBuild.Sha256), version $($launcherBuild.Version)"
    }
    Write-Info 'DevOrigin is not built: the development preset never reads a mod-stack index, and a catalog row cannot carry a loopback world (see the doc)'

    # 3. Lab manifest ------------------------------------------------------------------
    Write-Step '3. Lab required-mod manifest (what Direct Connect reads)'
    $fetched = Get-LabManifest $lab
    $manifest = $fetched.Manifest
    $check = Test-DirectManifest $manifest $fetched.Bytes
    if ($check.Problems.Count) { foreach ($p in $check.Problems) { Write-Fail "manifest: $p" 'fix the lab requiredMods; the launcher would refuse this manifest' } }
    else { Write-Ok "manifest v$($manifest['version']), $(@($manifest['mods']).Count) mods, digest $(Get-Short $manifest['digest']) recomputed and equal" }
    Save-Json (Join-Path $P.Origin 'manifest.json') $manifest
    $hosted = @(@($manifest['mods']) | Where-Object { $_['source'] -eq 'hosted' })
    $indexed = @(@($manifest['mods']) | Where-Object { $_['source'] -ne 'hosted' })
    if ($indexed.Count) { Write-Warn "$($indexed.Count) indexed (non-hosted) mod(s): $(@($indexed | ForEach-Object { $_['id'] }) -join ', ')" 'the development preset cannot install indexed packages; the launcher will refuse the world' }
    $selectedIds = @(Resolve-SelectedIds $hosted)
    Write-Info "selected for strip: $($selectedIds -join ', ')"

    $labConfig = if ($LabRoot) { Join-Path $LabRoot 'server.jsonc' }
    if (-not $labConfig) { Write-Info 'lab server.jsonc not checked (pass -LabRoot or set OP77_VC_LAB_DIR)' }
    elseif (Test-Path -LiteralPath $labConfig) {
        $text = Get-Content -LiteralPath $labConfig -Raw
        $devLocal = $text -match '"devLocalAuth"\s*:\s*true'
        $ticket = $text -match '"requireConnectTicket"\s*:\s*true'
        if ($devLocal -and -not $ticket) { Write-Ok 'lab server.jsonc: devLocalAuth true, requireConnectTicket not true' }
        else { Write-Warn "lab server.jsonc: devLocalAuth=$devLocal requireConnectTicket=$ticket" 'a launcher-started client joins only a devLocalAuth lab without connect tickets (see the doc)' }
    }

    # 4. Blobs -------------------------------------------------------------------------
    Write-Step '4. Every hosted blob: HTTP 200, declared size, SHA-256'
    $packages = [Collections.Generic.List[object]]::new()
    foreach ($m in $hosted) {
        $sha = [string]$m['sha256']; $id = [string]$m['id']
        $uri = "$($lab.ModsBase)blobs/$sha"
        $zip = Join-Path $P.OriginBlobs "$sha.zip"
        try { $response = Invoke-Get $uri $zip }
        catch { Write-Fail "$id GET $uri failed: $($_.Exception.Message)" 'check the lab resource HTTP listener'; continue }
        if ($response.Status -ne 200) { Write-Fail "$id GET blobs/$(Get-Short $sha) -> HTTP $($response.Status)" 'the lab does not serve this blob; rebuild the resource dist zip'; continue }
        $size = (Get-Item -LiteralPath $zip).Length
        $actual = Get-Sha256 $zip
        $okSize = $size -eq [long]$m['sizeBytes'] -and ($null -eq $response.Declared -or $response.Declared -eq $size)
        if ($actual -ne $sha -or -not $okSize) {
            Write-Fail "$id blob: $size B sha $(Get-Short $actual), manifest says $($m['sizeBytes']) B sha $(Get-Short $sha)" 'the lab serves stale bytes; restart the lab after rebuilding (not done by this script)'
            continue
        }
        Write-Ok ("{0,-34} {1,-8} 200 {2,9} B sha {3}" -f $id, $m['version'], $size, (Get-Short $sha))
        $magic = [byte[]]::new(2); $fs = [IO.File]::OpenRead($zip); try { [void]$fs.Read($magic, 0, 2) } finally { $fs.Dispose() }
        if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) { Write-Warn "$id is not a zip; the projection cannot be predicted here" 'none needed if the launcher accepts it (it also reads 7z/rar)'; continue }
        $packages.Add([pscustomobject]@{ Id = $id; Version = [string]$m['version']; Sha256 = $sha; Size = $size; Zip = $zip; Selected = ($selectedIds -contains $id); Files = @(Get-PackageFiles $zip) })
    }

    # 5. Projection prediction ---------------------------------------------------------
    Write-Step '5. Projection prediction (zip entries vs the game folder, as ModProjector.PlanWorld sees it)'
    $byPath = @{}
    $files = [Collections.Generic.List[object]]::new()
    foreach ($package in $packages) {
        foreach ($f in $package.Files) {
            if (-not $f.Root) { Write-Fail "$($package.Id): '$($f.Path)' is outside every mod root" 'the launcher refuses this package; fix the dist zip layout' }
            $key = $f.Path.ToLowerInvariant()
            if ($byPath.ContainsKey($key)) { Write-Warn "$($f.Path) is declared by $($byPath[$key].Package) and $($package.Id)" 'two packages writing one path end in a conflict'; continue }
            $full = ConvertTo-GamePath $game $f.Path
            $state = 'add'; $links = 0; $gameSha = $null
            if (Test-Path -LiteralPath $full) {
                $gameSha = Get-Sha256 $full
                if ($package.Selected) { $links = Get-LinkCount $full }
                $state = if ($gameSha -eq $f.Sha256) { 'kept' } else { 'conflict' }
            }
            $row = [pscustomobject]@{ Package = $package.Id; Selected = $package.Selected; Path = $f.Path; Sha256 = $f.Sha256; Size = $f.Size; State = $state; Links = $links; GameSha256 = $gameSha }
            $byPath[$key] = $row
            $files.Add($row)
        }
    }
    foreach ($package in $packages) {
        $rows = @($files | Where-Object Package -eq $package.Id)
        $line = "{0}{1,-34} {2,3} file(s): {3} kept, {4} missing, {5} differ" -f $(if ($package.Selected) { '* ' } else { '  ' }),
            $package.Id, $rows.Count, @($rows | Where-Object State -eq 'kept').Count, @($rows | Where-Object State -eq 'add').Count,
            @($rows | Where-Object State -eq 'conflict').Count
        Write-Host "         $line"
    }
    foreach ($row in @($files | Where-Object State -eq 'conflict')) {
        Write-Fail "$($row.Path) differs from $($row.Package) (game $(Get-Short $row.GameSha256), package $(Get-Short $row.Sha256))" `
            'the launcher would stop on a world repair offer; align the game file with the lab package before the proof'
    }
    $selectedRows = @($files | Where-Object Selected)
    Write-Host '         files strip will remove (selected packages):'
    foreach ($row in $selectedRows) {
        Write-Host ("           {0,-8} links={1} {2,10} B {3} {4}" -f $row.State, $row.Links, $row.Size, (Get-Short $row.Sha256), $row.Path)
        if ($row.State -eq 'kept' -and $row.Links -ne 1) {
            Write-Fail "$($row.Path) has $($row.Links) hard links" 'it is shared with a mod store; unlink it (copy over itself) before strip, or leave this package out'
        }
        if ($row.State -eq 'add') { Write-Warn "$($row.Path) is already absent from the game folder" 'strip will refuse it unless -Force (nothing to back up)' }
    }
    $missingOthers = @($files | Where-Object { -not $_.Selected -and $_.State -eq 'add' })
    $expectedProjected = $selectedRows.Count + $missingOthers.Count
    $expectedKept = $files.Count - $expectedProjected - @($files | Where-Object State -eq 'conflict').Count
    if ($missingOthers.Count) { Write-Info "$($missingOthers.Count) file(s) of other packages are absent today and will be projected too" }
    Write-Info "expected launcher line after strip: world '$($lab.Endpoint)': projected $expectedProjected file(s), removed 0, kept $expectedKept in place."

    # 6. Ports and footprint -----------------------------------------------------------
    Write-Step '6. Stand-in master port and launch footprint'
    $excluded = Test-PortExcluded $MasterPort
    if ($excluded) { Write-Fail "TCP $MasterPort is inside the Windows excluded range $excluded" 'the client enrolls the development master at 127.0.0.1:8090 only; free the range (netsh int ipv4 delete excludedportrange) or reboot' }
    elseif (Test-TcpListening $MasterPort) { Write-Warn "TCP $MasterPort is in use ($(Get-TcpOwner $MasterPort))" 'stop the local master (or whatever listens) before -Phase launch; launch refuses while it is taken' }
    else { Write-Ok "TCP $MasterPort is free for the stand-in master" }
    $open = Get-OpenDirectory
    $sessionPath = Join-Path $open 'launcher-session-v1.dat'
    Write-Info "launch will move $sessionPath aside ($(if (Test-Path -LiteralPath $sessionPath) { 'present' } else { 'absent' })) and restore it byte for byte"
    foreach ($item in @("launcher-webview.$Instance", "identity-$Instance-v1.dat")) {
        Write-Info "$item under $open is $(if (Test-Path -LiteralPath (Join-Path $open $item)) { 'present (kept by restore)' } else { 'absent (created by the run, removed by restore)' })"
    }
    $scheme = Get-SchemeSnapshot
    Write-Info "open77:// handler now: $(if ($scheme.CommandExists) { $scheme.Command } else { '(none)' }); launch records it, restore puts it back"

    $state = [ordered]@{
        PreparedUtc      = [DateTimeOffset]::UtcNow.ToString('o')
        GameDirectory    = $game
        GameSha256       = $exeSha
        GameBuild        = $gameBuild
        ClientSha256     = $clientSha
        Launcher         = $launcherBuild
        Lab              = [ordered]@{ Endpoint = $lab.Endpoint; ModsBase = $lab.ModsBase; Digest = [string]$manifest['digest']; ModCount = @($manifest['mods']).Count }
        Selected         = $selectedIds
        Packages         = @($packages | ForEach-Object { [ordered]@{ Id = $_.Id; Version = $_.Version; Sha256 = $_.Sha256; Size = $_.Size; Zip = $_.Zip; Selected = $_.Selected } })
        Files            = @($files | ForEach-Object { [ordered]@{ Package = $_.Package; Selected = $_.Selected; Path = $_.Path; Sha256 = $_.Sha256; Size = $_.Size; State = $_.State; Links = $_.Links } })
        ExpectedProjected = $expectedProjected
        ExpectedKept     = $expectedKept
    }
    Save-Json $P.Prepare $state
    Write-Info "snapshot written: $($P.Prepare)"
    Complete-Phase "pwsh -File $PSCommandPath -Phase strip$WorkDirArg"
}

# ═══ strip ═════════════════════════════════════════════════════════════════════════════

function Invoke-Strip {
    $P = Get-Paths
    $prepared = Get-PrepareState $P
    $game = $prepared['GameDirectory']
    Write-Host 'prove-launcher-delivery: strip (removes the hand-installed pack files, after a verified backup)'
    Write-Info "game folder   $game"
    Assert-GameClosed $game
    if (Test-Path -LiteralPath $P.StripState) {
        $previous = Read-Json $P.StripState
        if ($previous['Status'] -ne 'restored') {
            Stop-Phase "a previous strip ($($previous['StrippedUtc'])) is not restored yet (status $($previous['Status']))" `
                "run -Phase restore first; its backup is in $($P.Strip)"
        }
    }
    $selected = @($prepared['Selected'])
    $rows = @(@($prepared['Files']) | Where-Object { $selected -contains $_['Package'] })
    if (-not $rows.Count) { Stop-Phase 'the prepare snapshot lists no file for the selected packages' 'rerun -Phase prepare with the -Packages you want' }

    Write-Step '1. Preconditions (nothing is touched unless every file passes)'
    $plan = [Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        $full = ConvertTo-GamePath $game $row['Path']
        if (-not (Test-Path -LiteralPath $full)) {
            if ($Force) { Write-Warn "$($row['Path']) is already absent; recorded as absent" ''; $plan.Add([ordered]@{ Path = $row['Path']; Package = $row['Package']; Sha256 = $row['Sha256']; Present = $false }); continue }
            Stop-Phase "$($row['Path']) is absent from the game folder" 'the install is already without this file: run -Phase restore of the earlier proof, or pass -Force to record it as absent'
        }
        $sha = Get-Sha256 $full
        if ($sha -ne $row['Sha256']) {
            Stop-Phase "$($row['Path']) is $(Get-Short $sha), the lab package declares $(Get-Short $row['Sha256'])" 'the file changed since prepare; rerun -Phase prepare'
        }
        $links = Get-LinkCount $full
        if ($links -ne 1) {
            Stop-Phase "$($row['Path']) has $links hard links (fsutil hardlink list)" 'it shares bytes with a mod store; unlink it first (copy it over itself), then rerun strip'
        }
        if (Test-ReparsePoint $full) { Stop-Phase "$($row['Path']) is a reparse point" 'replace it by a real file, then rerun strip' }
        $item = Get-Item -LiteralPath $full -Force
        Write-Ok "$($row['Path'])  sha $(Get-Short $sha)  links=1"
        $plan.Add([ordered]@{
                Path = $row['Path']; Package = $row['Package']; Sha256 = $sha; Size = $item.Length; Present = $true
                Attributes = [int]$item.Attributes; CreationUtcTicks = $item.CreationTimeUtc.Ticks; LastWriteUtcTicks = $item.LastWriteTimeUtc.Ticks
            })
    }

    Write-Step '2. Backup (copied and re-hashed before anything is removed)'
    $filesDir = Join-Path $P.Strip 'files'
    foreach ($entry in @($plan | Where-Object { $_.Present })) {
        $target = ConvertTo-GamePath $filesDir $entry.Path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath (ConvertTo-GamePath $game $entry.Path) -Destination $target -Force
        if ((Get-Sha256 $target) -ne $entry.Sha256) { Stop-Phase "the backup of $($entry.Path) does not hash back" "check the disk under $filesDir; nothing was removed" }
        $entry.Backup = $target
        Write-Ok "backed up $($entry.Path)"
    }
    $cacheDir = Join-Path $P.Strip 'r6cache'
    $cache = foreach ($relative in $ScriptCacheFiles) {
        $full = ConvertTo-GamePath $game $relative
        if (Test-Path -LiteralPath $full) {
            $target = ConvertTo-GamePath $cacheDir $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $full -Destination $target -Force
            [ordered]@{ Path = $relative; Sha256 = (Get-Sha256 $full); Backup = $target }
        }
    }
    Write-Info "script cache snapshot (copied, not removed): $(@($cache).Count) file(s); the launcher resets these on a non-empty projection"
    $guarded = foreach ($relative in $GuardedFiles) {
        $full = ConvertTo-GamePath $game $relative
        [ordered]@{ Path = $relative; Sha256 = $(if (Test-Path -LiteralPath $full) { Get-Sha256 $full } else { $null }) }
    }
    $state = [ordered]@{
        Status = 'removing'; StrippedUtc = [DateTimeOffset]::UtcNow.ToString('o'); GameDirectory = $game
        Files = @($plan); ScriptCache = @($cache); Guarded = @($guarded)
    }
    Save-Json $P.StripState $state

    Write-Step '3. Remove'
    foreach ($entry in @($plan | Where-Object { $_.Present })) {
        $full = ConvertTo-GamePath $game $entry.Path
        Remove-Item -LiteralPath $full -Force
        if (Test-Path -LiteralPath $full) { Write-Fail "$($entry.Path) is still present" 'close whatever holds it, then run -Phase restore and start again' }
        else { Write-Ok "removed $($entry.Path)" }
    }
    $state.Status = if ($script:Failures) { 'partial' } else { 'stripped' }
    Save-Json $P.StripState $state
    $client = @($guarded | Where-Object { $_.Path -eq 'red4ext/plugins/Open77/Open77.dll' })[0]
    Write-Info "feature client kept: Open77.dll $(Get-Short $client.Sha256) (the development preset never writes red4ext/plugins/Open77)"
    Write-Info "state: $($P.StripState)"
    Complete-Phase "pwsh -File $PSCommandPath -Phase launch$WorkDirArg"
}

# ═══ launch ════════════════════════════════════════════════════════════════════════════

function Invoke-Launch {
    $P = Get-Paths
    $prepared = Get-PrepareState $P
    $game = $prepared['GameDirectory']
    $lab = Get-LabInfo
    Write-Host 'prove-launcher-delivery: launch (stand-in master + isolated launcher, Direct Connect to the lab)'
    Write-Step '1. Preconditions'
    Assert-GameClosed
    $launchers = @(Get-Process -Name Open77Launcher -ErrorAction SilentlyContinue)
    if ($launchers.Count) {
        Stop-Phase "Open77Launcher is running (pid $($launchers.Id -join ', '))" 'close every launcher window and its tray icon: launch swaps the shared session file under it'
    }
    if (-not (Test-Path -LiteralPath $P.StripState)) { Stop-Phase 'strip has not run' "run -Phase strip first" }
    $strip = Read-Json $P.StripState
    if ($strip['Status'] -ne 'stripped') { Stop-Phase "strip state is '$($strip['Status'])'" 'run -Phase restore, then strip again' }
    foreach ($entry in @($strip['Files'] | Where-Object { $_['Present'] })) {
        if (Test-Path -LiteralPath (ConvertTo-GamePath $game $entry['Path'])) {
            Stop-Phase "$($entry['Path']) is back in the game folder" 'something re-installed it (another launcher?); run -Phase restore, then strip again'
        }
    }
    Write-Ok "$(@($strip['Files'] | Where-Object { $_['Present'] }).Count) stripped file(s) still absent"
    if (Test-Path -LiteralPath $P.LaunchState) {
        $previous = Read-Json $P.LaunchState
        if ($previous['Status'] -ne 'restored') { Stop-Phase "a previous launch ($($previous['StartedUtc'])) is not restored" 'run -Phase restore first' }
    }
    $exe = if ($prepared['Launcher']) { $prepared['Launcher']['Exe'] } else { $null }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { Stop-Phase 'no launcher build in the work folder' 'run -Phase prepare without -SkipBuild' }
    $manifest = (Get-LabManifest $lab).Manifest
    if ([string]$manifest['digest'] -ne $prepared['Lab']['Digest']) {
        Stop-Phase "the lab now announces digest $(Get-Short $manifest['digest']), prepare saw $(Get-Short $prepared['Lab']['Digest'])" 'the lab changed: run -Phase restore, then prepare and strip again'
    }
    Write-Ok "lab still announces digest $(Get-Short $manifest['digest'])"
    $excluded = Test-PortExcluded $MasterPort
    if ($excluded) { Stop-Phase "TCP $MasterPort is in the excluded range $excluded" 'free it (netsh int ipv4 delete excludedportrange protocol=tcp ...) or reboot' }
    if (Test-TcpListening $MasterPort) { Stop-Phase "TCP $MasterPort is taken ($(Get-TcpOwner $MasterPort))" 'stop the local master or whatever listens there; the client enrolls the development master on 8090 only' }
    Write-Ok "TCP $MasterPort free"

    Write-Step '2. Footprint snapshot (what restore puts back)'
    $open = Get-OpenDirectory
    New-Item -ItemType Directory -Force -Path $open | Out-Null
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $run = Join-Path $P.Runs $stamp
    New-Item -ItemType Directory -Force -Path (Join-Path $run 'modstore'), (Join-Path $run 'settings'), (Join-Path $run 'master'), (Join-Path $run 'footprint') | Out-Null
    $logPath = Join-Path $open 'launcher.log'
    $logLength = 0L; $logPrefix = $null
    if (Test-Path -LiteralPath $logPath) {
        $bytes = Read-SharedBytes $logPath
        $logLength = $bytes.LongLength
        $logPrefix = Get-BytesSha256 $bytes
    }
    $sessionPath = Join-Path $open 'launcher-session-v1.dat'
    $session = [ordered]@{ Existed = (Test-Path -LiteralPath $sessionPath); Sha256 = $null; Backup = $null }
    $webview = Join-Path $open "launcher-webview.$Instance"
    $identity = Join-Path $open "identity-$Instance-v1.dat"
    $listing = @(Get-ChildItem -LiteralPath $open -Force | ForEach-Object { [ordered]@{ Name = $_.Name; Directory = $_.PSIsContainer; Length = $(if ($_.PSIsContainer) { 0 } else { $_.Length }); LastWriteUtc = $_.LastWriteTimeUtc.ToString('o') } })
    $saves = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Saved Games\CD Projekt Red\Cyberpunk 2077'
    $templates = @(Get-ChildItem -LiteralPath $saves -Directory -Filter 'NCMP-Template-*' -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -File | ForEach-Object { [ordered]@{ Path = $_.FullName; Sha256 = (Get-Sha256 $_.FullName) } } })
    $accountId = [guid]::NewGuid().ToString()
    $state = [ordered]@{
        Status = 'launching'; StartedUtc = [DateTimeOffset]::UtcNow.ToString('o'); StartedUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        RunDirectory = $run; Exe = $exe; Instance = $Instance; AccountId = $accountId; Endpoint = $lab.Endpoint
        LauncherLog = [ordered]@{ Path = $logPath; Length = $logLength; PrefixSha256 = $logPrefix }
        Session = $session; WebviewExisted = (Test-Path -LiteralPath $webview); IdentityExisted = (Test-Path -LiteralPath $identity)
        Scheme = (Get-SchemeSnapshot); OpenListing = $listing; Templates = $templates
        LauncherPid = $null; MasterPid = $null
    }
    Save-Json $P.LaunchState $state
    Write-Ok "launcher.log at $logLength byte(s); open77:// handler recorded; $($listing.Count) item(s) listed in $open"

    if ($session.Existed) {
        $session.Sha256 = Get-Sha256 $sessionPath
        $session.Backup = Join-Path $run 'footprint\launcher-session-v1.dat'
        Move-Item -LiteralPath $sessionPath -Destination $session.Backup
        if ((Get-Sha256 $session.Backup) -ne $session.Sha256) { Stop-Phase 'the moved session does not hash back' "put $($session.Backup) back to $sessionPath by hand" }
        Save-Json $P.LaunchState $state
        Write-Ok "player session moved aside to $($session.Backup) ($(Get-Short $session.Sha256))"
    }
    else { Write-Info 'no player session to move aside' }
    Write-SeededSession $sessionPath $accountId $PlayerName $prepared['GameSha256']
    Write-Ok "stand-in session seeded for '$PlayerName' (account $accountId, random token, expires in 12 h)"

    Write-Step '3. Stand-in master on 127.0.0.1:8090'
    $pwsh = [Environment]::ProcessPath
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Phase serve-master -WorkDir `"$($P.Work)`" -RunDirectory `"$run`" -PlayerName `"$PlayerName`""
    $master = Start-Process -FilePath $pwsh -ArgumentList $arguments -WindowStyle Minimized -PassThru
    $state.MasterPid = $master.Id
    Save-Json $P.LaunchState $state
    $ready = $false
    for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
        Start-Sleep -Milliseconds 500
        try { $probe = Invoke-Get "$($MasterBase)healthz"; $ready = $probe.Status -eq 200 -and $probe.Headers.ContainsKey($StandinHeader) } catch { }
        if ($master.HasExited) { break }
    }
    if (-not $ready) { Stop-Phase "the stand-in master (pid $($master.Id)) did not answer $($MasterBase)healthz" "read $run\master\requests.log, then run -Phase restore" }
    Write-Ok "stand-in master pid $($master.Id) answers (log: $run\master\requests.log)"

    Write-Step '4. Isolated launcher'
    $settingsPath = Join-Path $run 'settings\launcher-settings.json'
    Save-Json $settingsPath ([ordered]@{
            gameDirectory = $game; master = 'development'; checkForUpdates = $false; discordRichPresence = $false
            officialDirectoryMigration149 = $true
        })
    $environment = @{
        OP77_LAUNCHER_MASTER_URL = $MasterBase; OP77_LAUNCHER_WEBSITE_URL = $MasterBase; OP77_LAUNCHER_CDN_URL = $MasterBase
        OP77_LAUNCHER_MODSTORE = (Join-Path $run 'modstore'); OP77_LAUNCHER_SETTINGS = $settingsPath
        OP77_LAUNCHER_INSTANCE = $Instance; OP77_IDENTITY_PROFILE = $Instance; OP77_PLAYER_NAME = $PlayerName
        OP77_GAME_DIR = $game
        OP77_LAUNCHER_MODSTACK = $null; OP77_MODSTACK_INDEX_KEY = $null; OP77_DISCORD_APPLICATION_ID = $null
        OP77_CONNECT = $null; OP77_CONNECT_MASTER = $null; OP77_WORLD_SERVER = $null; OP77_WORLD_MODS_DIGEST = $null
    }
    $deepLink = "open77://connect?endpoint=$($lab.Endpoint)"
    $launcher = Start-Process -FilePath $exe -ArgumentList $deepLink -WorkingDirectory (Split-Path -Parent $exe) -Environment $environment -PassThru
    $state.LauncherPid = $launcher.Id
    $state.Status = 'launched'
    Save-Json $P.LaunchState $state
    Write-Ok "launcher pid $($launcher.Id): $exe $deepLink"
    foreach ($k in @($environment.Keys | Sort-Object)) { if ($null -ne $environment[$k]) { Write-Host "         $k=$($environment[$k])" } }

    Write-Host ''
    Write-Host 'In the launcher window:' -ForegroundColor Cyan
    Write-Host "  1. It opens signed in as '$PlayerName' (stand-in session) and verifies the game."
    Write-Host "  2. A consent dialog names $($prepared['Lab']['ModCount']) packages from $($lab.Endpoint), unreviewed executables included"
    Write-Host '     (ArchiveXL, TweakXL). Accept it: that is the player''s step this proof keeps.'
    Write-Host '  3. It downloads, projects the stripped files, then starts the game into the lab.'
    Write-Host "  4. Once the character stands in the world (or the game stopped trying), run -Phase verify."
    Write-Host "Leave the minimized stand-in master window open until -Phase restore."
    Complete-Phase "pwsh -File $PSCommandPath -Phase verify$WorkDirArg"
}

# ═══ serve-master (internal) ═══════════════════════════════════════════════════════════

function Invoke-ServeMaster {
    if (-not $RunDirectory) { Stop-Phase 'serve-master needs -RunDirectory' 'it is started by -Phase launch; do not run it by hand' }
    Initialize-Native
    $P = Get-Paths
    $state = if (Test-Path -LiteralPath $P.LaunchState) { Read-Json $P.LaunchState } else { $null }
    [VcProof.StandinMaster]::DefaultName = $PlayerName
    if ($state -and $state['AccountId']) { [VcProof.StandinMaster]::AccountId = $state['AccountId'] }
    $host.UI.RawUI.WindowTitle = "Open77 stand-in master 127.0.0.1:$MasterPort (vc launcher proof)"
    $log = Join-Path $RunDirectory 'master\requests.log'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
    [VcProof.StandinMaster]::Run($MasterPort, $log, (Join-Path $RunDirectory 'master\stop'))
}

# ═══ verify ════════════════════════════════════════════════════════════════════════════

function Invoke-Verify {
    $P = Get-Paths
    $prepared = Get-PrepareState $P
    if (-not (Test-Path -LiteralPath $P.LaunchState)) { Stop-Phase 'launch has not run' 'run -Phase launch first' }
    $launch = Read-Json $P.LaunchState
    $strip = Read-Json $P.StripState
    $game = $prepared['GameDirectory']
    $run = $launch['RunDirectory']
    $started = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$launch['StartedUnixMs']).LocalDateTime
    $endpoint = $launch['Endpoint']
    $stripped = @($strip['Files'] | Where-Object { $_['Present'] })
    $verdict = [ordered]@{}
    Write-Host 'prove-launcher-delivery: verify (wiki/mods.md "Verifying that a mod loaded", steps 1, 2, 3 and 5)'
    Write-Info "run $run, started $started"

    # Step 1 ---------------------------------------------------------------------------
    Write-Step '1. Launcher log at the Connect'
    $logInfo = $launch['LauncherLog']
    $text = ''
    if (Test-Path -LiteralPath $logInfo['Path']) {
        $raw = Read-SharedBytes $logInfo['Path']
        $all = [Text.Encoding]::UTF8.GetString($raw)
        if ($raw.LongLength -ge $logInfo['Length'] -and ($logInfo['Length'] -eq 0 -or (Get-PrefixSha256 $raw $logInfo['Length']) -eq $logInfo['PrefixSha256'])) {
            $text = [Text.Encoding]::UTF8.GetString($raw, [int]$logInfo['Length'], $raw.Length - [int]$logInfo['Length'])
        }
        else {
            $previous = [IO.Path]::ChangeExtension($logInfo['Path'], '.previous.log')
            Write-Info 'launcher.log rotated during the run; reading launcher.previous.log too'
            if (Test-Path -LiteralPath $previous) { $text = (Read-Shared $previous) + "`n" }
            $text += $all
        }
    }
    $lines = @($text -split "`r?`n")
    $patterns = [ordered]@{
        'connect requested'  = "connect requested: world '.*' @ $([regex]::Escape($endpoint))"
        'consent approved'   = "Unreviewed executable mods explicitly approved for world"
        'unsecured content'  = 'unsecured world: accepting unreviewed executable content'
        'modstack projected' = 'modstack: projected \d+ file\(s\)'
        'world projected'    = "world '(?<name>[^']+)': projected (?<added>\d+) file\(s\), removed (?<removed>\d+), kept (?<kept>\d+) in place\."
        'script cache reset' = 'script cache: \d+ file\(s\) reset'
        'game launched'      = 'launched pid (?<pid>\d+) from .*OP77_CONNECT=(?<ep>\S+) OP77_CONNECT_MASTER=(?<master>\S+)'
    }
    $found = @{}
    foreach ($name in $patterns.Keys) {
        $hit = @($lines | Where-Object { $_ -match $patterns[$name] })
        if ($hit.Count) { $found[$name] = $hit; foreach ($h in $hit | Select-Object -First 3) { Write-Info ("{0,-19} {1}" -f $name, $h.Trim()) } }
    }
    foreach ($bad in @('world mod fetch failed', 'world mod projection (refused|failed)', 'connect refused', 'mod attestation lookup failed',
            'connect paused', 'launch refused', 'game launch failed', 'hashed to [0-9a-f]+, expected')) {
        foreach ($h in @($lines | Where-Object { $_ -match $bad })) { Write-Fail "launcher: $($h.Trim())" 'the reason is in the line; fix it, then restore and run strip/launch again' }
    }
    $worldLine = if ($found.ContainsKey('world projected')) { @($found['world projected'])[-1] } else { $null }
    if ($worldLine -and $worldLine -match $patterns['world projected']) {
        $added = [int]$Matches.added; $kept = [int]$Matches.kept; $removed = [int]$Matches.removed
        if ($added -eq [int]$prepared['ExpectedProjected'] -and $kept -eq [int]$prepared['ExpectedKept'] -and $removed -eq 0) {
            Write-Ok "world '$($Matches.name)': projected $added, removed 0, kept $kept in place, as predicted"
        }
        else { Write-Warn "projected $added / removed $removed / kept $kept; prepare predicted $($prepared['ExpectedProjected']) / 0 / $($prepared['ExpectedKept'])" 'the game folder changed between prepare and launch (another session?); step 2 says which files' }
        $verdict['1 launcher log'] = 'pass'
    }
    else {
        Write-Fail "no \"world '...': projected\" line after byte $($logInfo['Length']) of $($logInfo['Path'])" `
            'the Connect did not reach the projection: accept the consent dialog in the launcher, or read the refusal above'
        $verdict['1 launcher log'] = 'fail'
    }
    if ($found.ContainsKey('game launched') -and @($found['game launched'])[-1] -match $patterns['game launched']) {
        if ($Matches.ep -eq $endpoint -and $Matches.master -eq 'development') { Write-Ok "game pid $($Matches.pid) launched with OP77_CONNECT=$($Matches.ep) OP77_CONNECT_MASTER=development" }
        else { Write-Warn "game launched with OP77_CONNECT=$($Matches.ep) master=$($Matches.master)" 'the launcher was not started by -Phase launch' }
    }
    else { Write-Warn 'no "launched pid" line yet' 'the launcher has not started the game; finish the dialog or read the launcher log' }

    # Step 2 ---------------------------------------------------------------------------
    Write-Step '2. Files on disk'
    $store = Join-Path $run 'modstore'
    $journalPath = Join-Path $store 'state\projection.json'
    $journal = @{}
    if (Test-Path -LiteralPath $journalPath) {
        $j = Read-Json $journalPath
        foreach ($f in @($j['files'])) { if ($f -and $f['path']) { $journal[([string]$f['path']).ToLowerInvariant()] = $f } }
        Write-Info "isolated journal $journalPath lists $($journal.Count) file(s)"
    }
    else { Write-Warn "no projection journal at $journalPath" 'the launcher has not committed a projection in the isolated store' }
    $step2 = $true
    foreach ($entry in $stripped) {
        $relative = $entry['Path']
        $full = ConvertTo-GamePath $game $relative
        if (-not (Test-Path -LiteralPath $full)) { Write-Fail "$relative is not in the game folder" 'the launcher did not project it; see step 1'; $step2 = $false; continue }
        $sha = Get-Sha256 $full
        $links = Get-LinkCount $full
        $blob = Join-Path $store ("blobs\{0}\{1}" -f $entry['Sha256'].Substring(0, 2), $entry['Sha256'])
        $blobOk = (Test-Path -LiteralPath $blob) -and (Get-Sha256 $blob) -eq $entry['Sha256']
        $j = $journal[$relative.ToLowerInvariant()]
        $mode = if ($j) { "$($j['mode'])/$($j['layer'])" } else { 'not journaled' }
        if ($sha -eq $entry['Sha256'] -and $blobOk -and $links -eq 1) {
            Write-Ok "$relative  sha $(Get-Short $sha)  links=$links  store blob ok  journal $mode"
        }
        else {
            Write-Fail "$relative  sha $(Get-Short $sha) (want $(Get-Short $entry['Sha256']))  links=$links  store blob $(if ($blobOk) { 'ok' } else { 'missing/bad' })  journal $mode" `
                'world files are projected as copies (one link) from verified store blobs; anything else means another writer'
            $step2 = $false
        }
    }
    $drift = @(@($prepared['Files']) | Where-Object { $_['State'] -eq 'kept' -and -not $_['Selected'] } | Where-Object {
            $f = ConvertTo-GamePath $game $_['Path']; -not (Test-Path -LiteralPath $f) -or (Get-Sha256 $f) -ne $_['Sha256'] })
    if ($drift.Count) { foreach ($d in $drift) { Write-Fail "$($d['Path']) (kept in place) changed" 'another session wrote into the game folder' }; $step2 = $false }
    else { Write-Ok "the $(@(@($prepared['Files']) | Where-Object { $_['State'] -eq 'kept' -and -not $_['Selected'] }).Count) files kept in place are unchanged" }
    foreach ($g in @($strip['Guarded'])) {
        $full = ConvertTo-GamePath $game $g['Path']
        $now = if (Test-Path -LiteralPath $full) { Get-Sha256 $full } else { $null }
        if ($now -ne $g['Sha256']) { Write-Fail "$($g['Path']) changed during the proof ($(Get-Short $g['Sha256']) -> $(Get-Short $now))" 'the lab client or loader chain was replaced; the launcher should not do that in the development preset'; $step2 = $false }
    }
    if ($step2) { Write-Ok "feature client and loader chain unchanged (Open77.dll $(Get-Short (@($strip['Guarded'] | Where-Object { $_['Path'] -like '*Open77.dll' })[0]['Sha256'])))" }
    $missingBlobs = @(@($prepared['Packages']) | Where-Object {
            $b = Join-Path $store ("blobs\{0}\{1}" -f $_['Sha256'].Substring(0, 2), $_['Sha256']); -not (Test-Path -LiteralPath $b) })
    if ($missingBlobs.Count) { Write-Warn "$($missingBlobs.Count) package archive(s) not in the isolated store: $(@($missingBlobs | ForEach-Object { $_['Id'] }) -join ', ')" 'the download did not complete' }
    else { Write-Ok "all $(@($prepared['Packages']).Count) package archives are in the isolated store (the store started empty: each one was downloaded)" }
    $history = Join-Path $run 'settings\transfer-history.json'
    if (Test-Path -LiteralPath $history) {
        $events = @(Get-Content -LiteralPath $history -Raw | ConvertFrom-Json -AsHashtable)
        $grouped = $events | Group-Object { $_['State'] } | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-Info "transfer-history.json: $($events.Count) event(s) ($($grouped -join ', '))"
    }
    $verdict['2 files on disk'] = if ($step2) { 'pass' } else { 'fail' }

    # Step 3 ---------------------------------------------------------------------------
    Write-Step '3. Loader logs after the game booted'
    $red4ext = Find-NewestLog (Join-Path $game 'red4ext\logs') 'red4ext-*.log' $started
    $archivexl = Find-NewestLog (Join-Path $game 'red4ext\plugins\ArchiveXL') 'ArchiveXL*.log' $started
    $tweakxl = Find-NewestLog (Join-Path $game 'red4ext\plugins\TweakXL') 'TweakXL*.log' $started
    $client = Find-NewestLog (Join-Path $game 'red4ext\logs') 'open77-*.log' $started
    $step3 = $true
    if (-not $red4ext) {
        Write-Fail "no red4ext log written since $started" 'the game has not booted RED4ext yet: wait for the main menu, then rerun verify'
        $step3 = $false
    }
    else {
        $redText = Read-Shared $red4ext.FullName
        foreach ($plugin in @('ArchiveXL', 'TweakXL', 'Open77')) {
            $line = @($redText -split "`r?`n" | Where-Object { $_ -match "\] $plugin \(version: [^)]*\) has been loaded" -or $_ -match "\] $plugin .*has been loaded" })
            if ($line.Count) { Write-Ok "$($red4ext.Name): $plugin loaded" } else { Write-Fail "$($red4ext.Name): no '$plugin ... has been loaded' line" "read $($red4ext.FullName)"; $step3 = $false }
        }
    }
    $axText = if ($archivexl) { Read-Shared $archivexl.FullName } else { '' }
    $txText = if ($tweakxl) { Read-Shared $tweakxl.FullName } else { '' }
    $gamePid = @(Get-GameProcesses | Select-Object -ExpandProperty Id)
    if ($gamePid.Count) { Initialize-Native }
    foreach ($entry in $stripped) {
        $relative = $entry['Path']
        $tag = "[$($entry['Package'])] $relative"
        if ($relative -match '^r6/tweaks/(?<rest>.+)$') {
            $needle = 'Reading "' + ($Matches.rest -replace '/', '\') + '"'
            if ($txText.Contains($needle)) { Write-Ok "$tag -> $($tweakxl.Name): $needle" }
            else { Write-Fail "$tag -> no $needle in $(if ($tweakxl) { $tweakxl.Name } else { 'any TweakXL log since the launch' })" 'TweakXL did not read it: check the game reached the main menu and the file is under r6\tweaks'; $step3 = $false }
            $errors = @($txText -split "`r?`n" | Where-Object { $_ -match '\[error\]' -and $_ -like "*$([IO.Path]::GetFileNameWithoutExtension($relative))*" })
            foreach ($e in $errors) { Write-Fail "TweakXL: $($e.Trim())" 'a record error in the pack'; $step3 = $false }
        }
        elseif ($relative -match '^archive/pc/mod/(?<name>[^/]+\.xl)$') {
            $needle = 'Loading "' + $Matches.name + '"'
            if ($axText.Contains($needle)) { Write-Ok "$tag -> $($archivexl.Name): $needle" }
            else { Write-Fail "$tag -> no $needle in $(if ($archivexl) { $archivexl.Name } else { 'any ArchiveXL log since the launch' })" 'ArchiveXL did not register it'; $step3 = $false }
        }
        elseif ($relative -match '^red4ext/plugins/(?<p>[^/]+)/[^/]+\.dll$') {
            Write-Info "$tag -> RED4ext plugin $($Matches.p) (see the plugin lines above)"
        }
        elseif ($relative -match '^archive/pc/mod/[^/]+\.archive$') {
            # REDengine mounts archive/pc/mod silently: no loader prints a line for a plain .archive.
            $xl = "$relative.xl"
            $hasXl = @($stripped | Where-Object { $_['Path'] -eq $xl }).Count -gt 0
            $holders = @()
            if ($gamePid.Count) { try { $holders = @([VcProof.FileHolders]::Holders((ConvertTo-GamePath $game $relative))) } catch { Write-Info "file-in-use probe failed: $($_.Exception.Message)" } }
            $held = @($holders | Where-Object { $gamePid -contains $_ })
            if ($held.Count) { Write-Ok "$tag -> held open by Cyberpunk2077 pid $($held -join ', ') (inference: the engine keeps mounted archives open)" }
            elseif ($hasXl) { Write-Info "$tag -> no engine line for a .archive; its .archive.xl is checked separately" }
            elseif ($gamePid.Count) { Write-Warn "$tag -> not reported as held open by the game" 'inconclusive, not a failure: check it in game (step 4: /car with the pack applied)' }
            else { Write-Info "$tag -> no loader line exists for a plain .archive; rerun verify while the game runs for the file-in-use probe" }
        }
        else { Write-Info "$tag -> no loader prints a line for this file type" }
    }
    if ($client) {
        $clientLines = @((Read-Shared $client.FullName) -split "`r?`n")
        foreach ($pattern in @("connection attempt=\d+ endpoint=$([regex]::Escape($endpoint)) master=\S*", 'enrollment failed reason=\S+',
                'network phase=active', 'loading handoff complete', 'first placement landed', 'worldReady matched pristine transition')) {
            $hit = @($clientLines | Where-Object { $_ -match $pattern }) | Select-Object -Last 1
            if ($hit -and $pattern -like 'enrollment failed*') { Write-Fail "client: $($hit -replace '^.*\[shell-transition\] ', '')" 'the client could not enroll against the stand-in master: check its requests.log; fallback in the doc' }
            elseif ($hit) { Write-Info "client $($client.Name): $($hit -replace '^.*\[shell-transition\] ', '')" }
        }
    }
    else { Write-Info 'no Open77 client log since the launch yet' }
    $verdict['3 loader logs'] = if ($step3) { 'pass' } else { 'fail' }

    # Step 5 ---------------------------------------------------------------------------
    Write-Step '5. Server side'
    $step5 = $true
    $labLog = if ($LabRoot) { Find-NewestLog (Join-Path $LabRoot 'logs') 'server-*.log' ([datetime]::MinValue) }
    if ($labLog) {
        $declared = @((Read-Shared $labLog.FullName) -split "`r?`n" | Where-Object { $_ -match 'Required mods: (?<n>\d+) declared, digest=(?<d>[0-9a-f]{64})' }) | Select-Object -Last 1
        if ($declared -and $declared -match 'Required mods: (?<n>\d+) declared, digest=(?<d>[0-9a-f]{64})') {
            if ([int]$Matches.n -eq [int]$prepared['Lab']['ModCount'] -and $Matches.d -eq $prepared['Lab']['Digest']) { Write-Ok "$($labLog.Name): Required mods: $($Matches.n) declared, digest $(Get-Short $Matches.d)" }
            else { Write-Fail "$($labLog.Name): $($Matches.n) declared, digest $(Get-Short $Matches.d); prepare saw $($prepared['Lab']['ModCount']) / $(Get-Short $prepared['Lab']['Digest'])" 'the lab restarted with another set; restore and start over'; $step5 = $false }
        }
        else { Write-Warn "no 'Required mods: N declared' line in $($labLog.Name)" 'read the lab log' }
    }
    else { Write-Warn "no lab log$(if ($LabRoot) { " under $LabRoot\logs" })" 'pass -LabRoot or set OP77_VC_LAB_DIR' }
    Write-Info 'the lab does not log GET /mods/v1/blobs hits; the requests are re-made here and the client-side store (step 2) shows what was downloaded'
    $lab = Get-LabInfo
    foreach ($package in @($prepared['Packages'])) {
        $zip = Join-Path $run "footprint\recheck-$($package['Sha256']).zip"
        try { $response = Invoke-Get "$($lab.ModsBase)blobs/$($package['Sha256'])" $zip }
        catch { Write-Fail "$($package['Id']): $($_.Exception.Message)" 'the lab resource HTTP listener is down'; $step5 = $false; continue }
        $ok = $response.Status -eq 200 -and (Get-Item -LiteralPath $zip).Length -eq [long]$package['Size'] -and (Get-Sha256 $zip) -eq $package['Sha256']
        if ($ok) { if ($package['Selected']) { Write-Ok ("GET blobs/{0} 200 {1} B ({2})" -f (Get-Short $package['Sha256']), $package['Size'], $package['Id']) } }
        else { Write-Fail "GET blobs/$(Get-Short $package['Sha256']) ($($package['Id'])) -> $($response.Status)" 'the lab serves other bytes than it announced'; $step5 = $false }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
    if ($step5) { Write-Ok "all $(@($prepared['Packages']).Count) blob URLs re-checked (200, size, SHA-256); selected ones listed" }
    $requests = Join-Path $run 'master\requests.log'
    if (Test-Path -LiteralPath $requests) {
        $req = @(Get-Content -LiteralPath $requests)
        $enroll = @($req | Where-Object { $_ -match 'POST /api/v1/identities/enroll -> (\d+)' }) | Select-Object -Last 1
        $catalog = @($req | Where-Object { $_ -match 'GET /api/v1/servers\?page=1.*-> (\d+)' }) | Select-Object -Last 1
        Write-Info "stand-in master: $($req.Count) line(s); enroll: $(if ($enroll) { ($enroll -split ' ', 2)[1] } else { 'none yet' }); client catalog: $(if ($catalog) { ($catalog -split ' ', 2)[1] } else { 'none yet' })"
        foreach ($nf in @($req | Where-Object { $_ -match '-> 404' } | Select-Object -Unique -First 8)) { Write-Info "stand-in 404 (not needed so far): $(($nf -split ' ', 2)[1])" }
    }
    $verdict['5 server side'] = if ($step5) { 'pass' } else { 'fail' }

    Write-Host ''
    Write-Host 'Checklist (wiki/mods.md, "Verifying that a mod loaded"):' -ForegroundColor Cyan
    foreach ($k in $verdict.Keys) { Write-Host ("  {0,-18} {1}" -f $k, $verdict[$k]) }
    Write-Host '  4 in game          not covered by this script (drive to the car, apply the pack)'
    Complete-Phase "pwsh -File $PSCommandPath -Phase restore$WorkDirArg"
}

# ═══ restore ═══════════════════════════════════════════════════════════════════════════

function Invoke-Restore {
    $P = Get-Paths
    Write-Host 'prove-launcher-delivery: restore (strip removals by hash, then the launch footprint)'
    $launch = if (Test-Path -LiteralPath $P.LaunchState) { Read-Json $P.LaunchState } else { $null }
    $strip = if (Test-Path -LiteralPath $P.StripState) { Read-Json $P.StripState } else { $null }
    if (-not $launch -and -not $strip) { Stop-Phase "nothing to restore in $($P.Work)" 'pass the -WorkDir used by strip/launch' }
    # A proof launch that is still running holds the session and the projected files.
    Assert-GameClosed $(if ($strip -and -not ($launch -and $launch['Status'] -ne 'restored')) { $strip['GameDirectory'] })

    if ($launch -and $launch['Status'] -ne 'restored') {
        Write-Step '1. Isolated launcher and stand-in master'
        $exe = $launch['Exe']
        if ($launch['LauncherPid']) {
            $process = Get-Process -Id $launch['LauncherPid'] -ErrorAction SilentlyContinue
            if ($process -and $process.Path -eq $exe) {
                [void]$process.CloseMainWindow()
                if (-not $process.WaitForExit(15000)) {
                    if (-not $Force) { Stop-Phase "the isolated launcher (pid $($process.Id)) is still running" 'close its window (or its tray icon), or rerun restore with -Force to end it' }
                    Stop-Process -Id $process.Id -Force
                }
                Write-Ok "isolated launcher pid $($process.Id) closed"
            }
            else { Write-Ok 'isolated launcher already closed' }
        }
        $others = @(Get-Process -Name Open77Launcher -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
        if ($others.Count) { Stop-Phase "another instance of the proof launcher runs (pid $($others.Id -join ', '))" 'close it, then rerun restore' }
        if ($launch['MasterPid']) {
            New-Item -ItemType File -Force -Path (Join-Path $launch['RunDirectory'] 'master\stop') | Out-Null
            $master = Get-Process -Id $launch['MasterPid'] -ErrorAction SilentlyContinue
            if ($master -and -not $master.WaitForExit(8000)) {
                $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($master.Id)" -ErrorAction SilentlyContinue).CommandLine
                if ($commandLine -like '*serve-master*') { Stop-Process -Id $master.Id -Force }
            }
            Write-Ok 'stand-in master stopped'
        }
    }

    if ($strip -and $strip['Status'] -ne 'restored') {
        Write-Step '2. Game files strip removed'
        $game = $strip['GameDirectory']
        $origin = @{}
        if (Test-Path -LiteralPath $P.Prepare) { foreach ($pk in @((Read-Json $P.Prepare)['Packages'])) { $origin[$pk['Id']] = $pk['Zip'] } }
        foreach ($entry in @($strip['Files'] | Where-Object { $_['Present'] })) {
            $relative = $entry['Path']
            $full = ConvertTo-GamePath $game $relative
            $source = $entry['Backup']
            if (-not $source -or -not (Test-Path -LiteralPath $source) -or (Get-Sha256 $source) -ne $entry['Sha256']) {
                $source = $null
                $zip = $origin[$entry['Package']]
                if ($zip -and (Test-Path -LiteralPath $zip)) {
                    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
                    $candidate = Join-Path $P.Strip ("from-origin\" + ($relative -replace '/', '\'))
                    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
                    try {
                        $names = [string[]]@($archive.Entries | ForEach-Object { ConvertTo-ModPath $_.FullName })
                        $prefix = Get-ArchivePrefix $names
                        $zipEntry = @($archive.Entries | Where-Object { (ConvertTo-ModPath $_.FullName) -eq "$prefix$relative" })[0]
                        if ($zipEntry) {
                            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $candidate) | Out-Null
                            [IO.Compression.ZipFileExtensions]::ExtractToFile($zipEntry, $candidate, $true)
                            if ((Get-Sha256 $candidate) -eq $entry['Sha256']) { $source = $candidate; Write-Info "$relative comes from the origin zip (backup missing)" }
                        }
                    }
                    finally { $archive.Dispose() }
                }
            }
            if (-not $source) { Write-Fail "no copy of $relative with sha $(Get-Short $entry['Sha256'])" "restore it from the lab package $($entry['Package']) by hand"; continue }
            if (Test-Path -LiteralPath $full) {
                $current = Get-Sha256 $full
                if ($current -ne $entry['Sha256']) {
                    $displaced = Join-Path $P.Strip ("displaced\" + ($relative -replace '/', '\'))
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $displaced) | Out-Null
                    Move-Item -LiteralPath $full -Destination $displaced -Force
                    Write-Warn "$relative held other bytes ($(Get-Short $current)); moved to $displaced" ''
                }
                else { Remove-Item -LiteralPath $full -Force }
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            Copy-Item -LiteralPath $source -Destination $full -Force
            $item = Get-Item -LiteralPath $full -Force
            if ($entry['CreationUtcTicks']) { $item.CreationTimeUtc = [datetime]::new([long]$entry['CreationUtcTicks'], [DateTimeKind]::Utc) }
            if ($entry['LastWriteUtcTicks']) { $item.LastWriteTimeUtc = [datetime]::new([long]$entry['LastWriteUtcTicks'], [DateTimeKind]::Utc) }
            if ($null -ne $entry['Attributes']) { $item.Attributes = [IO.FileAttributes][int]$entry['Attributes'] }
            $sha = Get-Sha256 $full; $links = Get-LinkCount $full
            if ($sha -eq $entry['Sha256'] -and $links -eq 1) { Write-Ok "$relative  sha $(Get-Short $sha)  links=1" }
            else { Write-Fail "$relative restored as $(Get-Short $sha) links=$links" "copy $source to $full by hand" }
        }
        Write-Step '3. Script cache'
        foreach ($c in @($strip['ScriptCache'])) {
            $full = ConvertTo-GamePath $game $c['Path']
            if (-not (Test-Path -LiteralPath $full)) {
                Copy-Item -LiteralPath $c['Backup'] -Destination $full -Force
                Write-Ok "$($c['Path']) was missing (game not booted since the reset); put back from the strip snapshot"
            }
            elseif ((Get-Sha256 $full) -ne $c['Sha256']) { Write-Info "$($c['Path']) was regenerated by the game for the same script set; left as is (snapshot in $($c['Backup']))" }
            else { Write-Ok "$($c['Path']) unchanged" }
        }
        foreach ($g in @($strip['Guarded'])) {
            $full = ConvertTo-GamePath $game $g['Path']
            $now = if (Test-Path -LiteralPath $full) { Get-Sha256 $full } else { $null }
            if ($now -ne $g['Sha256']) { Write-Warn "$($g['Path']) is $(Get-Short $now), was $(Get-Short $g['Sha256']) at strip" 'not restored by this script: redeploy the lab client if it was replaced' }
        }
        if ($script:Failures -eq 0) { $strip['Status'] = 'restored'; $strip['RestoredUtc'] = [DateTimeOffset]::UtcNow.ToString('o'); Save-Json $P.StripState $strip }
    }
    elseif ($strip) { Write-Ok 'game files already restored' }

    if ($launch -and $launch['Status'] -ne 'restored') {
        Write-Step '4. Launch footprint under %LOCALAPPDATA%\Open77 and HKCU'
        $open = Get-OpenDirectory
        $sessionPath = Join-Path $open 'launcher-session-v1.dat'
        $session = $launch['Session']
        $currentAccount = if (Test-Path -LiteralPath $sessionPath) { Get-SessionAccountId $sessionPath } else { $null }
        if ($session['Existed']) {
            if ((Test-Path -LiteralPath $sessionPath) -and $currentAccount -ne $launch['AccountId']) {
                Write-Fail 'the session file is not the stand-in one any more' "someone signed in meanwhile; the player's original is still at $($session['Backup'])"
            }
            elseif (Test-Path -LiteralPath $session['Backup']) {
                Move-Item -LiteralPath $session['Backup'] -Destination $sessionPath -Force
                if ((Get-Sha256 $sessionPath) -eq $session['Sha256']) { Write-Ok "player session restored byte for byte ($(Get-Short $session['Sha256']))" }
                else { Write-Fail 'the restored session does not hash back' "the original was $($session['Sha256'])" }
            }
            elseif ((Test-Path -LiteralPath $sessionPath) -and (Get-Sha256 $sessionPath) -eq $session['Sha256']) { Write-Ok 'player session already restored' }
            else { Write-Fail "the moved-aside session is missing ($($session['Backup']))" 'the player signs in again in the launcher' }
        }
        elseif (Test-Path -LiteralPath $sessionPath) {
            if ($currentAccount -eq $launch['AccountId']) { Remove-Item -LiteralPath $sessionPath -Force; Write-Ok 'stand-in session removed (there was none before)' }
            else { Write-Warn 'a session file exists that is not the stand-in one; left in place' '' }
        }
        else { Write-Ok 'no session file, as before' }

        $webview = Join-Path $open "launcher-webview.$($launch['Instance'])"
        if (-not $launch['WebviewExisted'] -and (Test-Path -LiteralPath $webview)) {
            for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $webview); $i++) {
                try { Remove-Item -LiteralPath $webview -Recurse -Force } catch { Start-Sleep -Seconds 1 }
            }
            if (Test-Path -LiteralPath $webview) { Write-Fail "$webview is still in use" 'wait for msedgewebview2 to exit, then rerun restore' } else { Write-Ok "removed $webview" }
        }
        $identities = @(Get-ChildItem -LiteralPath $open -Filter "identity-$($launch['Instance'])-v1.dat*" -File -ErrorAction SilentlyContinue)
        if (-not $launch['IdentityExisted']) {
            foreach ($file in $identities) { Remove-Item -LiteralPath $file.FullName -Force; Write-Ok "removed $($file.Name) (stand-in enrollment)" }
        }
        $log = $launch['LauncherLog']
        if (Test-Path -LiteralPath $log['Path']) {
            $bytes = Read-SharedBytes $log['Path']
            $prefixOk = $bytes.LongLength -ge $log['Length'] -and ($log['Length'] -eq 0 -or
                (Get-PrefixSha256 $bytes $log['Length']) -eq $log['PrefixSha256'])
            if ($prefixOk -and $bytes.LongLength -gt $log['Length']) {
                $tail = Join-Path $launch['RunDirectory'] 'launcher.log.proof-tail.txt'
                $out = [IO.File]::Create($tail)
                try { $out.Write($bytes, [int]$log['Length'], $bytes.Length - [int]$log['Length']) } finally { $out.Dispose() }
                $stream = [IO.File]::Open($log['Path'], [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $stream.SetLength($log['Length']) } finally { $stream.Dispose() }
                Write-Ok "launcher.log truncated back to $($log['Length']) byte(s); the run's lines are kept in $tail"
            }
            elseif ($prefixOk) { Write-Ok 'launcher.log unchanged' }
            else { Write-Warn 'launcher.log rotated or was rewritten during the run; left as is' 'the proof lines stay in it (and launcher.previous.log)' }
        }
        Write-Ok "open77:// handler $(Restore-Scheme $launch['Scheme'])"

        $known = @{}; foreach ($i in @($launch['OpenListing'])) { $known[$i['Name']] = $i }
        foreach ($item in @(Get-ChildItem -LiteralPath $open -Force)) {
            if (-not $known.ContainsKey($item.Name)) { Write-Warn "new item in $($open): $($item.Name)" 'created during the run (incident/diagnostics folders are the usual ones); not removed automatically' }
        }
        foreach ($t in @($launch['Templates'])) {
            if (-not (Test-Path -LiteralPath $t['Path']) -or (Get-Sha256 $t['Path']) -ne $t['Sha256']) { Write-Info "template save changed: $($t['Path']) (the launcher and the client both place NCMP-Template-* saves; left as is)" }
        }
        if ($script:Failures -eq 0) { $launch['Status'] = 'restored'; $launch['RestoredUtc'] = [DateTimeOffset]::UtcNow.ToString('o'); Save-Json $P.LaunchState $launch }
        Write-Info "the isolated store and settings stay in $($launch['RunDirectory']) for later reading; delete the work folder when done"
    }
    elseif ($launch) { Write-Ok 'launch footprint already restored' }
    Complete-Phase ''
}

# ═══ selftest ══════════════════════════════════════════════════════════════════════════

function Invoke-SelfTest {
    $P = Get-Paths
    $dir = Join-Path $P.Work 'selftest'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-Host 'prove-launcher-delivery: selftest (nothing outside the work folder, no socket opened)'
    Initialize-Native

    Write-Step 'stand-in master request handling (in memory)'
    function Invoke-Raw([byte[]] $Raw) {
        $in = [IO.MemoryStream]::new($Raw); $out = [IO.MemoryStream]::new()
        [VcProof.StandinMaster]::Handle($in, $out)
        $bytes = $out.ToArray()
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        $split = $text.IndexOf("`r`n`r`n")
        [pscustomobject]@{ Status = [int]($text.Split(' ')[1]); Head = $text.Substring(0, $split); Body = [byte[]]$bytes[($split + 4)..($bytes.Length - 1)] }
    }
    [VcProof.StandinMaster]::LogPath = (Join-Path $dir 'requests.log')
    $r = Invoke-Raw ([Text.Encoding]::ASCII.GetBytes("GET /healthz?clock=abc HTTP/1.1`r`nHost: x`r`n`r`n"))
    if ($r.Status -eq 200 -and $r.Head -match 'Date: ' -and $r.Head -match $StandinHeader) { Write-Ok 'GET /healthz -> 200 with Date and the stand-in header' } else { Write-Fail "healthz -> $($r.Status)" '' }
    $chunked = "POST /api/v1/mods/attest HTTP/1.1`r`nTransfer-Encoding: chunked`r`n`r`n7`r`n{`"sha25`r`n6`r`n6`":[]}`r`n0`r`n`r`n"
    $r = Invoke-Raw ([Text.Encoding]::ASCII.GetBytes($chunked))
    if ($r.Status -eq 200 -and [Text.Encoding]::UTF8.GetString($r.Body) -eq '{"results":[]}') { Write-Ok 'POST /api/v1/mods/attest (chunked body) -> {"results":[]}' } else { Write-Fail "attest -> $($r.Status)" '' }
    $r = Invoke-Raw ([Text.Encoding]::ASCII.GetBytes("POST /x HTTP/1.1`r`nTransfer-Encoding: chunked`r`n`r`nzz`r`n"))
    if ($r.Status -eq 400) { Write-Ok 'a malformed chunked body -> 400, the listener survives' } else { Write-Fail "malformed body -> $($r.Status)" '' }
    $r = Invoke-Raw ([Text.Encoding]::ASCII.GetBytes("GET /api/v1/servers?page=1&pageSize=100&gameBuild=25000&protocolMajor=1 HTTP/1.1`r`n`r`n"))
    if ($r.Status -eq 200 -and ([Text.Encoding]::UTF8.GetString($r.Body) | ConvertFrom-Json).total -eq 0) { Write-Ok 'GET /api/v1/servers -> empty page' } else { Write-Fail "servers -> $($r.Status)" '' }
    $name = [Text.Encoding]::UTF8.GetBytes($PlayerName)
    $userId = [byte[]](1..16)
    $body = [Collections.Generic.List[byte]]::new()
    $body.AddRange([Text.Encoding]::ASCII.GetBytes('CYIDENR1')); $body.AddRange($userId); $body.AddRange([byte[]]::new(64)); $body.AddRange([byte[]]::new(16))
    $body.AddRange([byte[]]::new(8)); $body.Add([byte]($name.Length -shr 8)); $body.Add([byte]($name.Length -band 0xFF)); $body.AddRange($name); $body.AddRange([byte[]]::new(64))
    $head = [Text.Encoding]::ASCII.GetBytes("POST /api/v1/identities/enroll HTTP/1.1`r`nContent-Length: $($body.Count)`r`nContent-Type: application/octet-stream`r`n`r`n")
    $r = Invoke-Raw ([byte[]]($head + $body.ToArray()))
    $reply = $r.Body
    $replyName = if ($reply.Length -ge 122) { [Text.Encoding]::UTF8.GetString($reply, 122, $reply.Length - 122) } else { '' }
    $sameUser = $reply.Length -ge 24 -and [Linq.Enumerable]::SequenceEqual([byte[]]$reply[8..23], $userId)
    if ($r.Status -eq 200 -and [Text.Encoding]::ASCII.GetString($reply, 0, 8) -eq 'CYIDACK1' -and $sameUser -and
        ($reply[120] * 256 + $reply[121]) -eq $name.Length -and $replyName -eq $PlayerName) {
        Write-Ok "POST /api/v1/identities/enroll -> CYIDACK1, user id echoed, name '$replyName', $($reply.Length) bytes"
    }
    else { Write-Fail "enroll -> $($r.Status), $($reply.Length) bytes" '' }
    $r = Invoke-Raw ([Text.Encoding]::ASCII.GetBytes("POST /api/v1/servers/00000000-0000-0000-0000-000000000000/ticket HTTP/1.1`r`nContent-Length: 0`r`n`r`n"))
    if ($r.Status -eq 404) { Write-Ok 'connect ticket -> 404 (non-fatal for the client; the lab requires none)' } else { Write-Fail "ticket -> $($r.Status)" '' }
    $logText = Get-Content -LiteralPath (Join-Path $dir 'requests.log') -Raw
    if ($logText -notmatch 'Bearer|Authorization|sessionToken') { Write-Ok 'request log carries no header and no body' } else { Write-Fail 'request log leaks a header' '' }

    Write-Step 'seeded launcher session (DPAPI round trip, inside the work folder)'
    $path = Join-Path $dir 'launcher-session-v1.dat'
    $account = [guid]::NewGuid().ToString()
    Write-SeededSession $path $account $PlayerName ('0' * 64)
    Initialize-ProtectedData
    $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), $SessionEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $session = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json -AsHashtable
    $keys = @($session.Keys) -join ','
    if ((Get-SessionAccountId $path) -eq $account -and $session['sessionToken'].Length -eq 43 -and $session['sessionToken'] -cmatch '^[A-Za-z0-9_-]{43}$' -and
        $keys -eq 'accountId,displayName,sessionToken,expiresAtUtc,gameBuildSha256') {
        Write-Ok "session decrypts with the launcher entropy: $keys; token is 43 base64url characters"
    }
    else { Write-Fail "session round trip: keys $keys" '' }
    Remove-Item -LiteralPath $path -Force

    Write-Step 'file-in-use probe (Restart Manager, read-only)'
    $probe = Join-Path $dir 'held.bin'
    [IO.File]::WriteAllBytes($probe, [byte[]](1, 2, 3))
    $free = @([VcProof.FileHolders]::Holders($probe))
    $handle = [IO.File]::Open($probe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $held = @([VcProof.FileHolders]::Holders($probe)) } finally { $handle.Dispose() }
    if ($free.Count -eq 0 -and $held -contains $PID) { Write-Ok "a closed file has no holder; an open one reports this process ($PID)" }
    else { Write-Warn "probe: closed=$($free -join ',') open=$($held -join ',') (this process is $PID)" 'the .archive evidence of verify step 3 is then unavailable on this machine' }
    Remove-Item -LiteralPath $probe -Force

    Write-Step 'mirrors of the launcher rules'
    $prefixCases = @(
        @{ In = @('archive/pc/mod/a.archive', 'r6/tweaks/x.yaml'); Want = '' },
        @{ In = @('Wrap/archive/pc/mod/a.archive', 'Wrap/r6/tweaks/x.yaml'); Want = 'Wrap/' },
        @{ In = @('Wrap/readme.txt', 'Wrap/archive/pc/mod/a.archive'); Want = '' })
    $prefixOk = $true
    foreach ($case in $prefixCases) { if ((Get-ArchivePrefix ([string[]]$case.In)) -ne $case.Want) { $prefixOk = $false } }
    if ($prefixOk) { Write-Ok 'ArchivePrefix mirror: plain, wrapped and mixed layouts' } else { Write-Fail 'ArchivePrefix mirror disagrees with ModRootPolicy' '' }
    $mods = @(@{ id = 'b'; version = '1.0'; sha256 = ('b' * 64) }, @{ id = 'a'; version = '2.0'; sha256 = ('a' * 64) })
    $expected = Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes("a$([char]0x1f)2.0$([char]0x1f)$('a' * 64)`nb$([char]0x1f)1.0$([char]0x1f)$('b' * 64)`n"))
    if ((Get-ManifestDigest $mods) -eq $expected) { Write-Ok 'manifest digest mirror: ordinal id order, unit separators, trailing newline' } else { Write-Fail 'digest mirror' '' }
    Complete-Phase ''
}

switch ($Phase) {
    'prepare' { Invoke-Prepare }
    'strip' { Invoke-Strip }
    'launch' { Invoke-Launch }
    'verify' { Invoke-Verify }
    'restore' { Invoke-Restore }
    'selftest' { Invoke-SelfTest }
    'serve-master' { Invoke-ServeMaster }
}
