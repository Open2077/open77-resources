#requires -Version 7.0
<#
.SYNOPSIS
    Builds the Light RP performance-stage and engine-sound pack: TweakXL YAMLs -> preload_mod ZIP -> draft resource.

.DESCRIPTION
    Runs make_stages.py (offline: reads tweakdb.bin of the installed game, never writes to the
    game folder), packs the generated YAMLs as r6/tweaks/LightRP/open77-lightrp-stages.yaml and
    r6/tweaks/LightRP/open77-lightrp-engine-sounds.yaml (wave 2, W2.3) in a deterministic ZIP,
    writes a draft Light RP resource around it (manifest with preload_mod and the TweakXL
    dependency, server-side tables of the stage and sound records, the call that registers the
    engine-sound catalogue), re-checks the YAML bytes taken back out of the ZIP, and prints
    VK_STAGES_OK with the ZIP sha256.

    -SkipEngineSounds builds the stage pack alone: the same ZIP bytes and revision (the stage
    YAML's sha256 prefix) as the pre-wave-2 build.

    Never launches the game, never deploys, never copies anything into r6/tweaks: installing the
    YAML in a lab or shipping the resource is a separate, deliberate step.

    The output folder must be git-ignored (default artifacts/vehicle-kit/stages).

.EXAMPLE
    pwsh -File scripts/vehicle-kit/stages/build-stages.ps1
    pwsh -File scripts/vehicle-kit/stages/build-stages.ps1 -GameDirectory 'D:\Games\Cyberpunk 2077' -OutDir D:\out\stages
    pwsh -File scripts/vehicle-kit/stages/build-stages.ps1 -SkipEngineSounds
#>
[CmdletBinding()]
param(
    [string] $GameDirectory,
    [string] $OutDir,
    [string] $Uv,
    [string] $ResourceName = 'lightrp_vehicle_stages',
    [string] $ResourceVersion = '0.1.0',
    # TweakXL 1.12.0 is the version proven on this game build (E0.8); the repository's loader
    # resource (resources/assets/loaders/tweakxl) ships it since 2026-11-05.
    [string] $TweakXlMin = '1.12.0',
    [switch] $SkipEngineSounds
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$stagesRoot = $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $stagesRoot '../../..'))
$generator = Join-Path $stagesRoot 'make_stages.py'
$ZipEntry = 'r6/tweaks/LightRP/open77-lightrp-stages.yaml'
$SoundsZipEntry = 'r6/tweaks/LightRP/open77-lightrp-engine-sounds.yaml'
$ArchiveName = 'LightRPVehicleStages'
$withSounds = -not $SkipEngineSounds

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail([string] $text) { throw "vehicle-stages: $text" }
function Sha256([string] $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }

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

function Invoke-Generator([string] $label, [string[]] $arguments, [string] $marker)
{
    $output = & $script:UvExe run --no-project python -I $generator --game $GameDirectory @arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Host "   $line" }
    if ($code -ne 0 -or -not ($output -match [regex]::Escape($marker))) {
        Fail "$label failed (exit $code)"
    }
    return $output
}

# --------------------------------------------------------------------------- inputs
Step 'Inputs'
if (-not $GameDirectory) { $GameDirectory = Get-EnvBothScopes 'OP77_GAME_DIR' }
if (-not $GameDirectory) { Fail 'no game folder: pass -GameDirectory or set OP77_GAME_DIR (user scope is read too)' }
$GameDirectory = [IO.Path]::GetFullPath($GameDirectory)
$tweakdb = Join-Path $GameDirectory 'r6\cache\tweakdb.bin'
if (-not (Test-Path -LiteralPath $tweakdb -PathType Leaf)) { Fail "tweakdb.bin not found: $tweakdb" }
Write-Host "   game      $GameDirectory (read only)"

$script:UvExe = if ($Uv) { $Uv } else { (Get-Command uv -ErrorAction SilentlyContinue)?.Source }
if (-not $script:UvExe -or -not (Test-Path -LiteralPath $script:UvExe)) { Fail 'uv not found: install it or pass -Uv <uv.exe>' }
Write-Host "   uv        $script:UvExe"

