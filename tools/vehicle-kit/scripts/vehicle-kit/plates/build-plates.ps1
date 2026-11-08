#requires -Version 7.0
<#
.SYNOPSIS
    Builds the production plate pack of the vehicle-customization campaign (route W): an
    ArchiveXL preload_mod that adds a disabled screen quad + text widget over the rear (and
    front) plate of the 15 dealer models, the staff-only Caliburn and every other vanilla
    player vehicle but the quest variants (player-models.py), without copying any
    vanilla data.

.DESCRIPTION
    1. Read the vanilla appearance resources, entities, plate meshes and widgets from the
       local game (read-only; cached under the git-ignored output folder; never shipped).
    2. Survey every appearance definition for its plate components, and decode the plate,
       screen and rear-bumper meshes to glb (cached).
    3. Per design (original; sign and lcd are retired, see the README): place the quad
       over each plate mesh by the cover rule and prove by ray casting that no factory
       print shows around it (native/cover.cjs; the build fails otherwise), generate the
       WolvenKit JSON of OUR files only (native/plates.cjs: one patch .app per vanilla
       .app, plus our .inkwidget), deserialize, round trip check, no-vanilla-bytes scan,
       pack, pin the archive timestamps (H's normalize-archive.cjs), list + extract byte
       check, .xl, deterministic preload_mod ZIP, ZIP-vs-vanilla hash check, lab resource.
    4. Compile client/redscript (Open77VehiclePlate.reds included) plus the LAB ONLY trigger
       offline with the game's own scc.exe, in a scratch copy of the vanilla bundle.

    Never writes into the game folder, never launches the game, never deploys. Same inputs
    = same revision = byte-identical archive and ZIP.

    Only one design may be installed at a time: every design patches the same vanilla
    definitions with the same component names.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/plates/build-plates.ps1
    pwsh -File scripts/vehicle-kit/plates/build-plates.ps1 -Design original -UpdateData
#>
[CmdletBinding()]
param(
    [ValidateSet('original')] [string[]] $Design = @('original'),
    [string] $OutDir,
    [string] $GameDirectory,
    [string] $WolvenKitCli,
    [switch] $SkipRedscriptCheck,
    [switch] $RefreshVanilla,
    [switch] $UpdateData,
    [int] $RedscriptTimeoutSeconds = 240
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$kitRoot = $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $kitRoot '../../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')

$SpecPath = Join-Path $kitRoot 'specs/plates.json'
$Generator = Join-Path $kitRoot 'native/plates.cjs'
$Normalizer = Join-Path $repo 'scripts/vehicle-kit/archivexl/native/normalize-archive.cjs'   # sub-agent H's, used as is
$LabServer = Join-Path $kitRoot 'lab/plates_server.lua'
$LabReds = Join-Path $kitRoot 'lab/Open77VehiclePlateLab.reds'
$ClientReds = Join-Path $repo 'client/redscript/Open77VehiclePlate.reds'
$LabPermissions = @('world.vehicles', 'world.vehicles.appearance', 'network.events', 'players.life.read')
$FixedZipTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail([string] $text) { throw "vehicle-kit/plates: $text" }

function Get-EnvBothScopes([string] $name)
{
    foreach ($scope in 'Process', 'User') {
        $v = [Environment]::GetEnvironmentVariable($name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $null
}

function Invoke-Tool([string] $label, [string] $exe, [string[]] $arguments, [string] $marker, [string] $tolerate)
{
    $output = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $errors = @($output | Where-Object { $_ -match '\[\s*\d+:\s*Error\s*\]|Error:|PLATES_FAILED|AXL_ARCHIVE_FAILED' -and -not ($tolerate -and $_ -match $tolerate) })
    foreach ($line in $output) {
        if ($line -match '^PLATES_|^AXL_|\[\s*\d+:\s*(Error|Warning)\s*\]|Error') { Write-Host "   $line" }
    }
    if ($code -ne 0 -or $errors.Count -gt 0 -or ($marker -and -not ($output -match [regex]::Escape($marker)))) {
        $tail = ($output | Select-Object -Last 25) -join "`n"
        Fail "$label failed (exit $code).`n$tail"
    }
    return $output
}

function Wk([string] $label, [string[]] $arguments, [string] $tolerate) { Invoke-Tool "WolvenKit $label" $script:Cli ($arguments + @('--verbosity', 'Minimal')) $null $tolerate }

function Reset-Dir([string] $path)
{
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($script:OutRoot + [IO.Path]::DirectorySeparatorChar)) { Fail "refusing to clear $full (outside $script:OutRoot)" }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $full | Out-Null
    return $full
}

function Sha256([string] $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Read-Text([string] $path) { (Get-Content -LiteralPath $path -Raw) -replace "`r`n", "`n" }

function Write-Utf8NoBom([string] $path, [string] $text)
{
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $text = $text -replace "`r`n", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

function Assert-NoBom([string] $path)
{
    $head = [IO.File]::ReadAllBytes($path)
    if ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) { Fail "$path has a BOM: Lua and REDscript files must not" }
}

function Local-Path([string] $root, [string] $depot) { Join-Path $root ($depot -replace '\\', '/') }

function Write-DeterministicZip([string] $zipPath, $layout)
{
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zipPath) | Out-Null
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    $fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    try {
        $zip = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($name in $layout.Keys) {
            $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $FixedZipTime
            $dst = $entry.Open(); $src = [IO.File]::OpenRead($layout[$name])
            try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
        }
        $zip.Dispose()
    } finally { $fs.Dispose() }
}

# Hashes of every entry of a ZIP, read back from the ZIP itself.
function Get-ZipEntryHashes([string] $zipPath)
{
    $out = [ordered]@{}
    $z = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($e in $z.Entries) {
            $s = $e.Open(); $ms = [IO.MemoryStream]::new()
            try { $s.CopyTo($ms) } finally { $s.Dispose() }
            $out[$e.FullName] = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($ms.ToArray())) -replace '-', '').ToLowerInvariant()
        }
    } finally { $z.Dispose() }
    return $out
}

