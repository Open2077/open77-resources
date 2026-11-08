#requires -Version 7.0
<#
.SYNOPSIS
    Builds the Light RP vehicle sticker pack (wave 2, W2.4), end to end: TweakXL YAML + .archive +
    preload_mod ZIP + draft resource, from specs/lightrp-stickers.json.

.DESCRIPTION
    A sticker is a look the game's artists already composed: the sticker components one vanilla
    appearance of a dealer model shows. The pack carries OUR wrappers only: one decal entity per
    sticker component (lv_cook.decal_entity, the E3 livery decal), whose mesh component points at
    the VANILLA sticker mesh by depot path with the vanilla meshAppearance, chunkMask and local
    transform. No game file is copied into the archive or the repository.

    Steps: dealer .app files (read-only, cached) -> survey (st_survey.py; compared with the
    committed data/stickers-dealer-2.50.json, -UpdateData rewrites it) -> plan + checks + negative
    tests (st_plan.py) -> the planned vanilla sticker meshes (read-only, cached: appearance and
    chunk checks) -> revision -> cook (st_cook.py) -> deserialize, round trip -> pack, pin
    timestamps, byte check -> ZIP (archive + YAML) -> draft resource -> manifest.

    Never writes in the game folder, never launches the game, never deploys. The output folder
    must be git-ignored: the work tree holds extracted game files.
    Same spec + scripts + tools + game build = same revision and the same bytes.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/stickers/build-stickers.ps1
    pwsh -File scripts/vehicle-kit/stickers/build-stickers.ps1 -UpdateData