if (-not $OutDir) { $OutDir = Join-Path $repo 'artifacts/vehicle-kit/stages' }
$script:OutRoot = [IO.Path]::GetFullPath($OutDir).TrimEnd([IO.Path]::DirectorySeparatorChar)
New-Item -ItemType Directory -Force -Path $script:OutRoot | Out-Null
if ($script:OutRoot.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    & git -C $repo check-ignore -q -- (Join-Path $script:OutRoot 'probe.zip')
    if ($LASTEXITCODE -ne 0) { Fail "output folder $script:OutRoot is inside the repository but not git-ignored" }
}
Write-Host "   output    $script:OutRoot"

# --------------------------------------------------------------------------- 1. generate + check
Step ('Generate the stage records' + $(if ($withSounds) { ' and engine sounds' } else { '' }) + ' (make_stages.py, offline)')
$work = Reset-Dir (Join-Path $script:OutRoot 'work')
$genArgs = @('--out-dir', $work) + $(if ($withSounds) { @() } else { @('--no-sounds') })
$genOut = Invoke-Generator 'generation' $genArgs $(if ($withSounds) { 'VK_SOUNDS_GEN_OK' } else { 'VK_STAGES_GEN_OK' })
$genText = $genOut -join "`n"
$yaml = Join-Path $work 'open77-lightrp-stages.yaml'
$yamlSha = Sha256 $yaml
$records = [int](([regex]::Match($genText, 'VK_STAGES_GEN_OK records=(\d+)')).Groups[1].Value)
$models = [int](([regex]::Match($genText, 'VK_STAGES_GEN_OK records=\d+ models=(\d+)')).Groups[1].Value)
if ($records -le 0 -or $models -le 0) { Fail 'could not read the record and model counts from the generator' }
Write-Host "   yaml      $yaml ($records records, sha256 $yamlSha)"
$soundRecords = 0; $soundCount = 0; $soundYaml = $null; $soundSha = $null; $soundBytes = 0
if ($withSounds) {
    $m = [regex]::Match($genText, 'VK_SOUNDS_GEN_OK records=(\d+) models=\d+ sounds=(\d+) bytes=(\d+)')
    if (-not $m.Success) { Fail 'could not read the engine-sound counts from the generator' }
    $soundRecords = [int]$m.Groups[1].Value; $soundCount = [int]$m.Groups[2].Value; $soundBytes = [int]$m.Groups[3].Value
    $soundYaml = Join-Path $work 'open77-lightrp-engine-sounds.yaml'
    $soundSha = Sha256 $soundYaml
    Write-Host "   sounds    $soundYaml ($soundRecords records, $soundCount sounds, $soundBytes bytes, sha256 $soundSha)"
}
# Revision: the stage YAML's sha256 prefix alone (pre-wave-2 builds), or the hash of both YAML hashes.
$rev12 = if ($withSounds) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("stages:$yamlSha`nsounds:$soundSha`n")
    ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant().Substring(0, 12)
} else { $yamlSha.Substring(0, 12) }

# --------------------------------------------------------------------------- 2. preload_mod ZIP
Step 'preload_mod ZIP'
$resourceDir = Reset-Dir (Join-Path $script:OutRoot "resource/$ResourceName")
$zipName = "${ArchiveName}_$rev12.zip"
$zipPath = Join-Path $resourceDir "dist/$zipName"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zipPath) | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipEntries = [ordered]@{ $ZipEntry = $yaml }
if ($withSounds) { $zipEntries[$SoundsZipEntry] = $soundYaml }
$fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
try {
    $zip = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($name in $zipEntries.Keys) {
        $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        # A fixed timestamp keeps the ZIP byte-identical across rebuilds of the same YAML.
        $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $dst = $entry.Open(); $src = [IO.File]::OpenRead($zipEntries[$name])
        try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
    }
    $zip.Dispose()
} finally { $fs.Dispose() }