# Compiles client/redscript plus the lab trigger against a scratch copy of the vanilla
# bundle. scc never exits when its output is redirected and a compile error opens a modal
# window: watch its output and kill it once it has reported (sub-agent H's method).
function Test-Redscript([string[]] $labFiles, [string] $work)
{
    $scc = Join-Path $GameDirectory 'engine\tools\scc.exe'
    if (-not (Test-Path -LiteralPath $scc)) { Fail "scc.exe not found at $scc (-SkipRedscriptCheck to skip)" }
    $bundle = Join-Path $GameDirectory 'r6\cache\final.redscripts.bk'
    if (-not (Test-Path -LiteralPath $bundle)) { $bundle = Join-Path $GameDirectory 'r6\cache\final.redscripts' }
    $root = Reset-Dir (Join-Path $work 'scc')
    $scripts = Join-Path $root 'r6\scripts'
    New-Item -ItemType Directory -Force -Path (Join-Path $scripts 'Open77'), (Join-Path $scripts 'Open77Lab'), (Join-Path $root 'r6\cache') | Out-Null
    Copy-Item -Path (Join-Path $repo 'client\redscript\*.reds') -Destination (Join-Path $scripts 'Open77')
    foreach ($f in $labFiles) { Copy-Item -LiteralPath $f -Destination (Join-Path $scripts 'Open77Lab') }
    $cache = Join-Path $root 'r6\cache\final.redscripts'
    Copy-Item -LiteralPath $bundle -Destination $cache            # a copy: scc renames the bundle it finds
    $stdout = Join-Path $root 'scc-stdout.txt'
    $process = Start-Process -FilePath $scc -ArgumentList @('-compile', "`"$scripts`"", "`"$cache`"") -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError (Join-Path $root 'scc-stderr.txt')
    $deadline = (Get-Date).AddSeconds($RedscriptTimeoutSeconds)
    $killed = $false
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 500
        $text = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
        if ($text -match 'Compilation failed|\[ERROR' -or (Get-Date) -gt $deadline) {
            Start-Sleep -Milliseconds 1500
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force; $killed = $true }
            break
        }
    }
    $lines = @(Get-Content -LiteralPath $stdout)
    $errors = @($lines | Where-Object { $_ -match '\[ERROR' })
    $ours = @($lines | Where-Object { $_ -match '\[WARN' -and $_ -match 'Open77VehiclePlate|Open77Lab' })
    $summary = @($lines | Where-Object { $_ -match 'Completed with' }) | Select-Object -Last 1
    $exit = if ($killed) { 'killed' } else { $process.ExitCode }
    if ($errors.Count -or $exit -ne 0) {
        $context = ($lines | Where-Object { $_ -notmatch '^r6\\' } | Select-Object -Last 40) -join "`n"
        Fail "REDscript does not compile (scc exit $exit):`n$context"
    }
    if (-not ($lines -match 'Succesfully written|Successfully written')) { Fail 'scc reported no error but wrote no bundle' }
    foreach ($w in $ours) { Write-Warning $w }
    Write-Host "   scc: $summary (warnings in the plate files: $($ours.Count))"
    return [ordered]@{ compiler = 'engine\tools\scc.exe'; result = 'ok'; exit = $exit; errors = 0; summary = "$summary"; plateWarnings = $ours.Count; bundle = (Split-Path -Leaf $bundle) }
}

