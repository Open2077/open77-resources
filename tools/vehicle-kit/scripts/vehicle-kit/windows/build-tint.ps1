#requires -Version 7.0
<#
.SYNOPSIS
    Builds the window tint packs of the vehicle-customization campaign (route 2,
    CONTRACT.md §6): the production ArchiveXL mesh-patch pack open77_vehicle_tint and the
    one-mesh LAB ONLY pack open77_vehicle_tint_t2, each with its server resource skeleton.

.DESCRIPTION
    1. Read the target glass meshes and the base materials from the local game (read-only;
       cached under the git-ignored output folder; never shipped) and serialize them, for
       checks only: the data still matches the installed game, our names are free in every
       target, every value we set is a parameter of its template.
    2. Per pack: revision = SHA-256 of the packPlan + meshes section of data/glass-2.50.json,
       native/tint.cjs, this script, the normalizer and the WolvenKit version. Generate the
       WolvenKit JSON of OUR files only (native/tint.cjs: original .mi + geometry-less patch
       meshes), deserialize, round trip + structural check, no-vanilla-bytes scan, pack, pin
       the archive timestamps (archivexl/native/normalize-archive.cjs), list + extract byte
       check, .archive.xl, deterministic preload_mod ZIP, ZIP-vs-vanilla hash check, server
       resource (open77.lua + no-op server.lua and client.lua + dist/<zip>) checked against the manifest
       rules of server/src/Open77.Resources/Manifests/ResourceManifestParser.cs.

    Never writes into the game folder, never launches the game, never deploys. Same inputs
    = same revision = byte-identical archive and ZIP.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/windows/build-tint.ps1
    pwsh -File scripts/vehicle-kit/windows/build-tint.ps1 -Pack t2
#>
[CmdletBinding()]
param(
    [ValidateSet('production', 't2')] [string[]] $Pack = @('production', 't2'),
    [string] $OutDir,
    [string] $GameDirectory,
    [string] $WolvenKitCli,
    [switch] $RefreshVanilla
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$kitRoot = $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $kitRoot '../../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')

$DataPath = Join-Path $kitRoot 'data/glass-2.50.json'
$Generator = Join-Path $kitRoot 'native/tint.cjs'
$Normalizer = Join-Path $repo 'scripts/vehicle-kit/archivexl/native/normalize-archive.cjs'   # sub-agent H's, used as is
$FixedZipTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$T2Mesh = 'base\vehicles\standard\v_standard2_thorton_colby\entities\meshes\v_standard2_thorton_colby__ext01_window_fl_01.mesh'
$Packs = [ordered]@{
    production = [ordered]@{ resource = 'open77_vehicle_tint'; lab = $false; select = $null }
    t2 = [ordered]@{ resource = 'open77_vehicle_tint_t2'; lab = $true; select = [ordered]@{ meshes = @($T2Mesh); sources = @('default'); levels = @(3) } }
}

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail([string] $text) { throw "vehicle-kit/windows: $text" }