# Read the ZIP back: exactly the expected entries, under r6/tweaks, .yaml, the same bytes as the YAMLs.
$checkDir = Reset-Dir (Join-Path $work 'zip-check')
$extracted = @{}
$z = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entries = @($z.Entries | ForEach-Object { $_.FullName })
    if (($entries -join '|') -ne (@($zipEntries.Keys) -join '|')) { Fail "ZIP layout is wrong: $($entries -join ', ')" }
    foreach ($e in $z.Entries) {
        if ($e.FullName -notmatch '^r6/tweaks/LightRP/[A-Za-z0-9_.-]+\.yaml$') { Fail "ZIP entry outside r6/tweaks/LightRP or not a .yaml: $($e.FullName)" }
        $out = Join-Path $checkDir ([IO.Path]::GetFileName($e.FullName))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out)
        if ((Sha256 $out) -ne (Sha256 $zipEntries[$e.FullName])) { Fail "the YAML $($e.FullName) inside the ZIP differs from the generated YAML" }
        $extracted[$e.FullName] = $out
    }
} finally { $z.Dispose() }
$zipBytes = (Get-Item -LiteralPath $zipPath).Length
$zipSha = Sha256 $zipPath
Write-Host "   $zipName  $zipBytes bytes  entries: $(@($zipEntries.Keys) -join ', ')"

Step 'Re-check the YAMLs taken out of the ZIP'
$null = Invoke-Generator 'check' @('--check', $extracted[$ZipEntry]) 'VK_STAGES_CHECK_OK'
if ($withSounds) {
    $null = Invoke-Generator 'sound check' @('--check-sounds', $extracted[$SoundsZipEntry], '--stages-yaml', $extracted[$ZipEntry]) 'VK_SOUNDS_CHECK_OK'
}