# --------------------------------------------------------------------------- setup
$node = (Get-Command node -ErrorAction SilentlyContinue)?.Source
if (-not $node) { Fail 'node (Node.js 18+) not found on PATH' }
$nodeVersion = (& $node --version).Trim()
$script:Cli = Find-WolvenKitCli -Explicit $WolvenKitCli
$wkVersion = ((& $script:Cli --version) 2>&1 | Select-Object -First 1).ToString().Trim()
if (-not $GameDirectory) { $GameDirectory = Get-EnvBothScopes 'OP77_GAME_DIR' }
if (-not $GameDirectory -or -not (Test-Path -LiteralPath (Join-Path $GameDirectory 'archive\pc\content'))) {
    Fail "game directory not found (got '$GameDirectory'). Pass -GameDirectory or set OP77_GAME_DIR; it is only read."
}
$GameDirectory = [IO.Path]::GetFullPath($GameDirectory)
if (-not $OutDir) { $OutDir = Join-Path $repo 'artifacts/vehicle-kit-plates' }
$script:OutRoot = [IO.Path]::GetFullPath($OutDir)
if ($script:OutRoot.StartsWith($GameDirectory, [StringComparison]::OrdinalIgnoreCase)) { Fail 'the output folder may not be inside the game directory' }
New-Item -ItemType Directory -Force -Path $script:OutRoot | Out-Null
if ($script:OutRoot.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    & git -C $repo check-ignore -q -- (Join-Path $script:OutRoot 'probe.archive')
    if ($LASTEXITCODE -ne 0) { Fail "output folder $script:OutRoot is inside the repository but not git-ignored" }
}
foreach ($f in $LabServer, $LabReds, $ClientReds) { Assert-NoBom $f }
Write-Host "   WolvenKit $wkVersion, node $nodeVersion, game $GameDirectory"
Write-Host "   output    $script:OutRoot"

$spec = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json
if ($spec.schema -ne 'open77.vehicle-kit.plates/1') { Fail "unexpected spec schema $($spec.schema)" }
if ($spec.resource -notmatch '^[a-z][a-z0-9_]{2,63}$') { Fail "resource name $($spec.resource) is not a valid resource slug" }

$apps = @($spec.models | ForEach-Object { $_.apps } | Sort-Object -Unique)
$ents = @($spec.models | ForEach-Object { $_.entity } | Sort-Object -Unique)
$plateMeshes = @($spec.plateMeshes.PSObject.Properties.Name | Sort-Object)
$widgets = @(foreach ($d in $spec.designs.PSObject.Properties.Value) { $w = $d.PSObject.Properties['widget']; if ($w) { $w.Value } })
$fonts = @($spec.designs.original.fonts.PSObject.Properties.Value | ForEach-Object { $_.family })
$depotPaths = @(@($apps) + @($ents) + @($spec.screenMesh.path) + @($plateMeshes) + @($widgets) + @($fonts) | Sort-Object -Unique)

