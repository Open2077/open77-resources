#requires -Version 7.0
<#
.SYNOPSIS
    Builds an Open77 vehicle-kit preload_mod pack, end to end, from a JSON spec of parts.

.DESCRIPTION
    Original geometry by script in Blender -> glb -> WolvenKit import onto a template
    .mesh -> native cook (materials, LOD table, appearances, visual hosts) -> round trip
    check -> .archive -> deterministic preload_mod ZIP -> owner-review renders, plus a
    ready-to-copy asset resource and an E0.9 test resource.

    Never touches the game folder (read-only template extraction), never launches the
    game, never deploys. The output folder must be git-ignored: the work tree holds
    vanilla template files and the outputs are generated binaries.

    Same spec + same scripts + same tool versions = same revision, so the depot paths
    (open77\assets\<resource>\<revision12>\...) and the ZIP name are stable across reruns.
    Every rerun rebuilds its own work folders; only the extracted game templates are cached.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/build-pack.ps1
    pwsh -File scripts/vehicle-kit/build-pack.ps1 -Spec my-kit.json -OutDir D:\kits\my-kit -SkipPreview
    pwsh -File scripts/vehicle-kit/build-pack.ps1 -InstallAddon      # fetch the pinned Cyberpunk add-on first
#>
[CmdletBinding()]
param(
    [string] $Spec = (Join-Path $PSScriptRoot 'parts.example.json'),
    [string] $OutDir,
    [string] $GameDirectory,
    [string] $Blender,
    [string] $BlenderScripts,
    [string] $WolvenKitCli,
    [ValidateSet('auto', 'cp77', 'gltf')] [string] $Exporter = 'auto',
    [switch] $InstallAddon,
    [switch] $SkipPreview,
    [ValidateSet(1, 4)] [int] $PreviewViews = 4,
    [int] $PreviewSamples = 48,
    [switch] $DeepCollisionCheck,
    [switch] $AllowAnyBlender
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$kitRoot = $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $kitRoot '../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')

# Pinned Cyberpunk IO Suite: 1.8.0 is the last release declaring Blender 4.5 (2.0.0 needs 5.0).
$AddonVersion = '1.8.0'
$AddonUrl = "https://github.com/WolvenKit/Cyberpunk-Blender-add-on/releases/download/$AddonVersion/Cyberpunk.Blender.Plugin-$AddonVersion.zip"
$AddonSha256 = '80538cf42eb17f266267dc7fb19f15f891d3cb6c5765b7e228ee4d95cf5564ef'
$MaxZipBytes = 64MB          # Warden upload ceiling; preload_mod itself allows 256 MiB
$Generators = @{ rim = 'make_rim.py'; spoiler = 'make_spoiler.py'; lip = 'make_lip.py'; skirt = 'make_skirt.py'; roofrack = 'make_roofrack.py'; bullbar = 'make_bullbar.py'
                 louver = 'make_louver.py'; canard = 'make_canard.py'; diffuser = 'make_diffuser.py'; hood = 'make_hood.py' }

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail([string] $text) { throw "vehicle-kit: $text" }