# --------------------------------------------------------------------------- 3. draft resource
Step 'Draft Light RP resource'
New-Item -ItemType Directory -Force -Path (Join-Path $resourceDir 'server') | Out-Null
Copy-Item -LiteralPath (Join-Path $work 'stages.lua') -Destination (Join-Path $resourceDir 'server/stages.lua')
if ($withSounds) { Copy-Item -LiteralPath (Join-Path $work 'engine-sounds.lua') -Destination (Join-Path $resourceDir 'server/engine_sounds.lua') }
$soundScript = if ($withSounds) { "server_script 'server/engine_sounds.lua'`n" } else { '' }
Write-Utf8NoBom (Join-Path $resourceDir 'open77.lua') (@'
-- Light RP performance stages and engine sounds (DRAFT). Ships the TweakXL records
-- Vehicle.<dealer record>_o77s1..s3 (stages) and _o77[s<n>]a<k> (engine sounds) as an inert
-- preload_mod (r6/tweaks/LightRP/*.yaml): the launcher projects it before the game starts,
-- TweakXL creates the records at boot. Needs the TweakXL loader resource in resources.load
-- (an executable package: the world must be unsecured or the hash verified).
-- Generated by scripts/vehicle-kit/stages/build-stages.ps1 (revision @@REV@@). Edit the
-- generator, not this file.
resource '@@RESOURCE@@'
version '@@VERSION@@'
auto_start true
dependency 'tweakxl >=@@TWEAKXL@@'
preload_mod 'dist/@@ZIP@@'
server_script 'server/stages.lua'
@@SOUNDS@@server_script 'server/main.lua'
'@).Replace('@@REV@@', $rev12).Replace('@@RESOURCE@@', $ResourceName).Replace('@@VERSION@@', $ResourceVersion).Replace('@@TWEAKXL@@', $TweakXlMin).Replace('@@ZIP@@', $zipName).Replace('@@SOUNDS@@', $soundScript)
$mainTemplate = Join-Path $stagesRoot 'lua/stages_main.lua'
$mainText = [IO.File]::ReadAllText($mainTemplate)
if ($mainText.StartsWith([char]0xFEFF)) { Fail "$mainTemplate starts with a BOM (Lua must not)" }
Write-Utf8NoBom (Join-Path $resourceDir 'server/main.lua') $mainText.Replace('@@RESOURCE@@', $ResourceName)

# --------------------------------------------------------------------------- 4. manifest
Step 'Manifest'
Copy-Item -LiteralPath $yaml -Destination (Join-Path $script:OutRoot 'open77-lightrp-stages.yaml') -Force
Copy-Item -LiteralPath (Join-Path $work 'stages-manifest.json') -Destination (Join-Path $script:OutRoot 'stages-manifest.json') -Force
Copy-Item -LiteralPath (Join-Path $work 'stages-table.md') -Destination (Join-Path $script:OutRoot 'stages-table.md') -Force
# The Light RP gamemode's per-record data (stage prices, sound counts): server/config/vehicle_stage_catalogue.lua.
Copy-Item -LiteralPath (Join-Path $work 'lightrp-vehicle-stage-catalogue.lua') -Destination (Join-Path $script:OutRoot 'lightrp-vehicle-stage-catalogue.lua') -Force
foreach ($stale in 'open77-lightrp-engine-sounds.yaml', 'engine-sounds-manifest.json') {
    $p = Join-Path $script:OutRoot $stale
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
if ($withSounds) {
    Copy-Item -LiteralPath $soundYaml -Destination (Join-Path $script:OutRoot 'open77-lightrp-engine-sounds.yaml') -Force
    Copy-Item -LiteralPath (Join-Path $work 'engine-sounds-manifest.json') -Destination (Join-Path $script:OutRoot 'engine-sounds-manifest.json') -Force
}
$manifest = [ordered]@{
    schema = 'open77.vehicle-stages-pack/1'
    revision = $rev12
    resource = [ordered]@{ name = $ResourceName; version = $ResourceVersion; path = [IO.Path]::GetRelativePath($script:OutRoot, $resourceDir).Replace('\', '/'); tweakxlMin = $TweakXlMin }
    zip = [ordered]@{ name = $zipName; sha256 = $zipSha; bytes = $zipBytes; entries = @($zipEntries.Keys) }
    yaml = [ordered]@{ sha256 = $yamlSha; records = $records; models = $models; bytes = (Get-Item -LiteralPath $yaml).Length }
    engineSounds = $(if ($withSounds) { [ordered]@{ sha256 = $soundSha; records = $soundRecords; sounds = $soundCount; bytes = $soundBytes } } else { $null })
    deployed = $false
}
Write-Utf8NoBom (Join-Path $script:OutRoot 'manifest.json') ($manifest | ConvertTo-Json -Depth 8)
$sumFiles = @($zipPath, (Join-Path $script:OutRoot 'open77-lightrp-stages.yaml'), (Join-Path $resourceDir 'open77.lua'),
    (Join-Path $resourceDir 'server/main.lua'), (Join-Path $resourceDir 'server/stages.lua'),
    (Join-Path $script:OutRoot 'lightrp-vehicle-stage-catalogue.lua'))
if ($withSounds) {
    $sumFiles += @((Join-Path $script:OutRoot 'open77-lightrp-engine-sounds.yaml'), (Join-Path $resourceDir 'server/engine_sounds.lua'))
}
$sums = foreach ($f in $sumFiles) { "{0}  {1}" -f (Sha256 $f), [IO.Path]::GetRelativePath($script:OutRoot, $f).Replace('\', '/') }
Write-Utf8NoBom (Join-Path $script:OutRoot 'SHA256SUMS') (($sums -join "`n") + "`n")

Step 'Done'
Write-Host "   resource  $resourceDir"
Write-Host "   zip       $zipPath ($zipBytes bytes)"
Write-Host "   install   nothing was copied to the game: a lab installs $(@($zipEntries.Keys) -join ' and ') by hand, a world ships the resource"
Write-Host "VK_STAGES_OK revision=$rev12 models=$models records=$records soundRecords=$soundRecords zip=$zipName bytes=$zipBytes sha256=$zipSha (not deployed)"