#>
[CmdletBinding()]
param(
    [string] $Spec = (Join-Path $PSScriptRoot 'specs/lightrp-stickers.json'),
    [string] $OutDir,
    [string] $GameDirectory,
    [string] $WolvenKitCli,
    [string] $Uv,
    # Rewrite data/stickers-dealer-2.50.json from this game install instead of failing on a difference.
    [switch] $UpdateData,
    [string] $ResourceVersion = '0.1.0',
    # Same TweakXL floor as the stage and livery packs (E0.8 proved 1.12.0 on this build).
    [string] $TweakXlMin = '1.12.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here = $PSScriptRoot
$kitRoot = [IO.Path]::GetFullPath((Join-Path $here '..'))
$repo = [IO.Path]::GetFullPath((Join-Path $here '../../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')
$YamlName = 'open77-lightrp-stickers.yaml'
$ZipYaml = "r6/tweaks/LightRP/$YamlName"
$MaxZipBytes = 64MB          # Warden upload ceiling (same as build-pack.ps1)
$DataPath = Join-Path $here 'data/stickers-dealer-2.50.json'

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail([string] $text) { throw "vehicle-stickers: $text" }
function Sha256([string] $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Flat([string] $depot) { $depot.Replace('\', '~') }

function Get-EnvBothScopes([string] $name)
{
    foreach ($scope in 'Process', 'User') {
        $v = [Environment]::GetEnvironmentVariable($name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $null
}

function Reset-Dir([string] $path)
{
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($script:OutRoot + [IO.Path]::DirectorySeparatorChar)) { Fail "refusing to clear $full (outside $script:OutRoot)" }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $full | Out-Null
    return $full
}

function Write-Utf8NoBom([string] $path, [string] $text)
{
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $text = $text -replace "`r`n", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

function Invoke-Tool([string] $label, [string] $exe, [string[]] $arguments, [string] $marker, [int[]] $okCodes = @(0))
{
    $output = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    if ($okCodes -contains $code) { $code = 0 }
    $errors = @($output | Where-Object { $_ -match '\[\s*\d+:\s*Error\s*\]|^Traceback|^st_[a-z]+: |^lv_[a-z]+: ' })
    foreach ($line in $output) {
        if ($line -match '^(ST_|VK_)|\[\s*\d+:\s*(Error|Warning)\s*\]|^Traceback|^\s+File "|^st_[a-z]+: |^lv_[a-z]+: ') { Write-Host "   $line" }
    }
    if ($code -ne 0 -or $errors.Count -gt 0 -or ($marker -and -not ($output -match [regex]::Escape($marker)))) {
        $tail = ($output | Select-Object -Last 25) -join "`n"
        Fail "$label failed (exit $code).`n$tail"
    }
    return $output
}

function Wk([string] $label, [string[]] $arguments) { Invoke-Tool "WolvenKit $label" $script:Cli $arguments $null }
function Py([string] $label, [string] $script, [string[]] $arguments, [string] $marker)
{
    Invoke-Tool $label $script:UvExe (@('run', '--no-project', 'python', '-I', (Join-Path $here $script)) + $arguments) $marker
}

# One alternation per call, kept short enough for the command line.
function Get-DepotRegexes([string[]] $paths, [int] $limit = 7000)
{
    $out = @(); $cur = @()
    foreach ($p in ($paths | Sort-Object -Unique)) {
        $e = '^' + [regex]::Escape($p) + '$'
        if ($cur.Count -and (($cur -join '|').Length + $e.Length) -gt $limit) { $out += ($cur -join '|'); $cur = @() }
        $cur += $e
    }
    if ($cur.Count) { $out += ($cur -join '|') }
    return $out
}

# Extracts the missing depot paths into game/raw (read-only on the game), serializes the missing
# ones into $jsonDir under flat names.
function Sync-GameFiles([string[]] $paths, [string] $jsonDir)
{
    $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $gameRaw $_)) })
    if ($missing.Count) {
        New-Item -ItemType Directory -Force -Path $gameRaw | Out-Null
        # ep1 paths live in archive\pc\ep1, the rest in archive\pc\content.
        foreach ($pair in @(@('archive\pc\content', @($missing | Where-Object { -not $_.StartsWith('ep1\') })),
                            @('archive\pc\ep1', @($missing | Where-Object { $_.StartsWith('ep1\') })))) {
            $src = Join-Path $GameDirectory $pair[0]
            if (-not $pair[1].Count -or -not (Test-Path -LiteralPath $src)) { continue }
            foreach ($rx in (Get-DepotRegexes $pair[1])) {
                Wk "extract from $($pair[0])" @('extract', $src, '--regex', $rx, '--outpath', $gameRaw, '--gamepath', $GameDirectory) | Out-Null
            }
        }
        $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $gameRaw $_)) })
        if ($missing.Count) { Fail "not found in the game archives: $($missing -join ', ')" }
    }
    $needJson = @($paths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $jsonDir ((Flat $_) + '.json'))) })
    if ($needJson.Count) {
        $null = Reset-Dir $gameFlat
        foreach ($p in $needJson) { Copy-Item -LiteralPath (Join-Path $gameRaw $p) -Destination (Join-Path $gameFlat (Flat $p)) }
        New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null
        Wk "serialize $($needJson.Count) game files" @('convert', 'serialize', $gameFlat, '--outpath', $jsonDir) | Out-Null
    }
}

# --------------------------------------------------------------------------- 0. inputs
Step 'Resolving inputs and tools'
$SpecPath = (Resolve-Path -LiteralPath $Spec).Path
$st = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json -AsHashtable
if ($st.schema -ne 'open77.vehicle-stickers/1') { Fail "spec schema must be open77.vehicle-stickers/1 ($SpecPath)" }
if ($st.resource -notmatch '^[a-z0-9_-]{1,64}$') { Fail "resource '$($st.resource)' must match [a-z0-9_-]{1,64}" }
if ($st.archiveName -notmatch '^[A-Za-z0-9_]{3,64}$' -or $st.archiveName -match '^Open77(Mirror|RP)?$') { Fail "archiveName '$($st.archiveName)' is invalid or collides with a platform archive" }
if (-not $GameDirectory) { $GameDirectory = Get-EnvBothScopes 'OP77_GAME_DIR' }
if (-not $GameDirectory -or -not (Test-Path -LiteralPath (Join-Path $GameDirectory 'r6\cache\tweakdb.bin'))) {
    Fail "game directory not found (got '$GameDirectory'). Pass -GameDirectory or set OP77_GAME_DIR; it is only read."
}
$GameDirectory = (Resolve-Path -LiteralPath $GameDirectory).Path
$script:Cli = Find-WolvenKitCli -Explicit $WolvenKitCli
$wkVersion = ((& $script:Cli --version) 2>&1 | Select-Object -First 1).ToString().Trim()
$wkNumeric = ([regex]::Match($wkVersion, '\d+\.\d+\.\d+')).Value
if (-not $wkNumeric) { Fail "could not read the WolvenKit version ($wkVersion)" }
$script:UvExe = if ($Uv) { $Uv } else { (Get-Command uv -ErrorAction SilentlyContinue)?.Source }
if (-not $script:UvExe) { Fail 'uv not found (pass -Uv <uv.exe>): it runs the Python steps in an isolated environment' }
$node = (Get-Command node -ErrorAction SilentlyContinue)?.Source
if (-not $node) { Fail 'node (Node.js 18+) not found on PATH (archive timestamp normalization)' }

if (-not $OutDir) { $OutDir = Join-Path $repo 'artifacts/vehicle-kit/stickers' }
$script:OutRoot = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $script:OutRoot | Out-Null
if ($script:OutRoot.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    & git -C $repo check-ignore -q -- (Join-Path $script:OutRoot 'probe.archive')
    if ($LASTEXITCODE -ne 0) { Fail "output folder $script:OutRoot is inside the repository but not git-ignored" }
}
$work = Join-Path $script:OutRoot 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$gameRaw = Join-Path $work 'game/raw'
$gameFlat = Join-Path $work 'game/flat'
$appJson = Join-Path $work 'game/json'
$meshJson = Join-Path $work 'game/mesh-json'
Write-Host "   WolvenKit $wkVersion  uv $script:UvExe  game $GameDirectory"

# --------------------------------------------------------------------------- 1. survey
Step 'Dealer .app files (read-only, cached) and sticker survey'
$apps = @(Invoke-Tool 'list apps' $script:UvExe @('run', '--no-project', 'python', '-I', (Join-Path $here 'st_survey.py'), '--list-apps') $null |
    Where-Object { $_ -match '\.app$' })
if (-not $apps.Count) { Fail 'st_survey.py --list-apps listed no .app file' }
Sync-GameFiles $apps $appJson
$surveyPath = Join-Path $work 'survey.json'
Py 'survey' 'st_survey.py' @('--json-dir', $appJson, '--out', $surveyPath) 'ST_SURVEY_OK' | Out-Null
if ($UpdateData) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DataPath) | Out-Null
    Copy-Item -LiteralPath $surveyPath -Destination $DataPath -Force
    Write-Host "   data/stickers-dealer-2.50.json rewritten from this game install"
} elseif (-not (Test-Path -LiteralPath $DataPath)) {
    Fail "no committed data/stickers-dealer-2.50.json: run once with -UpdateData"
} elseif (((Get-Content -LiteralPath $surveyPath -Raw) -replace "`r`n", "`n") -cne ((Get-Content -LiteralPath $DataPath -Raw) -replace "`r`n", "`n")) {
    Fail "the survey of this game install differs from data/stickers-dealer-2.50.json (game update?): review, then rerun with -UpdateData"
}

# --------------------------------------------------------------------------- 2. plan
Step 'Plan, checks and negative tests'
$planPath = Join-Path $work 'plan.json'
Py 'plan' 'st_plan.py' @('--survey', $DataPath, '--spec', $SpecPath, '--out', $planPath) 'ST_PLAN_OK' | Out-Null
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -AsHashtable
$meshDepots = @($plan.models | ForEach-Object { $_.decals | ForEach-Object { $_.mesh } } | Sort-Object -Unique)

Step "The $($meshDepots.Count) planned vanilla sticker meshes (read-only, cached, never shipped)"
Sync-GameFiles $meshDepots $meshJson

# --------------------------------------------------------------------------- 3. revision
$hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
$add = { param($text) $hasher.AppendData([Text.Encoding]::UTF8.GetBytes([string] $text + "`n")) }
& $add ((Get-Content -LiteralPath $SpecPath -Raw) -replace "`r`n", "`n")
& $add ((Get-Content -LiteralPath $DataPath -Raw) -replace "`r`n", "`n")
$sources = @(Get-ChildItem -LiteralPath $here -Filter 'st_*.py' -File) + @(Get-ChildItem -LiteralPath (Join-Path $here 'lua') -Filter '*.lua' -File) +
    @(Get-Item -LiteralPath (Join-Path $kitRoot 'liveries/lv_cook.py')) + @(Get-Item -LiteralPath (Join-Path $kitRoot 'liveries/lv_common.py')) + @(Get-Item -LiteralPath $PSCommandPath)
foreach ($f in ($sources | Sort-Object Name)) {
    & $add $f.Name; & $add ((Get-Content -LiteralPath $f.FullName -Raw) -replace "`r`n", "`n")
}
foreach ($p in $meshDepots) { & $add "$p $(Sha256 (Join-Path $gameRaw $p))" }
& $add "$wkVersion|tweakxl>=$TweakXlMin"
$revision = ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
$rev12 = $revision.Substring(0, 12)
$prefix = "open77\assets\$($st.resource)\$rev12"
Write-Host "   revision $revision  ->  $prefix"

# --------------------------------------------------------------------------- 4. cook
Step 'Cook (decal entities, YAML, Lua catalogue)'
$cook = [ordered]@{
    plan = $planPath; prefix = $prefix; resource = $st.resource; revision = $revision; wolvenkit = $wkNumeric
    meshJsonDir = $meshJson
    preparedDir = (Join-Path $work 'prepared'); roundtripDir = (Join-Path $work 'roundtrip')
    yamlOut = (Join-Path $work $YamlName); luaOut = (Join-Path $work 'stickers.lua')
    catalogueOut = (Join-Path $work 'catalogue.json'); packageOut = (Join-Path $work 'package.json')
}
$cookPath = Join-Path $work 'cook.json'
Write-Utf8NoBom $cookPath ($cook | ConvertTo-Json -Depth 8)
$null = Reset-Dir $cook.preparedDir
Py 'cook prepare' 'st_cook.py' @('prepare', $cookPath) 'ST_COOK_PREPARED' | Out-Null
$deser = Reset-Dir (Join-Path $work 'deserialized')
Wk 'deserialize' @('convert', 'deserialize', $cook.preparedDir, '--outpath', $deser) | Out-Null
$null = Reset-Dir $cook.roundtripDir
Wk 'round trip serialize' @('convert', 'serialize', $deser, '--outpath', $cook.roundtripDir) | Out-Null
Py 'cook validate' 'st_cook.py' @('validate', $cookPath) 'ST_COOK_ROUNDTRIP_OK' | Out-Null
$package = Get-Content -LiteralPath $cook.packageOut -Raw | ConvertFrom-Json -AsHashtable

$stage = Reset-Dir (Join-Path $work 'stage')
$expected = @()
foreach ($f in $package.files) {
    $src = Join-Path $deser (Flat $f)
    if (-not (Test-Path -LiteralPath $src)) { Fail "deserialize produced no $f" }
    $dst = Join-Path $stage $f
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst
    $expected += $f
}
$expected = @($expected | Sort-Object)

# --------------------------------------------------------------------------- 5. archive
Step 'Pack and verify the archive'
$packedDir = Reset-Dir (Join-Path $work 'packed')
Wk 'pack' @('pack', $stage, '--outpath', $packedDir) | Out-Null
$packed = Join-Path $packedDir 'stage.archive'
if (-not (Test-Path -LiteralPath $packed)) { Fail "pack produced no $packed" }
$archive = Join-Path $packedDir "$($st.archiveName).archive"
Move-Item -LiteralPath $packed -Destination $archive -Force
Invoke-Tool 'normalize archive' $node @((Join-Path $kitRoot 'native/normalize-archive.cjs'), $archive) 'VK_ARCHIVE_NORMALIZED' | Out-Null
$listing = Wk 'list archive' @('archive', $archive, '--list')
$entries = @($listing | Where-Object { $_ -match '^[A-Za-z0-9_]+\\' } | ForEach-Object { $_.Trim() } | Sort-Object)
if (Compare-Object $entries $expected) { Fail "archive entries differ from the staged files:`n$(Compare-Object $entries $expected | Out-String)" }
$foreign = @($entries | Where-Object { -not $_.StartsWith("$prefix\") })
if ($foreign.Count) { Fail "archive carries paths outside ${prefix}: $($foreign -join ', ')" }
$verifyDir = Reset-Dir (Join-Path $work 'verify')
Wk 'extract for byte check' @('extract', $archive, '--outpath', $verifyDir) | Out-Null
foreach ($rel in $expected) {
    $b = Join-Path $verifyDir $rel
    if (-not (Test-Path -LiteralPath $b) -or (Sha256 $b) -ne (Sha256 (Join-Path $stage $rel))) { Fail "archive changed or lost $rel" }
}
Write-Host "   $($entries.Count) entries, all under $prefix, bytes identical after extraction"

# --------------------------------------------------------------------------- 6. ZIP
Step 'preload_mod ZIP (archive + TweakXL YAML)'
$resourceDir = Reset-Dir (Join-Path $script:OutRoot "resource/$($st.resource)")
$zipName = "$($st.archiveName)_$rev12.zip"
$zipPath = Join-Path $resourceDir "dist/$zipName"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zipPath) | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipArchive = "archive/pc/mod/$($st.archiveName).archive"
$parts = [ordered]@{ $zipArchive = $archive; $ZipYaml = $cook.yamlOut }
$fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
try {
    $zip = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($name in $parts.Keys) {
        $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $dst = $entry.Open(); $src = [IO.File]::OpenRead($parts[$name])
        try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
    }
    $zip.Dispose()
} finally { $fs.Dispose() }
$zipBytes = (Get-Item -LiteralPath $zipPath).Length
if ($zipBytes -gt $MaxZipBytes) { Fail "$zipName is $zipBytes bytes, over the $MaxZipBytes-byte ceiling" }
$checkDir = Reset-Dir (Join-Path $work 'zip-check')
$z = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $zipEntries = @($z.Entries | ForEach-Object { $_.FullName })
    if (Compare-Object $zipEntries @($parts.Keys)) { Fail "ZIP layout is wrong: $($zipEntries -join ', ')" }
    foreach ($e in $z.Entries) {
        $out = Join-Path $checkDir ($e.FullName.Replace('/', '_'))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out)
        if ((Sha256 $out) -ne (Sha256 $parts[$e.FullName])) { Fail "ZIP entry $($e.FullName) differs from its source" }
    }
} finally { $z.Dispose() }
Write-Host "   $zipName  $zipBytes bytes  entries: $($zipEntries -join ', ')"

# --------------------------------------------------------------------------- 7. resource
Step 'Draft Light RP resource'
New-Item -ItemType Directory -Force -Path (Join-Path $resourceDir 'server') | Out-Null
Copy-Item -LiteralPath $cook.luaOut -Destination (Join-Path $resourceDir 'server/stickers.lua')
Copy-Item -LiteralPath $cook.catalogueOut -Destination (Join-Path $resourceDir 'catalogue.json')
Write-Utf8NoBom (Join-Path $resourceDir 'open77.lua') (@'
-- Light RP vehicle stickers (DRAFT). Ships the TweakXL records Vehicle.o77_st_* (one decal: our
-- .ent wrapping a vanilla sticker mesh) and Vehicle.o77_sticker_* (one sticker: its decal list),
-- with the decal entities, as one inert preload_mod: the launcher projects it before the game
-- starts and TweakXL creates the records at boot. Needs the TweakXL loader resource in
-- resources.load, and the wave-2 natives (registerStickers, setStickers) to be applied.
-- Generated by scripts/vehicle-kit/stickers/build-stickers.ps1 (revision @@REV@@). Edit the
-- spec, not this file.
resource '@@RESOURCE@@'
version '@@VERSION@@'
auto_start true
dependency 'tweakxl >=@@TWEAKXL@@'
preload_mod 'dist/@@ZIP@@'
server_script 'server/stickers.lua'
server_script 'server/main.lua'
-- world.vehicles + world.vehicles.appearance: registerStickers / setStickers for the lab command.
permissions { 'world.vehicles', 'world.vehicles.appearance' }
'@).Replace('@@REV@@', $rev12).Replace('@@RESOURCE@@', $st.resource).Replace('@@VERSION@@', $ResourceVersion).Replace('@@TWEAKXL@@', $TweakXlMin).Replace('@@ZIP@@', $zipName)
Write-Utf8NoBom (Join-Path $resourceDir 'server/main.lua') ((Get-Content -LiteralPath (Join-Path $here 'lua/stickers_main.lua') -Raw).Replace('@@RESOURCE@@', $st.resource))

# --------------------------------------------------------------------------- 8. manifest
Step 'Manifest'
$yamlCopy = Join-Path $script:OutRoot $YamlName
Copy-Item -LiteralPath $cook.yamlOut -Destination $yamlCopy -Force
$manifest = [ordered]@{
    schema = 'open77.vehicle-stickers.build/1'
    revision = $revision; depotPrefix = $prefix
    tools = [ordered]@{ wolvenkit = $wkVersion; node = (& $node --version); tweakxlMin = $TweakXlMin }
    referencedNotShipped = [ordered]@{ meshes = $package.referencedMeshes }
    plan = [ordered]@{ totals = $plan.totals; refused = $plan.refused; limits = $plan.limits }
    yaml = [ordered]@{ name = $YamlName; sha256 = (Sha256 $yamlCopy); bytes = (Get-Item -LiteralPath $yamlCopy).Length;
                       decalRecords = $package.decalRecords.Count; stickerRecords = $package.stickerRecords.Count }
    zip = [ordered]@{ name = $zipName; sha256 = (Sha256 $zipPath); bytes = $zipBytes; entries = $zipEntries }
    archive = [ordered]@{ name = "$($st.archiveName).archive"; sha256 = (Sha256 $archive); bytes = (Get-Item -LiteralPath $archive).Length; entries = $entries.Count }
    deployed = $false
}
Copy-Item -LiteralPath $planPath -Destination (Join-Path $script:OutRoot 'plan.json') -Force
Write-Utf8NoBom (Join-Path $script:OutRoot 'manifest.json') ($manifest | ConvertTo-Json -Depth 16)
$sumFiles = @($zipPath, $archive, $yamlCopy, (Join-Path $resourceDir 'open77.lua'), (Join-Path $resourceDir 'server/main.lua'),
    (Join-Path $resourceDir 'server/stickers.lua'), (Join-Path $resourceDir 'catalogue.json'))
$sums = foreach ($f in $sumFiles) { "{0}  {1}" -f (Sha256 $f), [IO.Path]::GetRelativePath($script:OutRoot, $f).Replace('\', '/') }
Write-Utf8NoBom (Join-Path $script:OutRoot 'SHA256SUMS') (($sums -join "`n") + "`n")

Step 'Done'
Write-Host "   resource  $resourceDir"
Write-Host "   zip       $zipPath ($zipBytes bytes)"
Write-Host "   yaml      $yamlCopy"
Write-Host "VK_STICKERS_OK revision=$rev12 stickers=$($package.stickerRecords.Count) decals=$($package.decalRecords.Count) files=$($entries.Count) zip=$zipBytes (not deployed)"