# --------------------------------------------------------------------------- 1. vanilla (cached, never shipped)
Step "vanilla resources: $($depotPaths.Count) files (read-only, cached)"
$vanillaDir = Join-Path $script:OutRoot 'vanilla'
$missing = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (Local-Path $vanillaDir $_)) })
if ($RefreshVanilla -or $missing.Count) {
    if ($RefreshVanilla) { $vanillaDir = Reset-Dir $vanillaDir }
    foreach ($folder in 'archive\pc\content', 'archive\pc\ep1') {
        $source = Join-Path $GameDirectory $folder
        $still = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (Local-Path $vanillaDir $_)) })
        if (-not $still.Count) { break }
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $pattern = '^(' + (($still | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
        Wk "extract from $folder" @('extract', $source, '--regex', $pattern, '--outpath', $vanillaDir, '--gamepath', $GameDirectory) | Out-Null
    }
    $missing = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (Local-Path $vanillaDir $_)) })
    if ($missing.Count) { Fail "not found in the game archives: $($missing -join ', ')" }
}
$vanillaHashes = [ordered]@{}
foreach ($p in $depotPaths) { $vanillaHashes[$p] = Sha256 (Local-Path $vanillaDir $p) }

$vanillaJsonDir = Join-Path $script:OutRoot 'vanilla-json'
$toSerialize = @(@($apps) + @($ents) + @($plateMeshes) + @($spec.screenMesh.path))
$dupes = @($toSerialize | Group-Object { ($_ -split '\\')[-1] } | Where-Object Count -gt 1)
if ($dupes) { Fail "convert serialize flattens names; duplicate basenames: $($dupes.Name -join ', ')" }
$jsonOf = [ordered]@{}
$stale = @()
foreach ($p in $toSerialize) {
    $json = Join-Path $vanillaJsonDir "$(($p -split '\\')[-1]).json"
    $stamp = "$json.sha256"
    if ($RefreshVanilla -or -not (Test-Path -LiteralPath $json) -or -not (Test-Path -LiteralPath $stamp) -or (Read-Text $stamp).Trim() -ne $vanillaHashes[$p]) { $stale += $p }
    $jsonOf[$p] = $json
}
New-Item -ItemType Directory -Force -Path $vanillaJsonDir | Out-Null
# One WolvenKit start per batch: a start costs more than a file.
for ($i = 0; $i -lt $stale.Count; $i += 20) {
    $batch = $stale[$i..([Math]::Min($i + 19, $stale.Count - 1))]
    Wk "serialize $($batch.Count) files" (@('convert', 'serialize') + @($batch | ForEach-Object { Local-Path $vanillaDir $_ }) + @('--outpath', $vanillaJsonDir)) | Out-Null
    foreach ($p in $batch) {
        if (-not (Test-Path -LiteralPath $jsonOf[$p])) { Fail "serialize produced no $($jsonOf[$p])" }
        Write-Utf8NoBom "$($jsonOf[$p]).sha256" $vanillaHashes[$p]
    }
}
$appJson = [ordered]@{}; foreach ($p in $apps) { $appJson[$p] = $jsonOf[$p] }
$entJson = [ordered]@{}; foreach ($p in $ents) { $entJson[$p] = $jsonOf[$p] }
$meshJson = [ordered]@{}; foreach ($p in @($plateMeshes) + @($spec.screenMesh.path)) { $meshJson[$p] = $jsonOf[$p] }