function Get-EnvBothScopes([string] $name)
{
    foreach ($scope in 'Process', 'User') {
        $v = [Environment]::GetEnvironmentVariable($name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $null
}

function Invoke-Tool([string] $label, [string] $exe, [string[]] $arguments, [string] $marker)
{
    $output = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $errors = @($output | Where-Object { $_ -match '\[\s*\d+:\s*Error\s*\]|Error:|TINT_FAILED|AXL_ARCHIVE_FAILED' })
    foreach ($line in $output) {
        if ($line -match '^TINT_|^AXL_|\[\s*\d+:\s*(Error|Warning)\s*\]|Error') { Write-Host "   $line" }
    }
    if ($code -ne 0 -or $errors.Count -gt 0 -or ($marker -and -not ($output -match [regex]::Escape($marker)))) {
        $tail = ($output | Select-Object -Last 25) -join "`n"
        Fail "$label failed (exit $code).`n$tail"
    }
    return $output
}

function Wk([string] $label, [string[]] $arguments) { Invoke-Tool "WolvenKit $label" $script:Cli ($arguments + @('--verbosity', 'Minimal')) $null }

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

function Test-Bom([string] $path)
{
    $head = [IO.File]::ReadAllBytes($path)
    return ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
}

function Local-Path([string] $root, [string] $depot) { Join-Path $root ($depot -replace '\\', '/') }

function Invoke-Batched([string] $label, [string[]] $prefix, [string[]] $files, [string[]] $suffix)
{
    # One WolvenKit start per batch: a start costs more than a file.
    for ($i = 0; $i -lt $files.Count; $i += 20) {
        $batch = $files[$i..([Math]::Min($i + 19, $files.Count - 1))]
        Wk "$label $($batch.Count) files" (@($prefix) + @($batch) + @($suffix)) | Out-Null
    }
}

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

# The rules ResourceManifestParser.ParseDirectory and ResourcePreloadModResolver apply to a
# resource folder, restated for the generated skeleton (server/src/Open77.Resources/
# Manifests/ResourceManifestParser.cs, server/src/Open77.Server/Resources/
# ResourcePreloadModResolver.cs). A failure here means the server would refuse it.
function Test-ResourceSkeleton([string] $dir, [string] $name, [string] $zipName, [string[]] $zipEntries)
{
    if ($name -notmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { Fail "resource name $name is not a lowercase slug" }
    if ((Split-Path -Leaf $dir) -ne $name) { Fail "resource folder $(Split-Path -Leaf $dir) does not match the resource name $name" }
    $manifest = Join-Path $dir 'open77.lua'
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.lua')) { if (Test-Bom $f.FullName) { Fail "$($f.FullName) has a BOM: Lua files must not" } }
    $text = (Read-Text $manifest) -replace '(?m)--.*$', ''
    if ($text -notmatch "(?m)^\s*resource\s+'$([regex]::Escape($name))'\s*$") { Fail "open77.lua does not declare resource '$name'" }
    $scripts = @([regex]::Matches($text, "(?m)^\s*server_scripts?\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    if (-not $scripts.Count) { Fail 'open77.lua declares no script: the parser refuses a resource with no scripts or files' }
    foreach ($s in $scripts) { if (-not (Test-Path -LiteralPath (Join-Path $dir $s))) { Fail "server script $s is missing" } }
    $clientScripts = @([regex]::Matches($text, "(?m)^\s*client_scripts?\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    if (-not $clientScripts.Count) { Fail 'open77.lua declares no client script: clients would not see the pack running' }
    foreach ($s in $clientScripts) { if (-not (Test-Path -LiteralPath (Join-Path $dir $s))) { Fail "client script $s is missing" } }
    $preloads = @([regex]::Matches($text, "(?m)^\s*preload_mods?\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    if ($preloads.Count -ne 1 -or $preloads[0] -ne "dist/$zipName") { Fail "open77.lua preloads $($preloads -join ', '), expected dist/$zipName" }
    $zip = Join-Path $dir "dist/$zipName"
    $size = (Get-Item -LiteralPath $zip).Length
    if ($size -le 0 -or $size -gt 256MB) { Fail "preload ZIP is $size bytes; the resolver accepts 1..256 MiB" }
    foreach ($e in $zipEntries) {
        if ($e -notmatch '^archive/pc/mod/[a-z0-9_]+\.archive(\.xl)?$') { Fail "ZIP entry $e is outside archive/pc/mod or not an .archive/.xl (inert content only)" }
    }
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
if (-not $OutDir) { $OutDir = Join-Path $repo 'artifacts/vehicle-kit-tint' }
$script:OutRoot = [IO.Path]::GetFullPath($OutDir).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($script:OutRoot.StartsWith($GameDirectory, [StringComparison]::OrdinalIgnoreCase)) { Fail 'the output folder may not be inside the game directory' }
if ($script:OutRoot.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $script:OutRoot -eq $repo) {
    & git -C $repo check-ignore -q -- (Join-Path $script:OutRoot 'probe.archive')
    if ($LASTEXITCODE -ne 0) { Fail "output folder $script:OutRoot is inside the repository but not git-ignored" }
}
New-Item -ItemType Directory -Force -Path $script:OutRoot | Out-Null
if (-not (Test-Bom $PSCommandPath)) { Fail "$PSCommandPath lost its UTF-8 BOM (Windows PowerShell 5.1 would misread it)" }
if (Test-Bom $Generator) { Fail "$Generator has a BOM" }
Write-Host "   WolvenKit $wkVersion, node $nodeVersion, game $GameDirectory"
Write-Host "   output    $script:OutRoot"

$data = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json -AsHashtable
$plan0 = $data['packPlan']
$targets = @($plan0['perMesh'].Keys | Sort-Object)
$bases = @($plan0['materialInstances'] | ForEach-Object { $_['baseMaterial'] } | Sort-Object -Unique)

# --------------------------------------------------------------------------- 1. vanilla (cached, never shipped)
$vanillaDir = Join-Path $script:OutRoot 'vanilla'
$vanillaJsonDir = Join-Path $script:OutRoot 'vanilla-json'
if ($RefreshVanilla) { $vanillaDir = Reset-Dir $vanillaDir; $vanillaJsonDir = Reset-Dir $vanillaJsonDir }
New-Item -ItemType Directory -Force -Path $vanillaDir, $vanillaJsonDir | Out-Null
$depotPaths = @(@($targets) + @($bases) | Sort-Object -Unique)
$vanillaHashes = [ordered]@{}
$jsonOf = [ordered]@{}
# A base .mi is followed to its template: up to three rounds of read, serialize, look.
Step "vanilla resources: $($targets.Count) glass meshes + their base materials (read-only, cached)"
for ($round = 0; $round -lt 4; $round++) {
    foreach ($folder in 'archive\pc\content', 'archive\pc\ep1') {
        $still = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (Local-Path $vanillaDir $_)) })
        if (-not $still.Count) { break }
        $source = Join-Path $GameDirectory $folder
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $pattern = '^(' + (($still | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
        Wk "extract from $folder" @('extract', $source, '--regex', $pattern, '--outpath', $vanillaDir, '--gamepath', $GameDirectory) | Out-Null
    }
    $missing = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (Local-Path $vanillaDir $_)) })
    if ($missing.Count) { Fail "not found in the game archives: $($missing -join ', ')" }
    $dupes = @($depotPaths | Group-Object { ($_ -split '\\')[-1] } | Where-Object Count -gt 1)
    if ($dupes) { Fail "convert serialize flattens names; duplicate basenames: $($dupes.Name -join ', ')" }
    $stale = @()
    foreach ($p in $depotPaths) {
        $vanillaHashes[$p] = Sha256 (Local-Path $vanillaDir $p)
        $json = Join-Path $vanillaJsonDir "$(($p -split '\\')[-1]).json"
        $stamp = "$json.sha256"
        if (-not (Test-Path -LiteralPath $json) -or -not (Test-Path -LiteralPath $stamp) -or (Read-Text $stamp).Trim() -ne $vanillaHashes[$p]) { $stale += $p }
        $jsonOf[$p] = $json
    }
    Invoke-Batched 'serialize' @('convert', 'serialize') @($stale | ForEach-Object { Local-Path $vanillaDir $_ }) @('--outpath', $vanillaJsonDir)
    foreach ($p in $stale) {
        if (-not (Test-Path -LiteralPath $jsonOf[$p])) { Fail "serialize produced no $($jsonOf[$p])" }
        Write-Utf8NoBom "$($jsonOf[$p]).sha256" $vanillaHashes[$p]
    }
    $more = @(foreach ($p in $depotPaths) {
        if ($p -like '*.mi') {
            $b = (Get-Content -LiteralPath $jsonOf[$p] -Raw | ConvertFrom-Json).Data.RootChunk.baseMaterial.DepotPath.'$value'
            if ($b -and $depotPaths -notcontains $b) { $b }
        }
    })
    if (-not $more.Count) { break }
    if ($round -eq 3) { Fail "base material chain too deep: $($more -join ', ')" }
    $depotPaths = @(@($depotPaths) + @($more) | Sort-Object -Unique)
}
$vanillaFiles = @($depotPaths | ForEach-Object { Local-Path $vanillaDir $_ })
$vanillaSet = [Collections.Generic.HashSet[string]]::new()
foreach ($p in $depotPaths) { [void] $vanillaSet.Add($vanillaHashes[$p]) }
Write-Host "   $($targets.Count) glass meshes, $($depotPaths.Count - $targets.Count) materials/templates: $((@($depotPaths | Where-Object { $targets -notcontains $_ } | ForEach-Object { ($_ -split '\\')[-1] })) -join ', ')"

$digest = ((Invoke-Tool 'data digest' $node @($Generator, 'digest', $DataPath) 'TINT_DIGEST') | Where-Object { $_ -match '^TINT_DIGEST ' } | Select-Object -First 1) -replace '^TINT_DIGEST ', ''

# --------------------------------------------------------------------------- 2. per pack
$results = [ordered]@{}
foreach ($packName in $Pack) {
    $def = $Packs[$packName]
    $resource = $def.resource
    $root = Join-Path $script:OutRoot $packName
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $add = { param($text) $hasher.AppendData([Text.Encoding]::UTF8.GetBytes([string] $text + "`n")) }
    & $add "pack=$packName resource=$resource"
    & $add "data=$digest"
    foreach ($f in @(Get-Item -LiteralPath $Generator) + @(Get-Item -LiteralPath $PSCommandPath) + @(Get-Item -LiteralPath $Normalizer)) {
        & $add $f.Name; & $add (Read-Text $f.FullName)
    }
    & $add $wkVersion
    $revision = ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
    $rev12 = $revision.Substring(0, 12)
    $prefix = "open77\assets\$resource\$rev12"
    Step "$packName`: revision $rev12 -> $prefix$(if ($def.lab) { '  (LAB ONLY)' })"

    $work = Join-Path $root 'work'
    $genDir = Reset-Dir (Join-Path $work 'generated')
    $genJsonDir = Join-Path $genDir 'json'
    $plan = [ordered]@{
        data = $DataPath; pack = $packName; resource = $resource; prefix = $prefix; outDir = $genJsonDir; reportDir = $genDir
        vanillaJson = $jsonOf; vanillaFiles = $vanillaFiles
    }
    if ($def.select) { $plan.select = $def.select }
    $planFile = Join-Path $genDir 'plan.json'
    Write-Utf8NoBom $planFile ($plan | ConvertTo-Json -Depth 8)
    Invoke-Tool 'generate' $node @($Generator, 'generate', $planFile) 'TINT_GENERATED' | Out-Null
    $report = Get-Content -LiteralPath (Join-Path $genDir 'generated.json') -Raw | ConvertFrom-Json
    $expected = @($report.files | Sort-Object)
    foreach ($f in $expected) { if (-not $f.StartsWith("$prefix\")) { Fail "generated file $f is outside $prefix" } }

    $stageDir = Reset-Dir (Join-Path $work 'stage')
    foreach ($sub in 'materials', 'windows') {
        $into = Join-Path $stageDir "$prefix\$sub"
        New-Item -ItemType Directory -Force -Path $into | Out-Null
        $jsonFiles = @(Get-ChildItem -LiteralPath (Join-Path $genJsonDir $sub) -Filter '*.json' -File | Sort-Object Name | ForEach-Object FullName)
        Invoke-Batched "deserialize $sub" @('convert', 'deserialize') $jsonFiles @('--outpath', $into)
    }
    $staged = @(Get-ChildItem -LiteralPath $stageDir -Recurse -File | ForEach-Object { $_.FullName.Substring($stageDir.Length + 1) } | Sort-Object)
    if (Compare-Object $staged $expected) { Fail "staged files differ from the generated list:`n$(Compare-Object $staged $expected | Out-String)" }
    $roundtripDir = Reset-Dir (Join-Path $work 'roundtrip')
    Wk 'round trip serialize' @('convert', 'serialize', $stageDir, '--outpath', $roundtripDir) | Out-Null
    $roundtrip = Invoke-Tool 'round trip check' $node @($Generator, 'validate', $planFile, $roundtripDir) 'TINT_ROUNDTRIP_OK'
    $scan = Invoke-Tool 'no-vanilla-bytes scan' $node @($Generator, 'scan', $planFile, $stageDir) 'TINT_SCAN_OK'

    Step "$packName`: pack and verify the archive"
    $packedDir = Reset-Dir (Join-Path $work 'packed')
    Wk 'pack' @('pack', $stageDir, '--outpath', $packedDir) | Out-Null
    $packed = Join-Path $packedDir 'stage.archive'
    if (-not (Test-Path -LiteralPath $packed)) { Fail "pack produced no $packed" }
    $archive = Join-Path $packedDir "$resource.archive"
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
    if ($vanillaSet.Contains((Sha256 $archive))) { Fail 'the archive is byte-identical to a vanilla file' }

    # ArchiveXL (fork open77/1.28, ResourcePatch OnMeshResourceLoad) clones each patch
    # appearance into the target mesh. A chunk material name the target lacks
    # (open77_tint*) resolves from the patch mesh's own entries; a name it has keeps the
    # target's material.
    $xl = [Text.StringBuilder]::new()
    [void] $xl.AppendLine("# Open77 window tint pack $resource, revision $rev12.$(if ($def.lab) { ' LAB ONLY: never install on a public server.' })")
    [void] $xl.AppendLine('# Generated by scripts/vehicle-kit/windows/build-tint.ps1. Each patch mesh holds only appearances')
    [void] $xl.AppendLine('# open77_tint<level>__<source>, chunk material names, and Open77 material instances.')
    [void] $xl.AppendLine('resource:')
    [void] $xl.AppendLine('  patch:')
    foreach ($m in @($report.meshes | Sort-Object patch)) {
        [void] $xl.AppendLine("    $($m.patch):")
        [void] $xl.AppendLine('      props: [ appearances ]')
        [void] $xl.AppendLine("      targets: [ $($m.target) ]")
    }
    $xlName = "$resource.archive.xl"
    $xlPath = Join-Path $packedDir $xlName
    Write-Utf8NoBom $xlPath $xl.ToString()

    Step "$packName`: preload_mod ZIP and server resource"
    $resourceDir = Reset-Dir (Join-Path $root "resource/$resource")
    $zipName = "$($resource)_$rev12.zip"
    $zipPath = Join-Path $resourceDir "dist/$zipName"
    $zipLayout = [ordered]@{ "archive/pc/mod/$resource.archive" = $archive; "archive/pc/mod/$xlName" = $xlPath }
    Write-DeterministicZip $zipPath $zipLayout
    $zipHashes = Get-ZipEntryHashes $zipPath
    if (Compare-Object @($zipHashes.Keys) @($zipLayout.Keys)) { Fail "ZIP layout is wrong: $($zipHashes.Keys -join ', ')" }
    foreach ($name in $zipHashes.Keys) {
        if ($zipHashes[$name] -ne (Sha256 $zipLayout[$name])) { Fail "ZIP entry $name does not hold the built file" }
        if ($vanillaSet.Contains($zipHashes[$name])) { Fail "ZIP entry $name is byte-identical to a vanilla file" }
    }
    if ($vanillaSet.Contains((Sha256 $zipPath))) { Fail 'the ZIP is byte-identical to a vanilla file' }

    if ($def.lab) {
        $head = @(
            "-- Open77 window tint T2 lab pack (route 2): ONE patch mesh, Colby window_fl, appearance"
            "-- open77_tint3__default. LAB ONLY: never start it on a public server, never together with"
            "-- open77_vehicle_tint (both patch the same mesh). Generated by"
            "-- scripts/vehicle-kit/windows/build-tint.ps1 (revision $rev12)."
        )
        $autoStart = 'auto_start false'
    } else {
        $head = @(
            "-- Open77 window tint pack (route 2): $($report.counts.meshes) glass meshes gain the appearances"
            "-- open77_tint<level>__<source mesh appearance>, levels 1-3. Generated by"
            "-- scripts/vehicle-kit/windows/build-tint.ps1 (revision $rev12); do not edit by hand."
        )
        $autoStart = $null
    }
    $lua = @($head) + @(
        "-- The preload_mod is the whole resource. server.lua is a no-op because the manifest parser"
        "-- refuses a resource with no script or files; client.lua is a no-op so that the resource"
        "-- runs on each client too, and GetResourceState('$resource') there reads 'running'"
        "-- (a gamemode greys its tint menu otherwise, as for the body and rim packs)."
        "resource '$resource'"
        "version '0.1.0'"
    ) + @(if ($autoStart) { $autoStart }) + @(
        "reload_policy 'reconnect'"
        "server_script 'server.lua'"
        "client_script 'client.lua'"
        "preload_mod 'dist/$zipName'"
    )
    Write-Utf8NoBom (Join-Path $resourceDir 'open77.lua') ($lua -join "`n")
    Write-Utf8NoBom (Join-Path $resourceDir 'server.lua') @"
-- $resource (revision $rev12): no-op. This resource only ships its preload_mod ZIP
-- (archive/pc/mod/$resource.archive + .archive.xl), mounted by the launcher before the game
-- starts. The client switches each glass component to open77_tint<level>__<appearance>.
"@
    Write-Utf8NoBom (Join-Path $resourceDir 'client.lua') @"
-- $resource (revision $rev12): no-op. Running it makes GetResourceState('$resource') read
-- 'running' on this client, which is how a gamemode tells that the tint pack came with the
-- server's resources. The glass itself is switched by the Open77 client, not by Lua.
"@
    Test-ResourceSkeleton $resourceDir $resource $zipName @($zipHashes.Keys)

    $manifest = [ordered]@{
        schema = 'open77.vehicle-kit.tint-build/1'
        pack = $packName
        lab = $def.lab
        resource = $resource
        revision = $revision
        prefix = $prefix
        inputs = [ordered]@{ dataDigest = $digest; generator = (Sha256 $Generator); script = (Sha256 $PSCommandPath); normalizer = (Sha256 $Normalizer); wolvenkit = $wkVersion }
        tools = [ordered]@{ wolvenkit = $wkVersion; node = $nodeVersion }
        counts = $report.counts
        vanillaRead = $vanillaHashes
        vanillaChecks = $report.vanillaChecks
        checks = [ordered]@{
            roundTrip = (@($roundtrip | Where-Object { $_ -match '^TINT_ROUNDTRIP_OK' }) | Select-Object -First 1)
            scan = (@($scan | Where-Object { $_ -match '^TINT_SCAN_OK' }) | Select-Object -First 1)
            hashes = 'no staged file, archive entry, archive, ZIP entry or ZIP equals a vanilla file read by the build'
            archive = 'list = staged files; extracted bytes = staged bytes'
            resource = 'open77.lua + server.lua + client.lua + dist/<zip> pass the ResourceManifestParser / preload resolver rules'
        }
        files = $receipts
        archive = [ordered]@{ path = $archive; sha256 = (Sha256 $archive); bytes = (Get-Item -LiteralPath $archive).Length; entries = $entries }
        xl = [ordered]@{ path = $xlPath; sha256 = (Sha256 $xlPath) }
        zip = [ordered]@{ path = $zipPath; sha256 = (Sha256 $zipPath); bytes = (Get-Item -LiteralPath $zipPath).Length; entries = $zipHashes }
        resourceDir = $resourceDir
    }
    Write-Utf8NoBom (Join-Path $root 'manifest.json') ($manifest | ConvertTo-Json -Depth 16)
    Write-Utf8NoBom (Join-Path $root 'SHA256SUMS') (@("$($manifest.archive.sha256)  $resource.archive", "$($manifest.xl.sha256)  $xlName", "$($manifest.zip.sha256)  $zipName") -join "`n")
    $results[$packName] = $manifest
    Write-Host "   archive $($manifest.archive.sha256)  $($manifest.archive.bytes) bytes"
    Write-Host "   zip     $($manifest.zip.sha256)  $($manifest.zip.bytes) bytes  $zipPath"
}

Step 'Done'
foreach ($key in $results.Keys) {
    $m = $results[$key]
    Write-Host ("TINT_PACK_OK {0} revision={1} meshes={2} appearances={3} materials={4} archive={5} zip={6}" -f $key, $m.revision.Substring(0, 12), $m.counts.meshes, $m.counts.appearances, $m.counts.materials, $m.archive.sha256, $m.zip.sha256)
}