function Get-EnvBothScopes([string] $name)
{
    foreach ($scope in 'Process', 'User') {
        $v = [Environment]::GetEnvironmentVariable($name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $null
}

function Resolve-Blender
{
    $tried = [Collections.Generic.List[string]]::new()
    $candidates = @()
    if ($Blender) { $candidates += , @('argument', $Blender) }
    $fromEnv = Get-EnvBothScopes 'OP77_BLENDER'
    if ($fromEnv) { $candidates += , @('env OP77_BLENDER', $fromEnv) }
    $candidates += , @('Open77 tools', (Join-Path $env:LOCALAPPDATA 'Open77\blender\blender.exe'))
    foreach ($dir in @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Sanstour\tools\blender-portable') -Directory -ErrorAction SilentlyContinue)) {
        $candidates += , @('portable', (Join-Path $dir.FullName 'blender.exe'))
    }
    foreach ($dir in @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Blender Foundation') -Directory -ErrorAction SilentlyContinue)) {
        $candidates += , @('installed', (Join-Path $dir.FullName 'blender.exe'))
    }
    foreach ($c in $candidates) {
        $tried.Add(('  {0,-18} {1}' -f $c[0], $c[1]))
        if (Test-Path -LiteralPath $c[1] -PathType Leaf) {
            if ($Blender -and $c[0] -ne 'argument') { break }
            return (Resolve-Path -LiteralPath $c[1]).Path
        }
        if ($c[0] -eq 'argument') { Fail "Blender not found at -Blender $Blender" }
    }
    $cmd = Get-Command blender -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Fail ("Blender 4.5 not found. Looked in:`n" + ($tried -join "`n") + "`nPass -Blender <blender.exe> or set OP77_BLENDER.")
}

function Invoke-Tool([string] $label, [string] $exe, [string[]] $arguments, [string] $marker)
{
    $output = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $errors = @($output | Where-Object { $_ -match '\[\s*\d+:\s*Error\s*\]|^Traceback|Error:|VK_[A-Z_]*FAILED|VK_ADDON_ENABLE_FAILED' })
    foreach ($line in $output) {
        if ($line -match '^VK_|\[\s*\d+:\s*(Error|Warning)\s*\]|^Traceback|^\s+File "|Error' ) { Write-Host "   $line" }
    }
    if ($code -ne 0 -or $errors.Count -gt 0 -or ($marker -and -not ($output -match [regex]::Escape($marker)))) {
        $tail = ($output | Select-Object -Last 25) -join "`n"
        Fail "$label failed (exit $code).`n$tail"
    }
    return $output
}

function Wk([string] $label, [string[]] $arguments) { Invoke-Tool "WolvenKit $label" $script:Cli ($arguments + @('--verbosity', 'Minimal')) $null }

function Invoke-Blender([string] $label, [string] $script, [string[]] $arguments, [string] $marker)
{
    $full = @('--background', '--factory-startup', '--python-exit-code', '1', '--python', (Join-Path $kitRoot "blender/$script"), '--') + $arguments
    Invoke-Tool "Blender $label" $script:BlenderExe $full $marker
}

function Reset-Dir([string] $path)
{
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($script:OutRoot + [IO.Path]::DirectorySeparatorChar)) { Fail "refusing to clear $full (outside $script:OutRoot)" }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $full | Out-Null
    return $full
}

function Sha256([string] $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Write-Utf8NoBom([string] $path, [string] $text)
{
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $text = $text -replace "`r`n", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

# --------------------------------------------------------------------------- 0. inputs
Step 'Resolving inputs and tools'
$SpecPath = (Resolve-Path -LiteralPath $Spec).Path
$kit = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json -AsHashtable
if ($kit.schema -ne 'open77.vehicle-kit/1') { Fail "spec schema must be open77.vehicle-kit/1 ($SpecPath)" }
if ($kit.resource -notmatch '^[a-z0-9_-]{1,64}$') { Fail "resource '$($kit.resource)' must match [a-z0-9_-]{1,64} (registerModel owner rule)" }
if ($kit.archiveName -notmatch '^[A-Za-z0-9_]{3,64}$') { Fail "archiveName '$($kit.archiveName)' must match [A-Za-z0-9_]{3,64}" }
if ($kit.archiveName -match '^Open77(Mirror|RP)?$') { Fail "archiveName '$($kit.archiveName)' collides with a platform archive name" }
$palette = $kit.palette
if (-not $palette -or $palette.Count -eq 0) { Fail 'spec palette is empty' }
foreach ($name in $palette.Keys) {
    if ($name -notmatch '^[a-z0-9_]{1,40}$') { Fail "palette name '$name' must match [a-z0-9_]{1,40}" }
    $m = $palette[$name]
    if (@($m.color).Count -ne 3 -or $null -eq $m.metalness -or $null -eq $m.roughness) { Fail "palette '$name' needs color[3], metalness, roughness" }
    # metal_base.remt declares MetalnessScale and RoughnessScale with min 0, max 1.
    foreach ($v in @($m.color) + @($m.metalness, $m.roughness)) {
        if ([double] $v -lt 0 -or [double] $v -gt 1) { Fail "palette '$name': color, metalness and roughness must lie in 0..1 (got $v)" }
    }
}
$native = if ($kit.ContainsKey('native')) { $kit.native } else { @{} }
$autoHide = if ($native.ContainsKey('autoHideDistance')) { [double] $native.autoHideDistance } else { 150.0 }
# One LOD by default, like every custom mesh proven visible in game (the generators
# export one LOD unless the part's params list more).
$lodDefaults = @{ rim = @(0); spoiler = @(0) }
if ($native.ContainsKey('lodDistances')) { foreach ($k in $native.lodDistances.Keys) { $lodDefaults[$k] = @($native.lodDistances[$k]) } }
$seen = @{}
foreach ($part in $kit.parts) {
    if ($part.id -notmatch '^[a-z0-9_]{1,40}$') { Fail "part id '$($part.id)' must match [a-z0-9_]{1,40}" }
    if ($seen.ContainsKey($part.id)) { Fail "duplicate part id $($part.id)" }
    $seen[$part.id] = $true
    if (-not $Generators.ContainsKey($part.kind)) { Fail "part $($part.id): unknown kind '$($part.kind)' (known: $($Generators.Keys -join ', '))" }
    if (-not $part.finishes -or $part.finishes.Count -eq 0) { Fail "part $($part.id) has no finishes" }
    foreach ($f in $part.finishes.Keys) {
        if ($f -notmatch '^[a-z0-9_]{1,20}$' -or $f -eq 'default') { Fail "part $($part.id): finish '$f' must match [a-z0-9_]{1,20} and not be 'default'" }
        foreach ($slot in $part.finishes[$f].Keys) {
            $mat = $part.finishes[$f][$slot]
            if (-not $palette.ContainsKey($mat)) { Fail "part $($part.id)/$f slot ${slot}: '$mat' is not in the palette" }
        }
    }
}
if ($kit.parts.Count -eq 0) { Fail 'spec has no parts' }

$node = (Get-Command node -ErrorAction SilentlyContinue)?.Source
if (-not $node) { Fail 'node (Node.js 18+) not found on PATH' }
$script:Cli = Find-WolvenKitCli -Explicit $WolvenKitCli
$wkVersion = ((& $script:Cli --version) 2>&1 | Select-Object -First 1).ToString().Trim()
$script:BlenderExe = Resolve-Blender
$blenderVersion = ((& $script:BlenderExe --factory-startup --version) 2>&1 | Where-Object { $_ -match '^Blender \d' } | Select-Object -First 1)
if (-not $blenderVersion) { Fail "could not read the Blender version from $script:BlenderExe" }
$blenderVersion = $blenderVersion.ToString().Trim()
if (-not $AllowAnyBlender -and $blenderVersion -notmatch '^Blender 4\.5\.') { Fail "$blenderVersion found; the pipeline and add-on $AddonVersion are proven on Blender 4.5 (-AllowAnyBlender to override)" }

if (-not $GameDirectory) { $GameDirectory = Get-EnvBothScopes 'OP77_GAME_DIR' }
if (-not $GameDirectory -or -not (Test-Path -LiteralPath (Join-Path $GameDirectory 'archive\pc\content'))) {
    Fail "game directory not found (got '$GameDirectory'). Pass -GameDirectory or set OP77_GAME_DIR; it is only read, for two template files."
}

if (-not $BlenderScripts) { $BlenderScripts = Get-EnvBothScopes 'OP77_BLENDER_SCRIPTS' }
if (-not $BlenderScripts) { $BlenderScripts = Join-Path $env:LOCALAPPDATA 'Open77\blender-scripts' }
$addonInit = Join-Path $BlenderScripts 'addons\i_scene_cp77_gltf\__init__.py'
if ($InstallAddon) {
    Step "Installing Cyberpunk IO Suite $AddonVersion into $BlenderScripts"
    $dl = Join-Path ([IO.Path]::GetTempPath()) "open77-cp77-addon-$AddonVersion.zip"
    Invoke-WebRequest -Uri $AddonUrl -OutFile $dl -UseBasicParsing
    if ((Sha256 $dl) -ne $AddonSha256) { Fail "add-on download hash mismatch ($dl)" }
    $addons = Join-Path $BlenderScripts 'addons'
    if (Test-Path -LiteralPath (Join-Path $addons 'i_scene_cp77_gltf')) { Remove-Item -LiteralPath (Join-Path $addons 'i_scene_cp77_gltf') -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $addons | Out-Null
    Expand-Archive -LiteralPath $dl -DestinationPath $addons -Force
}
$addonVersionFound = $null
if (Test-Path -LiteralPath $addonInit) {
    $m = [regex]::Match((Get-Content -LiteralPath $addonInit -Raw), '"version":\s*\((\d+),\s*(\d+),\s*(\d+)\)')
    if ($m.Success) { $addonVersionFound = "$($m.Groups[1]).$($m.Groups[2]).$($m.Groups[3])" }
}
if ($Exporter -eq 'cp77' -and -not $addonVersionFound) { Fail "-Exporter cp77 needs the add-on in $BlenderScripts (run with -InstallAddon)" }
if ($Exporter -eq 'auto' -and -not $addonVersionFound) {
    Write-Warning "Cyberpunk add-on not found in ${BlenderScripts}: exporting with the stock glTF exporter (no add-on mesh validation). Run with -InstallAddon to fix."
}

# Output folder: default under the repo's ignored artifacts/, and always git-ignored.
if (-not $OutDir) { $OutDir = Join-Path $repo "artifacts/vehicle-kit/$($kit.resource)" }
$script:OutRoot = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $script:OutRoot | Out-Null
if ($script:OutRoot.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    & git -C $repo check-ignore -q -- (Join-Path $script:OutRoot 'probe.archive')
    if ($LASTEXITCODE -ne 0) { Fail "output folder $script:OutRoot is inside the repository but not git-ignored" }
}

# --------------------------------------------------------------------------- 1. templates (cached)
Step 'Game templates (read-only, cached, never shipped)'
$tplDir = Join-Path $script:OutRoot 'work/templates'
$tplMesh = Join-Path $tplDir 'base/environment/ld_kit/box_1m_1m_1m_grey.w2mesh'
$tplEnt = Join-Path $tplDir 'base/gameplay/debug/debuginteraction.ent'
$tplEntJson = Join-Path $tplDir 'debuginteraction.ent.json'
if (-not (Test-Path -LiteralPath $tplMesh) -or -not (Test-Path -LiteralPath $tplEnt)) {
    New-Item -ItemType Directory -Force -Path $tplDir | Out-Null
    Wk 'extract templates' @('extract', (Join-Path $GameDirectory 'archive\pc\content'), '--regex',
        '^(base\\gameplay\\debug\\debuginteraction\.ent|base\\environment\\ld_kit\\box_1m_1m_1m_grey\.w2mesh)$',
        '--outpath', $tplDir, '--gamepath', $GameDirectory) | Out-Null
}
if (-not (Test-Path -LiteralPath $tplMesh) -or -not (Test-Path -LiteralPath $tplEnt)) { Fail 'template extraction produced no files' }
if (-not (Test-Path -LiteralPath $tplEntJson)) {
    Wk 'serialize host template' @('convert', 'serialize', $tplEnt, '--outpath', $tplDir) | Out-Null
}
$templateHashes = [ordered]@{ 'base\environment\ld_kit\box_1m_1m_1m_grey.w2mesh' = (Sha256 $tplMesh); 'base\gameplay\debug\debuginteraction.ent' = (Sha256 $tplEnt) }
Write-Host "   mesh container template  $($templateHashes[0])"
Write-Host "   visual host template     $($templateHashes[1])"

# --------------------------------------------------------------------------- 2. revision
$pipelineFiles = @(Get-ChildItem -LiteralPath (Join-Path $kitRoot 'blender') -Filter '*.py' -File) +
                 @(Get-ChildItem -LiteralPath (Join-Path $kitRoot 'native') -Filter '*.cjs' -File) +
                 @(Get-Item -LiteralPath $PSCommandPath)
$hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
$add = { param($text) $hasher.AppendData([Text.Encoding]::UTF8.GetBytes([string] $text + "`n")) }
& $add ($kit | ConvertTo-Json -Depth 64 -Compress)
foreach ($f in ($pipelineFiles | Sort-Object Name)) { & $add $f.Name; & $add ((Get-Content -LiteralPath $f.FullName -Raw) -replace "`r`n", "`n") }
& $add "$blenderVersion|addon:$addonVersionFound|exporter:$Exporter|$wkVersion"
foreach ($h in $templateHashes.Values) { & $add $h }
$revision = ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
$rev12 = $revision.Substring(0, 12)
$prefix = "open77\assets\$($kit.resource)\$rev12"
Write-Host "   revision $revision  ->  $prefix"

# --------------------------------------------------------------------------- 3. Blender parts
$work = Join-Path $script:OutRoot 'work'
$partsDir = Reset-Dir (Join-Path $work 'parts')
$importDir = Reset-Dir (Join-Path $work 'imported')
$importJsonDir = Reset-Dir (Join-Path $work 'imported-json')
$saved = @{}
foreach ($n in 'BLENDER_USER_SCRIPTS', 'BLENDER_USER_CONFIG', 'BLENDER_USER_EXTENSIONS', 'BLENDER_USER_DATAFILES') { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
try {
    # Process-scoped only: Blender reads the add-on from our folder and writes no
    # preference, recent-file or extension state into the shared Blender install.
    $isolated = Join-Path $env:LOCALAPPDATA 'Open77\blender-user'
    $env:BLENDER_USER_SCRIPTS = $BlenderScripts
    $env:BLENDER_USER_CONFIG = Join-Path $isolated 'config'
    $env:BLENDER_USER_EXTENSIONS = Join-Path $isolated 'extensions'
    $env:BLENDER_USER_DATAFILES = Join-Path $isolated 'datafiles'
    $planParts = @()
    foreach ($part in $kit.parts) {
        Step "Part $($part.id) ($($part.kind))"
        $resolved = [ordered]@{
            id = $part.id; kind = $part.kind; label = $part.label; params = $part.params
            finishes = $part.finishes; palette = $palette
        }
        $partJson = Join-Path $partsDir "$($part.id).spec.json"
        Write-Utf8NoBom $partJson ($resolved | ConvertTo-Json -Depth 32)
        $partOut = Join-Path $partsDir $part.id
        Invoke-Blender $part.id $Generators[$part.kind] @('--part', $partJson, '--out', $partOut, '--exporter', $Exporter) "VK_PART_OK $($part.id)" | Out-Null
        $glb = Join-Path $partOut "$($part.id).glb"
        $meta = Join-Path $partOut "$($part.id).part.json"
        Copy-Item -LiteralPath $tplMesh -Destination (Join-Path $importDir "$($part.id).mesh") -Force
        Wk "import $($part.id)" @('import', $glb, '--outpath', $importDir, '--keep') | Out-Null
        Wk "serialize $($part.id)" @('convert', 'serialize', (Join-Path $importDir "$($part.id).mesh"), '--outpath', $importJsonDir) | Out-Null
        # @(...) around the if: a one-entry array leaving an if statement unrolls to a scalar.
        $lods = @(if ($part.ContainsKey('lodDistances')) { $part.lodDistances } else { $lodDefaults[$part.kind] })
        $planParts += [ordered]@{ id = $part.id; kind = $part.kind; label = $part.label; finishes = $part.finishes; lodDistances = $lods
                                 meta = $meta; glb = $glb; spec = $partJson; importedJson = (Join-Path $importJsonDir "$($part.id).mesh.json") }
    }

    # ----------------------------------------------------------------------- 4. native cook
    Step 'Native cook (local materials, LOD table, one mesh and visual host per model)'
    $preparedDir = Reset-Dir (Join-Path $work 'prepared')
    $stageDir = Reset-Dir (Join-Path $work 'stage')
    $roundtripDir = Reset-Dir (Join-Path $work 'roundtrip')
    $packageWork = Join-Path $work 'package.json'
    $plan = [ordered]@{
        resource = $kit.resource; revision = $revision; prefix = $prefix; palette = $palette; autoHideDistance = $autoHide
        templates = @{ entity = $tplEntJson }; preparedDir = $preparedDir; stageDir = $stageDir; roundtripDir = $roundtripDir; packageOut = $packageWork
        parts = $planParts
    }
    $planPath = Join-Path $work 'plan.json'
    Write-Utf8NoBom $planPath ($plan | ConvertTo-Json -Depth 32)
    Invoke-Tool 'cook prepare' $node @((Join-Path $kitRoot 'native/cook.cjs'), 'prepare', $planPath) 'VK_COOK_PREPARED' | Out-Null
    $package = Get-Content -LiteralPath $packageWork -Raw | ConvertFrom-Json -AsHashtable

    # WolvenKit flattens folders on deserialize: one call per depot directory, in batches
    # so the command line stays under the Windows limit of 32 767 characters (a rim pack
    # puts 216 files in one folder; from a worktree's artifacts path one call overflows).
    $groups = Get-ChildItem -LiteralPath $preparedDir -Recurse -File -Filter '*.json' | Group-Object DirectoryName
    $commandBudget = 24000
    foreach ($g in $groups) {
        $relative = [IO.Path]::GetRelativePath($preparedDir, $g.Name)
        $target = Join-Path $stageDir $relative
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $batch = [Collections.Generic.List[string]]::new()
        $length = 0
        $files = @($g.Group.FullName)
        for ($i = 0; $i -lt $files.Count; $i++) {
            $batch.Add($files[$i])
            $length += $files[$i].Length + 3
            if ($length -ge $commandBudget -or $i -eq $files.Count - 1) {
                Wk "deserialize $relative ($($batch.Count) files)" (@('convert', 'deserialize') + $batch.ToArray() + @('--outpath', $target)) | Out-Null
                $batch.Clear()
                $length = 0
            }
        }
    }
    $staged = @(Get-ChildItem -LiteralPath $stageDir -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($stageDir, $_.FullName).Replace('/', '\') } | Sort-Object)
    $expected = @($package.files | Sort-Object)
    if (Compare-Object $staged $expected) { Fail "staged files differ from the cooked file list:`n$(Compare-Object $staged $expected | Out-String)" }
    Wk 'round trip serialize' @('convert', 'serialize', $stageDir, '--outpath', $roundtripDir) | Out-Null
    Invoke-Tool 'cook validate' $node @((Join-Path $kitRoot 'native/cook.cjs'), 'validate', $planPath) 'VK_COOK_ROUNDTRIP_OK' | Out-Null

    # ----------------------------------------------------------------------- 5. archive
    Step 'Pack and verify the archive'
    $packedDir = Reset-Dir (Join-Path $work 'packed')
    Wk 'pack' @('pack', $stageDir, '--outpath', $packedDir) | Out-Null
    # CLI pack has no --modname: it names the archive after the staging folder.
    $packed = Join-Path $packedDir 'stage.archive'
    if (-not (Test-Path -LiteralPath $packed)) { Fail "pack produced no $packed" }
    $archive = Join-Path $packedDir "$($kit.archiveName).archive"
    Move-Item -LiteralPath $packed -Destination $archive -Force
    # pack stamps each entry with the time of the pack: pin it so a rerun is byte-identical.
    Invoke-Tool 'normalize archive' $node @((Join-Path $kitRoot 'native/normalize-archive.cjs'), $archive) 'VK_ARCHIVE_NORMALIZED' | Out-Null
    $listing = Wk 'list archive' @('archive', $archive, '--list')
    $entries = @($listing | Where-Object { $_ -match '^[A-Za-z0-9_]+\\' } | ForEach-Object { $_.Trim() } | Sort-Object)
    if ($entries.Count -ne $expected.Count) { Fail "archive lists $($entries.Count) entries, $($expected.Count) staged (unresolved hash or extra file):`n$($listing -join "`n")" }
    if (Compare-Object $entries $expected) { Fail "archive entries differ from the staged files:`n$(Compare-Object $entries $expected | Out-String)" }
    $foreign = @($entries | Where-Object { -not $_.StartsWith("$prefix\") })
    if ($foreign.Count) { Fail "archive carries paths outside ${prefix}: $($foreign -join ', ')" }
    $verifyDir = Reset-Dir (Join-Path $work 'verify')
    Wk 'extract for byte check' @('extract', $archive, '--outpath', $verifyDir) | Out-Null
    $receipts = @()
    foreach ($rel in $expected) {
        $a = Join-Path $stageDir $rel; $b = Join-Path $verifyDir $rel
        if (-not (Test-Path -LiteralPath $b)) { Fail "archive lost $rel" }
        $h = Sha256 $a
        if ((Sha256 $b) -ne $h) { Fail "archive changed the bytes of $rel" }
        $receipts += [ordered]@{ path = $rel.Replace('\', '/'); sha256 = $h; bytes = (Get-Item -LiteralPath $a).Length }
    }
    if ($DeepCollisionCheck) {
        Step 'Deep collision check against the game archives'
        foreach ($folder in 'archive\pc\content', 'archive\pc\ep1') {
            $p = Join-Path $GameDirectory $folder
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $hits = @(Wk "scan $folder" @('archive', $p, '--list', '--regex', '^open77\\') | Where-Object { $_ -match '^open77\\' })
            if ($hits.Count) { Fail "the game's $folder already holds open77\ paths: $($hits -join ', ')" }
        }
        Write-Host '   no game archive holds an open77\ path'
    }

    # ----------------------------------------------------------------------- 6. preload_mod ZIP
    Step 'preload_mod ZIP'
    $resourceDir = Join-Path $script:OutRoot "resource/$($kit.resource)"
    $null = Reset-Dir $resourceDir
    $zipName = "$($kit.archiveName)_$rev12.zip"
    $zipPath = Join-Path $resourceDir "dist/$zipName"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zipPath) | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    $entryName = "archive/pc/mod/$($kit.archiveName).archive"
    $fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    try {
        $zip = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
        $entry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        # A fixed timestamp keeps the ZIP byte-identical across reruns of the same revision.
        $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $dst = $entry.Open(); $src = [IO.File]::OpenRead($archive)
        try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
        $zip.Dispose()
    } finally { $fs.Dispose() }
    $zipBytes = (Get-Item -LiteralPath $zipPath).Length
    if ($zipBytes -gt $MaxZipBytes) { Fail "$zipName is $zipBytes bytes, over the $MaxZipBytes-byte ceiling" }
    $check = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $zipEntries = @($check.Entries | ForEach-Object { $_.FullName })
        if ($zipEntries.Count -ne 1 -or $zipEntries[0] -ne $entryName) { Fail "ZIP layout is wrong: $($zipEntries -join ', ')" }
    } finally { $check.Dispose() }
    Write-Host "   $zipName  $zipBytes bytes  entries: $($zipEntries -join ', ')"

    # ----------------------------------------------------------------------- 7. resources
    Step 'Asset resource and E0.9 test resource'
    $package.nativeValidated = $true
    $package.assets = $receipts
    $package.archive = [ordered]@{ name = "$($kit.archiveName).archive"; sha256 = (Sha256 $archive); bytes = (Get-Item -LiteralPath $archive).Length }
    $package.zip = [ordered]@{ name = $zipName; sha256 = (Sha256 $zipPath); bytes = $zipBytes; entries = $zipEntries }
    Write-Utf8NoBom (Join-Path $resourceDir 'package.json') ($package | ConvertTo-Json -Depth 32)
    Write-Utf8NoBom (Join-Path $resourceDir 'open77.lua') (@'
-- Open77 vehicle kit: original rims and body parts, registered as visual prop models.
-- Generated by scripts/vehicle-kit/build-pack.ps1 (revision @@REV@@). Edit the spec, not this file.
resource '@@RESOURCE@@'
version '0.1.0'
auto_start false
reload_policy 'reconnect'
client_script 'register.lua'
files { 'package.json' }
preload_mod 'dist/@@ZIP@@'
permissions { 'props.register' }
'@).Replace('@@REV@@', $rev12).Replace('@@RESOURCE@@', $kit.resource).Replace('@@ZIP@@', $zipName)
    Write-Utf8NoBom (Join-Path $resourceDir 'register.lua') @'
-- Client: registers every cooked model of this pack as asset:<resource>/<model>.
-- Decision D4: a model that cannot register is skipped with a log line, and the others
-- still register. Never raise here: an error fails the resource activation, and that
-- disconnects the player. prop_archive_missing_restart_required means the game mounted
-- an older archive than this package (preload_mod archives mount at game start).
local function log(text) print('[vehicle-kit] ' .. text) end

local ok, package = pcall(json.decode, LoadResourceFile(GetCurrentResourceName(), 'package.json') or '')
if not ok or type(package) ~= 'table' or package.schema ~= 'open77.prop-package/1' or type(package.models) ~= 'table' then
    log('package.json is missing or invalid: no model registered')
    return
end
local revision = tostring(package.revision or '?'):sub(1, 12)

local ids = {}
for id in pairs(package.models) do ids[#ids + 1] = id end
table.sort(ids)   -- a stable log order

local registered, skipped = 0, 0
for _, id in ipairs(ids) do
    local def = package.models[id]
    -- registerModel accepts exactly mesh / visualEntity / physicalEntity.
    local called, alias, reason = pcall(Open77.props.registerModel, id, { mesh = def.mesh, visualEntity = def.visualEntity })
    if called and alias then
        registered = registered + 1
    else
        skipped = skipped + 1
        log(('skipped model %s: %s'):format(id, tostring(called and reason or alias)))
    end
end
log(('registered %d of %d models, skipped %d, revision %s'):format(registered, #ids, skipped, revision))
'@
    $rims = @(); $wings = @()
    foreach ($p in $kit.parts) {
        foreach ($f in $p.finishes.Keys) {
            if ($p.kind -eq 'rim') { $rims += "$($p.id)_$f" } else { $wings += "$($p.id)_$f" }
        }
    }
    $luaList = { param($items) '{ ' + (($items | ForEach-Object { "'$_'" }) -join ', ') + ' }' }
    $testName = "$($kit.resource)_e09"
    $testDir = Join-Path $script:OutRoot "resource/$testName"
    $null = Reset-Dir $testDir
    Write-Utf8NoBom (Join-Path $testDir 'open77.lua') (@'
-- E0.9 lab resource: attaches the vehicle-kit test parts to a car. Admin/lab use only.
resource '@@TEST@@'
version '0.1.0'
auto_start false
reload_policy 'reconnect'
dependency '@@RESOURCE@@'
server_script 'server.lua'
client_script 'client.lua'
-- world.props: create/attach (server), bones/projected (client); world.vehicles: the
-- lab car and seat reads (server); vehicles.read: the local seat (client);
-- network.events: the inspect event. Commands are restricted: grant command.vkit.*.
permissions { 'world.props', 'world.vehicles', 'vehicles.read', 'network.events' }
'@).Replace('@@TEST@@', $testName).Replace('@@RESOURCE@@', $kit.resource)
    Write-Utf8NoBom (Join-Path $testDir 'server.lua') ((Get-Content -LiteralPath (Join-Path $kitRoot 'lua/e09_server.lua') -Raw).
        Replace('@@RESOURCE@@', $kit.resource).Replace('@@RIMS@@', (& $luaList $rims)).Replace('@@WINGS@@', (& $luaList $wings)))
    Write-Utf8NoBom (Join-Path $testDir 'client.lua') ((Get-Content -LiteralPath (Join-Path $kitRoot 'lua/e09_client.lua') -Raw).
        Replace('@@RESOURCE@@', $kit.resource))

    # ----------------------------------------------------------------------- 8. previews
    $previews = @()
    if (-not $SkipPreview) {
        Step 'Owner-review renders'
        $previewDir = Reset-Dir (Join-Path $script:OutRoot 'preview')
        foreach ($pp in $planParts) {
            Invoke-Blender "preview $($pp.id)" 'render_preview.py' @('--part', $pp.spec, '--meta', $pp.meta, '--glb', $pp.glb,
                '--out', $previewDir, '--views', "$PreviewViews", '--samples', "$PreviewSamples") "VK_PREVIEW_OK $($pp.id)" | Out-Null
        }
        $previews = @(Get-ChildItem -LiteralPath $previewDir -Filter '*.png' | Sort-Object Name | ForEach-Object { $_.FullName })
    }
}
finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
}

# --------------------------------------------------------------------------- 9. manifest
$manifest = [ordered]@{
    schema = 'open77.vehicle-kit.build/1'
    resource = $kit.resource; revision = $revision; depotPrefix = $prefix
    tools = [ordered]@{ blender = $blenderVersion; addon = $addonVersionFound; exporter = $Exporter; wolvenkit = $wkVersion; node = (& $node --version) }
    templatesNotShipped = $templateHashes
    zip = $package.zip; archive = $package.archive; archiveEntries = $entries
    models = $package.models
    previews = @($previews | ForEach-Object { [IO.Path]::GetRelativePath($script:OutRoot, $_).Replace('\', '/') })
}
Write-Utf8NoBom (Join-Path $script:OutRoot 'manifest.json') ($manifest | ConvertTo-Json -Depth 32)
$sums = foreach ($f in @($zipPath, $archive) + $previews) { "{0}  {1}" -f (Sha256 $f), [IO.Path]::GetRelativePath($script:OutRoot, $f).Replace('\', '/') }
Write-Utf8NoBom (Join-Path $script:OutRoot 'SHA256SUMS') (($sums -join "`n") + "`n")

Step 'Done'
Write-Host "   resource  $resourceDir"
Write-Host "   test      $testDir"
Write-Host "   zip       $zipPath ($zipBytes bytes, sha256 $($package.zip.sha256))"
Write-Host "   models    $(($package.models.Keys | Sort-Object) -join ', ')"
Write-Host "VK_PACK_OK revision=$rev12 models=$($package.models.Count) files=$($entries.Count) zip=$zipBytes previews=$($previews.Count) (not deployed)"