# --------------------------------------------------------------------------- 2. survey + geometry
Step 'survey plate components; decode plate, screen and bumper meshes'
$surveyDir = Reset-Dir (Join-Path $script:OutRoot 'survey')
$surveyPlan = Join-Path $surveyDir 'plan.json'
Write-Utf8NoBom $surveyPlan ([ordered]@{ spec = $SpecPath; reportDir = $surveyDir; apps = $appJson; ents = $entJson } | ConvertTo-Json -Depth 8)
Invoke-Tool 'survey' $node @($Generator, 'survey', $surveyPlan) 'PLATES_SURVEYED' | Out-Null
$bumpers = @((Get-Content -LiteralPath (Join-Path $surveyDir 'survey.json') -Raw | ConvertFrom-Json).neededMeshes)
$glbMeshes = @(@($spec.screenMesh.path) + @($plateMeshes) + @($bumpers) | Sort-Object -Unique)
$glbDir = Join-Path $script:OutRoot 'glb'
$glbOf = { param($p) Local-Path $glbDir ($p -replace '\.mesh$', '.glb') }
foreach ($folder in 'archive\pc\content', 'archive\pc\ep1') {
    $still = @($glbMeshes | Where-Object { -not (Test-Path -LiteralPath (& $glbOf $_)) })
    if (-not $still.Count) { break }
    $source = Join-Path $GameDirectory $folder
    if (-not (Test-Path -LiteralPath $source)) { continue }
    # uncook also writes the meshes' textures next to the glb: game data, left in the
    # git-ignored cache with the rest. Some bumpers' materials do not export; only the
    # geometry is used, and every glb is checked below.
    $rx = '^(' + (($still | ForEach-Object { [regex]::Escape($_.ToLowerInvariant()) }) -join '|') + ')$'
    Wk "uncook meshes from $folder" @('uncook', $source, '--regex', $rx, '--outpath', $glbDir, '--gamepath', $GameDirectory, '--mesh-export-type', 'MeshOnly') 'Failed to export materials from' | Out-Null
}
$missing = @($glbMeshes | Where-Object { -not (Test-Path -LiteralPath (& $glbOf $_)) })
if ($missing.Count) { Fail "no glb for: $($missing -join ', ')" }
$glbJson = [ordered]@{}; $glbHashes = [ordered]@{}
foreach ($p in $glbMeshes) { $glbJson[$p] = & $glbOf $p; $glbHashes[$p] = Sha256 (& $glbOf $p) }
Write-Host "   $($bumpers.Count) rear bumper meshes for mounts, $($glbMeshes.Count) glb in all"

# Every vanilla file the build read: the no-vanilla-bytes scan compares our files to them.
$vanillaFiles = @(@($depotPaths | ForEach-Object { Local-Path $vanillaDir $_ }) +
                  @(Get-ChildItem -LiteralPath $glbDir -Recurse -File -Filter '*.mesh' | ForEach-Object FullName) | Sort-Object -Unique)
$vanillaSet = [Collections.Generic.HashSet[string]]::new()
foreach ($f in $vanillaFiles) { [void] $vanillaSet.Add((Sha256 $f)) }

# --------------------------------------------------------------------------- 3. per design
$results = [ordered]@{}
foreach ($designName in $Design) {
    $designSpec = $spec.designs.$designName
    if (-not $designSpec) { Fail "unknown design $designName" }
    $root = Join-Path $script:OutRoot $designName
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $add = { param($text) $hasher.AppendData([Text.Encoding]::UTF8.GetBytes([string] $text + "`n")) }
    & $add "design=$designName"
    & $add (Read-Text $SpecPath)
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $kitRoot 'native') -Filter '*.cjs' -File | Sort-Object Name) + @(Get-Item -LiteralPath $PSCommandPath) + @(Get-Item -LiteralPath $Normalizer)) {
        & $add $f.Name; & $add (Read-Text $f.FullName)
    }
    & $add $wkVersion
    foreach ($p in $vanillaHashes.Keys) { & $add "$p=$($vanillaHashes[$p])" }
    foreach ($p in $glbHashes.Keys) { & $add "glb:$p=$($glbHashes[$p])" }
    $revision = ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
    $rev12 = $revision.Substring(0, 12)
    $prefix = "open77\assets\$($spec.resource)\$rev12"
    Step "$designName`: revision $rev12 -> $prefix"

    $work = Join-Path $root 'work'
    $genDir = Reset-Dir (Join-Path $work 'generated')
    $genJsonDir = Join-Path $genDir 'json'
    $plan = [ordered]@{
        spec = $SpecPath; design = $designName; variant = 'disabled'; prefix = $prefix; outDir = $genJsonDir; reportDir = $genDir
        apps = $appJson; ents = $entJson; meshJson = $meshJson; glb = $glbJson; vanillaFiles = $vanillaFiles
    }
    $planFile = Join-Path $genDir 'plan.json'
    Write-Utf8NoBom $planFile ($plan | ConvertTo-Json -Depth 8)
    Invoke-Tool 'generate' $node @($Generator, 'generate', $planFile) 'PLATES_GENERATED' | Out-Null
    $report = Get-Content -LiteralPath (Join-Path $genDir 'generated.json') -Raw | ConvertFrom-Json
    $expected = @($report.files | Sort-Object)
    foreach ($f in $expected) { if (-not $f.StartsWith("$prefix\")) { Fail "generated file $f is outside $prefix" } }

    $stageDir = Reset-Dir (Join-Path $work 'stage')
    $stagePrefix = Join-Path $stageDir $prefix
    New-Item -ItemType Directory -Force -Path $stagePrefix | Out-Null
    $jsonFiles = @(Get-ChildItem -LiteralPath $genJsonDir -Filter '*.json' -File | Sort-Object Name | ForEach-Object FullName)
    for ($i = 0; $i -lt $jsonFiles.Count; $i += 20) {
        $batch = $jsonFiles[$i..([Math]::Min($i + 19, $jsonFiles.Count - 1))]
        Wk 'deserialize' (@('convert', 'deserialize') + $batch + @('--outpath', $stagePrefix)) | Out-Null
    }
    $staged = @(Get-ChildItem -LiteralPath $stageDir -Recurse -File | ForEach-Object { $_.FullName.Substring($stageDir.Length + 1) } | Sort-Object)
    if (Compare-Object $staged $expected) { Fail "staged files differ from the generated list:`n$(Compare-Object $staged $expected | Out-String)" }
    $roundtripDir = Reset-Dir (Join-Path $work 'roundtrip')
    Wk 'round trip serialize' @('convert', 'serialize', $stageDir, '--outpath', $roundtripDir) | Out-Null
    Invoke-Tool 'round trip check' $node @($Generator, 'validate', $planFile, $roundtripDir) 'PLATES_ROUNDTRIP_OK' | Out-Null
    $scan = Invoke-Tool 'no-vanilla-bytes scan' $node @($Generator, 'scan', $planFile, $stageDir) 'PLATES_SCAN_OK'

    Step "$designName`: pack and verify the archive"
    $packedDir = Reset-Dir (Join-Path $work 'packed')
    Wk 'pack' @('pack', $stageDir, '--outpath', $packedDir) | Out-Null
    $packed = Join-Path $packedDir 'stage.archive'
    if (-not (Test-Path -LiteralPath $packed)) { Fail "pack produced no $packed" }
    $archive = Join-Path $packedDir "$($spec.archiveName).archive"
    Move-Item -LiteralPath $packed -Destination $archive -Force
    Invoke-Tool 'normalize archive' $node @($Normalizer, $archive) 'AXL_ARCHIVE_NORMALIZED' | Out-Null
    $listing = Wk 'list archive' @('archive', $archive, '--list')
    $entries = @($listing | Where-Object { $_ -match '^[A-Za-z0-9_]+\\' } | ForEach-Object { $_.Trim() } | Sort-Object)
    if (Compare-Object $entries $expected) { Fail "archive entries differ from the staged files:`n$($listing -join "`n")" }
    $verifyDir = Reset-Dir (Join-Path $work 'verify')
    Wk 'extract for byte check' @('extract', $archive, '--outpath', $verifyDir) | Out-Null
    $receipts = @()
    foreach ($rel in $expected) {
        $a = Join-Path $stageDir $rel; $b = Join-Path $verifyDir $rel
        if (-not (Test-Path -LiteralPath $b)) { Fail "archive lost $rel" }
        $h = Sha256 $a
        if ((Sha256 $b) -ne $h) { Fail "archive changed the bytes of $rel" }
        if ($vanillaSet.Contains($h)) { Fail "$rel is byte-identical to a vanilla file" }
        $receipts += [ordered]@{ path = $rel; sha256 = $h; bytes = (Get-Item -LiteralPath $a).Length }
    }

    # ArchiveXL (fork open77/1.28) merges each patch definition into the vanilla definition
    # of the same name. props: appearances (walk the definitions) + components (prefetch
    # them for the entity builder); partsValues, partsOverrides, dependencies, visualTags
    # and censorship are not listed, so nothing else of the vanilla resource changes.
    $patches = @($report.apps.PSObject.Properties | Where-Object { $_.Value.patch } | Sort-Object Name)
    $xl = [Text.StringBuilder]::new()
    [void] $xl.AppendLine("# Open77 plate pack $($spec.archiveName), design $designName, revision $rev12.")
    [void] $xl.AppendLine('# Generated by scripts/vehicle-kit/plates/build-plates.ps1. Each patch .app holds only Open77')
    [void] $xl.AppendLine('# components (disabled), in definitions named after the vanilla definitions they extend.')
    [void] $xl.AppendLine('resource:')
    [void] $xl.AppendLine('  patch:')
    foreach ($p in $patches) {
        [void] $xl.AppendLine("    $($p.Value.patch):")
        [void] $xl.AppendLine('      props: [ appearances, components ]')
        [void] $xl.AppendLine('      targets:')
        [void] $xl.AppendLine("        - $($p.Name)")
    }
    $xlName = "$($spec.archiveName).archive.xl"
    $xlPath = Join-Path $packedDir $xlName
    Write-Utf8NoBom $xlPath $xl.ToString()

    Step "$designName`: preload_mod ZIP and lab resource"
    $resourceDir = Reset-Dir (Join-Path $root "resource/$($spec.resource)")
    $zipName = "$($spec.archiveName)_$($designName)_$rev12.zip"
    $zipPath = Join-Path $resourceDir "dist/$zipName"
    $zipLayout = [ordered]@{ "archive/pc/mod/$($spec.archiveName).archive" = $archive; "archive/pc/mod/$xlName" = $xlPath }
    Write-DeterministicZip $zipPath $zipLayout
    $zipHashes = Get-ZipEntryHashes $zipPath
    if (Compare-Object @($zipHashes.Keys) @($zipLayout.Keys)) { Fail "ZIP layout is wrong: $($zipHashes.Keys -join ', ')" }
    foreach ($name in $zipHashes.Keys) {
        if ($zipHashes[$name] -ne (Sha256 $zipLayout[$name])) { Fail "ZIP entry $name does not hold the built file" }
        if ($vanillaSet.Contains($zipHashes[$name])) { Fail "ZIP entry $name is byte-identical to a vanilla file" }
    }

    $permissionList = ($LabPermissions | ForEach-Object { "'$_'" }) -join ', '
    Write-Utf8NoBom (Join-Path $resourceDir 'open77.lua') @"
-- Open77 plate pack lab (vehicle customization, route W), design $designName. LAB ONLY: never start
-- it on a public server. Generated by scripts/vehicle-kit/plates/build-plates.ps1 (revision $rev12).
-- The preload_mod itself is production material (Open77 components only, no vanilla data); the lab
-- part is this resource's commands and the hand-installed trigger Open77VehiclePlateLab.reds.
resource '$($spec.resource)_lab'
version '0.1.0'
auto_start false
reload_policy 'reconnect'
server_script 'server.lua'
preload_mod 'dist/$zipName'
permissions { $permissionList }
"@
    $luaModels = [Text.StringBuilder]::new("{`n")
    foreach ($m in $spec.models) {
        $trims = (@($m.trims) | ForEach-Object { "'$_'" }) -join ', '
        [void] $luaModels.AppendLine("    $($m.key) = { record = '$($m.record)', player = '$($m.playerEntry)', trims = { $trims } },")
    }
    [void] $luaModels.Append('}')
    $luaOrder = '{ ' + ((@($spec.models) | ForEach-Object { "'$($_.key)'" }) -join ', ') + ' }'
    $serverText = (Read-Text $LabServer).Replace('@@REVISION@@', $rev12).Replace('@@DESIGN@@', $designName).Replace('@@MODELS@@', $luaModels.ToString()).Replace('@@ORDER@@', $luaOrder)
    Write-Utf8NoBom (Join-Path $resourceDir 'server.lua') $serverText

    $manifest = [ordered]@{
        schema = 'open77.vehicle-kit.plates-build/1'
        resource = $spec.resource
        design = $designName
        revision = $revision
        prefix = $prefix
        tools = [ordered]@{ wolvenkit = $wkVersion; node = $nodeVersion }
        vanilla = $vanillaHashes
        geometry = $glbHashes
        widget = $report.widget
        coverage = @($report.models | ForEach-Object { [ordered]@{ key = $_.key; player = $_.player.status; trims = @($_.trims | ForEach-Object { "$($_.entry)=$($_.status)" }) } })
        cover = [ordered]@{
            rule = $report.placement
            plates = @($report.plates.PSObject.Properties | ForEach-Object {
                $c = $_.Value.cover; $l = $_.Value.legacy
                [ordered]@{
                    mesh = ($_.Name -split '\\')[-1]; item = $_.Value.item; quadMm = $c.sizeMm; marginMm = $c.marginMm; gapMm = $c.gapMm
                    printViews = "$($c.leak.cone.viewsWithPrint)/$($c.leak.cone.views) within $($c.leak.cone.maxDegrees) deg"; mountChunkMask = $_.Value.mountChunkMask
                    before = [ordered]@{ quadMm = $l.sizeMm; frontalUncoveredMm = [ordered]@{ top = $l.frontal.top; bottom = $l.frontal.bottom; left = $l.frontal.left; right = $l.frontal.right }; printViews = "$($l.leak.cone.viewsWithPrint)/$($l.leak.cone.views)" }
                }
            })
        }
        noVanilla = [ordered]@{
            structural = 'round trip: only open77_plate* components, only definition names that exist in the target, only allow-listed depot paths and types'
            hashes = 'no staged file and no ZIP entry equals a vanilla file read by the build'
            scan = (@($scan | Where-Object { $_ -match '^PLATES_SCAN_OK' }) | Select-Object -First 1)
        }
        files = $receipts
        archive = [ordered]@{ path = $archive; sha256 = (Sha256 $archive); bytes = (Get-Item -LiteralPath $archive).Length; entries = $entries }
        xl = [ordered]@{ path = $xlPath; sha256 = (Sha256 $xlPath) }
        zip = [ordered]@{ path = $zipPath; sha256 = (Sha256 $zipPath); bytes = (Get-Item -LiteralPath $zipPath).Length; entries = $zipHashes }
        resourceDir = $resourceDir
    }
    Write-Utf8NoBom (Join-Path $root 'manifest.json') ($manifest | ConvertTo-Json -Depth 16)
    Write-Utf8NoBom (Join-Path $root 'SHA256SUMS') (@("$($manifest.archive.sha256)  $($spec.archiveName).archive", "$($manifest.xl.sha256)  $xlName", "$($manifest.zip.sha256)  $zipName") -join "`n")
    $results[$designName] = $manifest
    Write-Host "   archive $($manifest.archive.sha256)  $archive"
    Write-Host "   zip     $($manifest.zip.sha256)  $zipPath"
}

# --------------------------------------------------------------------------- 4. REDscript + lab install
Step 'REDscript: production plate script + LAB ONLY trigger'
$labInstall = Reset-Dir (Join-Path $script:OutRoot 'lab-install')
$labScripts = Join-Path $labInstall 'r6\scripts\Open77Lab'
$labCopy = Join-Path $labScripts (Split-Path -Leaf $LabReds)
Write-Utf8NoBom $labCopy (Read-Text $LabReds)
$reds = [ordered]@{ labTrigger = [ordered]@{ installUnder = 'r6/scripts/Open77Lab/'; name = (Split-Path -Leaf $labCopy); sha256 = (Sha256 $labCopy) }; client = [ordered]@{ name = (Split-Path -Leaf $ClientReds); sha256 = (Sha256 $ClientReds) } }
if ($SkipRedscriptCheck) { Write-Warning 'REDscript NOT compile-checked (-SkipRedscriptCheck)'; $reds.check = 'skipped' }
else { $reds.check = Test-Redscript @($labCopy) $labInstall }
Write-Utf8NoBom (Join-Path $labInstall 'redscript.json') ($reds | ConvertTo-Json -Depth 8)
Remove-Item -LiteralPath (Join-Path $labInstall 'scc') -Recurse -Force -ErrorAction SilentlyContinue

# --------------------------------------------------------------------------- 5. committed data
if ($UpdateData) {
    $source = if ($results.Contains('original')) { 'original' } else { @($results.Keys)[0] }
    Step "data: per-model plate table (from design $source)"
    $dataPlan = Join-Path $script:OutRoot "$source/work/generated/plan.json"
    Invoke-Tool 'data' $node @($Generator, 'data', $dataPlan, (Join-Path $kitRoot 'data')) 'PLATES_DATA_WRITTEN' | Out-Null
}

Step 'Done'
foreach ($key in $results.Keys) {
    $m = $results[$key]
    Write-Host ("PLATES_PACK_OK {0} revision={1} archive={2} zip={3}" -f $key, $m.revision.Substring(0, 12), $m.archive.sha256, $m.zip.sha256)
}
Write-Host "PLATES_REDSCRIPT $(if ($reds.check -is [string]) { $reds.check } else { $reds.check.result })"
