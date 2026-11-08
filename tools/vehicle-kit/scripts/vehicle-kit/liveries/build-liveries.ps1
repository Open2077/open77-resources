#requires -Version 7.0
<#
.SYNOPSIS
    Builds the Light RP vehicle livery pack, end to end: TweakXL YAML + .archive +
    preload_mod ZIP + draft resource, from specs/lightrp-liveries.json.

.DESCRIPTION
    One livery = one unique TwinTone colour template per model (VehicleColorTemplate,
    hasCustomPattern = true), appended to the model's AppearancesToColorTemplate, so
    Open77.vehicles.setPaintProfile(id, 'Vehicle.o77_livery_<design>_<model>') can apply it:
      - base colour: a VehicleCustomMultilayer = OUR .mlsetup over the model's own vanilla
        mask, referenced by depot path (never shipped);
      - artwork: VehicleDecalAttachment entities of this pack (our .ent -> our .mesh -> our
        .xbm), one per painted panel the design covers.

    Steps: plan (TweakDB + dealer table) -> read-only extraction of the reference paint
    stacks, palettes, masks and TwinTone generic masks (cached) -> layer roles of the
    reference stacks, measured on the visible body (lv_composite.py roles) -> artwork
    (Pillow) -> decal grids measured on the visible paint of the stock panels (numpy,
    body-kit cache) -> WolvenKit import (textures with our setups, meshes on a never-shipped
    container) -> cook (lv_cook.py) -> deserialize, round trip -> composite check: the
    multilayer and the decals as the game blends them, coverage and placement assertions,
    previews (lv_composite.py check) -> pack, pin timestamps, byte check -> no-vanilla-bytes
    scan (plates.cjs scan, then lv_scan.py check against the reviewed baseline) -> ZIP (archive +
    YAML) -> draft resource -> manifest.

    Never writes in the game folder, never launches the game, never deploys. The output
    folder must be git-ignored: the work tree holds extracted game files.
    Same spec + scripts + tools + game build = same revision and the same bytes.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/liveries/build-liveries.ps1
    pwsh -File scripts/vehicle-kit/liveries/build-liveries.ps1 -SkipPreview -OutDir D:\out\liveries
#>
[CmdletBinding()]
param(
    [string] $Spec = (Join-Path $PSScriptRoot 'specs/lightrp-liveries.json'),
    [string] $OutDir,
    [string] $GameDirectory,
    [string] $WolvenKitCli,
    [string] $Uv,
    [string] $MeasureWork,
    # The component table of the models (docs/generated): the player table covers the dealer
    # models and every vanilla player body, with their trims (lv_plan.py `records`).
    [string] $Dealer,
    # The shared blocks of the no-vanilla-bytes scan reviewed by hand (lv_scan.py): any other fails.
    [string] $ScanBaseline = (Join-Path $PSScriptRoot 'specs/no-vanilla-bytes-baseline.json'),
    [double] $Spacing = 0.02,
    [double] $Offset = 0.004,
    # Composite raster step (metres): 1 cm keeps 30-60 k visible texels per view and car.
    [double] $CompositeSpacing = 0.01,
    # Build assertions of lv_composite.py check (scripts/vehicle-kit/docs/liveries.md).
    [double] $MinPrimary = 0.85,
    [double] $MaxTrimRecolouredExcess = 0.05,
    [double] $MinDecalVisible = 0.85,
    [double] $MinDecalOnComponent = 0.9,
    [double] $MaxDecalFloating = 0.03,
    [switch] $SkipPreview,
    [string] $ResourceVersion = '0.1.0',
    # Same TweakXL floor as the stage pack (E0.8 proved 1.12.0 on this build).
    [string] $TweakXlMin = '1.12.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here = $PSScriptRoot
$kitRoot = [IO.Path]::GetFullPath((Join-Path $here '..'))
$repo = [IO.Path]::GetFullPath((Join-Path $here '../../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')
$ZipYaml = 'r6/tweaks/LightRP/open77-lightrp-liveries.yaml'
$MaxZipBytes = 64MB          # Warden upload ceiling (same as build-pack.ps1)
# Never shipped: its CR2W shell receives our imported geometry, every material, appearance
# and buffer is replaced (a vanilla customization decal mesh, so the decal-specific fields
# start from the engine's own values).
$ContainerMesh = 'base\gameplay\vehicles\visual_customization\decals\rayfield_caliburn\meshes\v_sport1_rayfield_caliburn__ext01_door_fl_numbers_01.mesh'
# Vanilla resources our files may reference by depot path (decision D6), besides the
# model masks of the plan and the mltemplates / microblends of base\surfaces.
$AllowedReferences = @('base\vehicles\common\materials\stickers.mi', 'engine\textures\editor\normal.xbm')

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail([string] $text) { throw "vehicle-liveries: $text" }
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
    $errors = @($output | Where-Object { $_ -match '\[\s*\d+:\s*Error\s*\]|^Traceback|^lv_[a-z]+: ' })
    foreach ($line in $output) {
        if ($line -match 'Garment support is enabled') { continue }   # WolvenKit noise on every static mesh import
        if ($line -match '^(LV_|VK_)|\[\s*\d+:\s*(Error|Warning)\s*\]|^Traceback|^\s+File "|^lv_[a-z]+: |^[a-z]+ +(coverage|decal|ref) ') { Write-Host "   $line" }
    }
    if ($code -ne 0 -or $errors.Count -gt 0 -or ($marker -and -not ($output -match [regex]::Escape($marker)))) {
        $tail = ($output | Select-Object -Last 25) -join "`n"
        Fail "$label failed (exit $code).`n$tail"
    }
    return $output
}

function Wk([string] $label, [string[]] $arguments) { Invoke-Tool "WolvenKit $label" $script:Cli $arguments $null }
# WolvenKit 8.20 answers exit code 3 to every FOLDER import, successful or not (measured:
# the same single file imports with 0). The import counts as done only when it says it
# imported exactly the number of files we staged.
function Wk-ImportFolder([string] $label, [string] $folder, [int] $count, [switch] $Keep)
{
    $wkArgs = @('import', $folder, '-o', $folder)
    if ($Keep) { $wkArgs += '--keep' }
    $output = Invoke-Tool "WolvenKit $label" $script:Cli $wkArgs $null @(0, 3)
    $done = [regex]::Match(($output -join "`n"), 'Imported (\d+)/(\d+) file')
    if (-not $done.Success -or [int] $done.Groups[1].Value -ne $count -or [int] $done.Groups[2].Value -ne $count) {
        Fail "WolvenKit $label imported $(if ($done.Success) { $done.Value } else { 'nothing' }), expected $count/$count.`n$(($output | Select-Object -Last 15) -join "`n")"
    }
}
function Py([string] $label, [string] $script, [string[]] $arguments, [string] $marker)
{
    Invoke-Tool $label $script:UvExe (@('run', '--no-project', '--with', 'pillow==13.0.0', '--with', 'numpy==2.5.4', 'python', '-I', (Join-Path $here $script)) + $arguments) $marker
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

# --------------------------------------------------------------------------- 0. inputs
Step 'Resolving inputs and tools'
$SpecPath = (Resolve-Path -LiteralPath $Spec).Path
$lv = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json -AsHashtable
if ($lv.schema -ne 'open77.vehicle-liveries/1') { Fail "spec schema must be open77.vehicle-liveries/1 ($SpecPath)" }
if ($lv.resource -notmatch '^[a-z0-9_-]{1,64}$') { Fail "resource '$($lv.resource)' must match [a-z0-9_-]{1,64}" }
if ($lv.archiveName -notmatch '^[A-Za-z0-9_]{3,64}$' -or $lv.archiveName -match '^Open77(Mirror|RP)?$') { Fail "archiveName '$($lv.archiveName)' is invalid or collides with a platform archive" }
if ($lv.recordPrefix -notmatch '^Vehicle\.o77_[a-z0-9_]+_$') { Fail "recordPrefix '$($lv.recordPrefix)' must look like Vehicle.o77_<name>_" }
$ids = @{}
foreach ($d in $lv.designs) {
    if ($d.id -notmatch '^[a-z0-9]{2,16}$') { Fail "design id '$($d.id)' must match [a-z0-9]{2,16}" }
    if ($ids.ContainsKey($d.id)) { Fail "duplicate design $($d.id)" }
    $ids[$d.id] = $true
    if (-not $lv.finishes.ContainsKey($d.finish)) { Fail "design $($d.id): unknown finish $($d.finish)" }
    foreach ($k in 'primary', 'secondary') { if ($d[$k] -notmatch '^#[0-9a-f]{6}$') { Fail "design $($d.id): $k must be #rrggbb" } }
}
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
if (-not $script:UvExe) { Fail 'uv not found (pass -Uv <uv.exe>): it runs the Pillow/numpy steps in an isolated environment' }
$node = (Get-Command node -ErrorAction SilentlyContinue)?.Source
if (-not $node) { Fail 'node (Node.js 18+) not found on PATH (archive timestamp normalization)' }
if (-not $MeasureWork) { $MeasureWork = Join-Path ([IO.Path]::GetTempPath()) 'open77-vehicle-kit-measure\bodykit' }
$MeasureWork = [IO.Path]::GetFullPath($MeasureWork)
if ($MeasureWork.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) { Fail "-MeasureWork $MeasureWork is inside the repository; game data must stay outside it" }

if (-not $OutDir) { $OutDir = Join-Path $repo 'artifacts/vehicle-kit/liveries' }
$script:OutRoot = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $script:OutRoot | Out-Null
if ($script:OutRoot.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    & git -C $repo check-ignore -q -- (Join-Path $script:OutRoot 'probe.archive')
    if ($LASTEXITCODE -ne 0) { Fail "output folder $script:OutRoot is inside the repository but not git-ignored" }
}
$work = Join-Path $script:OutRoot 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (-not $Dealer) { $Dealer = Join-Path $repo 'docs/generated/vehicle-components-player-bodies-2.50.json' }
$Dealer = (Resolve-Path -LiteralPath $Dealer).Path
Write-Host "   WolvenKit $wkVersion  uv $script:UvExe  game $GameDirectory"

# --------------------------------------------------------------------------- 1. plan
Step 'Plan (TweakDB + dealer table, read-only)'
$planPath = Join-Path $work 'plan.json'
Py 'plan' 'lv_plan.py' @('--spec', $SpecPath, '--game', $GameDirectory, '--dealer', $Dealer, '--out', $planPath) 'LV_PLAN_OK' | Out-Null
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -AsHashtable

# --------------------------------------------------------------------------- 2. game files
Step 'Reference paint stacks, palettes, masks and the mesh container (read-only, cached, never shipped)'
$gameRaw = Join-Path $work 'game/raw'
$gameFlat = Join-Path $work 'game/flat'
$gameJson = Join-Path $work 'game/json'
# Extracts the missing $raw depot paths into game/raw, serializes the missing $json ones into game/json.
function Sync-GameFiles([string[]] $raw, [string[]] $json)
{
    $missing = @($raw | Where-Object { -not (Test-Path -LiteralPath (Join-Path $gameRaw $_)) })
    if ($missing.Count) {
        New-Item -ItemType Directory -Force -Path $gameRaw | Out-Null
        # ep1 paths live in archive\pc\ep1, the rest in archive\pc\content (as body_measure.py).
        foreach ($pair in @(@('archive\pc\content', @($missing | Where-Object { -not $_.StartsWith('ep1\') })),
                            @('archive\pc\ep1', @($missing | Where-Object { $_.StartsWith('ep1\') })))) {
            $src = Join-Path $GameDirectory $pair[0]
            if (-not $pair[1].Count -or -not (Test-Path -LiteralPath $src)) { continue }
            foreach ($rx in (Get-DepotRegexes $pair[1])) {
                Wk "extract from $($pair[0])" @('extract', $src, '--regex', $rx, '--outpath', $gameRaw, '--gamepath', $GameDirectory) | Out-Null
            }
        }
        $missing = @($raw | Where-Object { -not (Test-Path -LiteralPath (Join-Path $gameRaw $_)) })
        if ($missing.Count) { Fail "not found in the game archives: $($missing -join ', ')" }
    }
    $needJson = @($json | Where-Object { -not (Test-Path -LiteralPath (Join-Path $gameJson ((Flat $_) + '.json'))) })
    if ($needJson.Count) {
        $null = Reset-Dir $gameFlat
        foreach ($p in $needJson) { Copy-Item -LiteralPath (Join-Path $gameRaw $p) -Destination (Join-Path $gameFlat (Flat $p)) }
        New-Item -ItemType Directory -Force -Path $gameJson | Out-Null
        Wk "serialize $($needJson.Count) game files" @('convert', 'serialize', $gameFlat, '--outpath', $gameJson) | Out-Null
    }
}
$dealerJson = Get-Content -LiteralPath $Dealer -Raw | ConvertFrom-Json -AsHashtable
# The model masks (sampled by the composite) and each model's TwinTone generic mask (TweakDB
# genericCustomizationMask: the factory split between main colour, secondary colour and the
# vanilla material). Read only: neither is shipped, the generic masks are not even referenced.
$maskDepots = @($plan.models | ForEach-Object { $_.multilayers | ForEach-Object { $_.mask } } | Sort-Object -Unique)
$genericDepots = @(@(foreach ($m in $plan.models) {
    $gm = [string] ($dealerJson.models | Where-Object { $_.key -eq $m.key })['tweakdb']['genericCustomizationMask']
    if ($gm) { $gm }
}) | Sort-Object -Unique)
$wantedJson = @($plan.gameFiles) + @($ContainerMesh)
$wanted = @($wantedJson + $maskDepots + $genericDepots | Sort-Object -Unique)
Sync-GameFiles $wanted $wantedJson
$containerSha = Sha256 (Join-Path $gameRaw $ContainerMesh)
Write-Host "   $($wanted.Count) game files cached ($($maskDepots.Count) masks, $($genericDepots.Count) generic masks); container $containerSha"

# --------------------------------------------------------------------------- 3. body-kit cache
Step 'Stock exterior panels (body-kit measurement cache, outside the repository)'
$needGlb = @()
foreach ($m in $plan.models) {
    $dm = $dealerJson.models | Where-Object { $_.key -eq $m.key }
    foreach ($c in $dm.components) {
        # Indexing, not dot access: strict mode throws on a key this component lacks.
        $mesh = [string] $c['mesh']
        if ($c['inPlayerAppearance'] -and $mesh -and $m.targets -contains $c['name']) {
            $glb = Join-Path $MeasureWork ('glb/' + $mesh.Substring(0, $mesh.Length - 5).Replace('\', '/') + '.glb')
            if (-not (Test-Path -LiteralPath $glb)) { $needGlb += $m.key; break }
        }
    }
}
if ($needGlb.Count) {
    Write-Host "   extracting the body-kit cache for: $($needGlb -join ', ')"
    Invoke-Tool 'body_measure --extract' $script:UvExe @('run', '--no-project', 'python', (Join-Path $kitRoot 'blender/body_measure.py'), '--extract', '--work', $MeasureWork, '--dealer', $Dealer,
        '--cars', ($needGlb -join ','), '--game', $GameDirectory, '--cli', $script:Cli) 'VK_BODY_MEASURE_OK' | Out-Null
}

# --------------------------------------------------------------------------- 3b. composite inputs
Step 'Composite inputs: mesh materials, mltemplates, masks as PNG (read-only, cached, never shipped)'
$previewRoot = Join-Path $script:OutRoot 'preview'
if (Test-Path -LiteralPath $previewRoot) { $null = Reset-Dir $previewRoot }
$meshJsonDir = Join-Path $work 'game/meshjson'
$maskDir = Join-Path $work 'game/masks'
$genericDir = Join-Path $work 'game/generic'
$compositeCfgPath = Join-Path $work 'composite-cfg.json'
$rolesPath = Join-Path $work 'layer-roles.json'
$compositeCfg = [ordered]@{
    plan = $planPath; spec = $SpecPath; dealer = $Dealer; gameJson = @($gameJson); measureWork = $MeasureWork; meshJson = $meshJsonDir
    masks = $maskDir; generic = $genericDir; spacing = $CompositeSpacing
    inputsOut = (Join-Path $work 'composite-inputs.json'); rolesOut = $rolesPath
}
if (-not $SkipPreview) { $compositeCfg.preview = $previewRoot }
Write-Utf8NoBom $compositeCfgPath ($compositeCfg | ConvertTo-Json -Depth 8)
# The material chains (.mi -> .mi -> .mt) are only known once the meshes and the first .mi
# files are serialized: list, fetch, and list again until nothing is missing.
for ($pass = 1; ; $pass++) {
    Py 'composite inputs' 'lv_composite.py' @('inputs', '--cfg', $compositeCfgPath) 'LV_INPUTS_OK' | Out-Null
    $compositeInputs = Get-Content -LiteralPath $compositeCfg.inputsOut -Raw | ConvertFrom-Json -AsHashtable
    if ($compositeInputs.complete) { break }
    if ($pass -ge 6) { Fail 'composite inputs still incomplete after 6 passes (material chain deeper than expected?)' }
    $chain = @(@($compositeInputs.templates) + @($compositeInputs.materials) | Sort-Object -Unique)
    Sync-GameFiles $chain $chain
    # Mesh materials and chunk lists: the raw .mesh files of the body-kit cache, as WolvenKit JSON.
    $needMesh = @($compositeInputs.meshes.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $meshJsonDir ((Flat $_) + '.json'))) } | Sort-Object)
    if ($needMesh.Count) {
        $meshFlat = Reset-Dir (Join-Path $work 'game/meshflat')
        foreach ($m in $needMesh) { Copy-Item -LiteralPath $compositeInputs.meshes[$m] -Destination (Join-Path $meshFlat (Flat $m)) }
        New-Item -ItemType Directory -Force -Path $meshJsonDir | Out-Null
        Wk "serialize $($needMesh.Count) meshes" @('convert', 'serialize', $meshFlat, '--outpath', $meshJsonDir) | Out-Null
        $null = Reset-Dir $meshFlat
    }
}
$templateDepots = @($compositeInputs.templates)
$materialDepots = @($compositeInputs.materials)
# WolvenKit exports a file next to itself, one file per call (a folder export fails).
foreach ($m in $maskDepots) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($m)
    $dir = Join-Path $maskDir (Flat $m)
    if (Test-Path -LiteralPath (Join-Path $dir "$stem.masklist")) { continue }
    $null = New-Item -ItemType Directory -Force -Path $dir
    Copy-Item -LiteralPath (Join-Path $gameRaw $m) -Destination (Join-Path $dir "$stem.mlmask")
    Wk "export mask $stem" @('export', (Join-Path $dir "$stem.mlmask"), '--outpath', $dir, '--gamepath', $GameDirectory) | Out-Null
    Remove-Item -LiteralPath (Join-Path $dir "$stem.mlmask")
    if (-not (Test-Path -LiteralPath (Join-Path $dir "$stem.masklist"))) { Fail "WolvenKit exported no $stem.masklist" }
}
New-Item -ItemType Directory -Force -Path $genericDir | Out-Null
foreach ($g in $genericDepots) {
    $flatXbm = Join-Path $genericDir (Flat $g)
    $png = $flatXbm.Substring(0, $flatXbm.Length - 4) + '.png'
    if (Test-Path -LiteralPath $png) { continue }
    Copy-Item -LiteralPath (Join-Path $gameRaw $g) -Destination $flatXbm
    Wk "export generic mask $([IO.Path]::GetFileName($g))" @('export', $flatXbm, '--outpath', $genericDir, '--gamepath', $GameDirectory, '--uext', 'png') | Out-Null
    Remove-Item -LiteralPath $flatXbm
    if (-not (Test-Path -LiteralPath $png)) { Fail "WolvenKit exported no $png" }
}
Write-Host "   $($compositeInputs.meshes.Count) meshes, $($templateDepots.Count) mltemplates, $($materialDepots.Count) material instances, $($maskDepots.Count) masks, $($genericDepots.Count) generic masks"

Step 'Layer roles of the reference stacks, measured on the visible body (numpy)'
Py 'layer roles' 'lv_composite.py' @('roles', '--cfg', $compositeCfgPath) 'LV_ROLES_OK' | Out-Null

# --------------------------------------------------------------------------- 4. art + decals
Step 'Artwork (original, Pillow)'
$artDir = Reset-Dir (Join-Path $work 'art')
Py 'art' 'lv_art.py' @('--spec', $SpecPath, '--out', $artDir, '--preview', (Join-Path $previewRoot 'flat')) 'LV_ART_OK' | Out-Null

Step 'Decal grids on the visible paint of the stock panels (numpy)'
$decalDir = Reset-Dir (Join-Path $work 'decals')
$decalArgs = @('--plan', $planPath, '--spec', $SpecPath, '--dealer', $Dealer, '--measure-work', $MeasureWork, '--mesh-json', $meshJsonDir,
    '--game-json', $gameJson, '--art', $artDir, '--out', $decalDir, '--spacing', "$Spacing", '--offset', "$Offset")
Py 'decals' 'lv_decals.py' $decalArgs 'LV_DECALS_OK' | Out-Null
$decals = Get-Content -LiteralPath (Join-Path $decalDir 'decals.json') -Raw | ConvertFrom-Json -AsHashtable

# --------------------------------------------------------------------------- 5. revision
$hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
$add = { param($text) $hasher.AppendData([Text.Encoding]::UTF8.GetBytes([string] $text + "`n")) }
& $add ((Get-Content -LiteralPath $SpecPath -Raw) -replace "`r`n", "`n")
foreach ($f in (@(Get-ChildItem -LiteralPath $here -Filter '*.py' -File) + @(Get-ChildItem -LiteralPath (Join-Path $here 'lua') -Filter '*.lua' -File) + @(Get-Item -LiteralPath $PSCommandPath) | Sort-Object Name)) {
    & $add $f.Name; & $add ((Get-Content -LiteralPath $f.FullName -Raw) -replace "`r`n", "`n")
}
foreach ($f in (Get-ChildItem -LiteralPath $artDir -Filter '*.png' -File | Sort-Object Name)) { & $add "$($f.Name) $(Sha256 $f.FullName)" }
foreach ($f in (Get-ChildItem -LiteralPath $decalDir -Recurse -Filter '*.glb' -File | Sort-Object FullName)) { & $add "$([IO.Path]::GetRelativePath($decalDir, $f.FullName)) $(Sha256 $f.FullName)" }
foreach ($p in (@($wanted + $templateDepots + $materialDepots) | Sort-Object -Unique)) { & $add "$p $(Sha256 (Join-Path $gameRaw $p))" }
& $add "layer-roles.json $(Sha256 $rolesPath)"
# The trims each model lists come from the component table (plan.json `records`).
& $add "$([IO.Path]::GetFileName($Dealer)) $(Sha256 $Dealer)"
& $add "$wkVersion|tweakxl>=$TweakXlMin|spacing=$Spacing|offset=$Offset"
$revision = ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
$rev12 = $revision.Substring(0, 12)
$prefix = "open77\assets\$($lv.resource)\$rev12"
Write-Host "   revision $revision  ->  $prefix"

# --------------------------------------------------------------------------- 6. textures
Step 'Textures: PNG -> xbm with the sticker setups (BC7 sRGB colour + alpha cut-out, BC4 mask)'
$xbm1 = Reset-Dir (Join-Path $work 'xbm/default')
$xbm1Json = Reset-Dir (Join-Path $work 'xbm/default-json')
$xbm2 = Reset-Dir (Join-Path $work 'xbm/final')
$xbm2Json = Reset-Dir (Join-Path $work 'xbm/final-json')
$textures = @()
foreach ($d in $lv.designs) {
    foreach ($k in 'd', 'm') {
        $depot = "$prefix\textures\$($d.id)_$k.xbm"
        $stem = (Flat $depot).Substring(0, (Flat $depot).Length - 4)
        Copy-Item -LiteralPath (Join-Path $artDir "$($d.id)_$k.png") -Destination (Join-Path $xbm1 "$stem.png")
        $textures += [ordered]@{ depot = $depot; kind = $k; stem = $stem; size = @(2048, 1024)
            json = (Join-Path $xbm1Json "$stem.xbm.json"); roundtrip = (Join-Path $xbm2Json "$stem.xbm.json") }
    }
}
Wk-ImportFolder 'import textures (default setup)' $xbm1 $textures.Count
Wk 'serialize textures' @('convert', 'serialize', $xbm1, '--outpath', $xbm1Json) | Out-Null
$cookPath = Join-Path $work 'cook.json'
$cook = [ordered]@{
    spec = $SpecPath; plan = $planPath; decals = (Join-Path $decalDir 'decals.json'); gameJson = $gameJson
    prefix = $prefix; resource = $lv.resource; revision = $revision; wolvenkit = $wkNumeric
    textures = $textures; meshes = @(); allowedReferences = $AllowedReferences; layerRoles = $rolesPath
    preparedDir = (Join-Path $work 'prepared'); roundtripDir = (Join-Path $work 'roundtrip')
    yamlOut = (Join-Path $work 'open77-lightrp-liveries.yaml'); luaOut = (Join-Path $work 'liveries.lua')
    profilesOut = (Join-Path $work 'profiles.json'); packageOut = (Join-Path $work 'package.json')
}
Write-Utf8NoBom $cookPath ($cook | ConvertTo-Json -Depth 16)
Py 'xbm setups' 'lv_cook.py' @('xbm-setup', $cookPath) 'LV_XBM_SETUP_OK' | Out-Null
Wk 'deserialize texture templates' @('convert', 'deserialize', $xbm1Json, '--outpath', $xbm2) | Out-Null
foreach ($t in $textures) { Copy-Item -LiteralPath (Join-Path $xbm1 "$($t.stem).png") -Destination (Join-Path $xbm2 "$($t.stem).png") }
Wk-ImportFolder 'import textures (--keep: our setups)' $xbm2 $textures.Count -Keep
Get-ChildItem -LiteralPath $xbm2 -Filter '*.png' | Remove-Item -Force
Wk 'serialize final textures' @('convert', 'serialize', $xbm2, '--outpath', $xbm2Json) | Out-Null

# --------------------------------------------------------------------------- 7. meshes
Step 'Decal meshes: glb -> WolvenKit import on the container'
$meshDir = Reset-Dir (Join-Path $work 'mesh/import')
$meshJson = Reset-Dir (Join-Path $work 'mesh/import-json')
$meshes = @()
foreach ($key in ($decals.models.Keys | Sort-Object)) {
    $dm = $decals.models[$key]
    foreach ($comp in ($dm.components.Keys | Sort-Object)) {
        $covered = @($dm.designs.Keys | Where-Object { @($dm.designs[$_]) -contains $comp })
        if (-not $covered.Count) { continue }
        $depot = "$prefix\meshes\$key\$($comp.ToLowerInvariant()).mesh"
        $stem = (Flat $depot).Substring(0, (Flat $depot).Length - 5)
        Copy-Item -LiteralPath (Join-Path $gameRaw $ContainerMesh) -Destination (Join-Path $meshDir "$stem.mesh")
        Copy-Item -LiteralPath $dm.components[$comp].glb -Destination (Join-Path $meshDir "$stem.glb")
        $meshes += [ordered]@{ model = $key; component = $comp; importedJson = (Join-Path $meshJson "$stem.mesh.json") }
    }
}
Wk-ImportFolder "import $($meshes.Count) meshes (--keep)" $meshDir $meshes.Count -Keep
Get-ChildItem -LiteralPath $meshDir -Filter '*.glb' | Remove-Item -Force
Wk 'serialize meshes' @('convert', 'serialize', $meshDir, '--outpath', $meshJson) | Out-Null
$cook.meshes = $meshes
Write-Utf8NoBom $cookPath ($cook | ConvertTo-Json -Depth 16)

# --------------------------------------------------------------------------- 8. cook
Step 'Cook (materials, appearances, decal entities, mlsetups, YAML)'
$null = Reset-Dir $cook.preparedDir
Py 'cook prepare' 'lv_cook.py' @('prepare', $cookPath) 'LV_COOK_PREPARED' | Out-Null
$deser = Reset-Dir (Join-Path $work 'deserialized')
Wk 'deserialize' @('convert', 'deserialize', $cook.preparedDir, '--outpath', $deser) | Out-Null
$null = Reset-Dir $cook.roundtripDir
Wk 'round trip serialize' @('convert', 'serialize', $deser, '--outpath', $cook.roundtripDir) | Out-Null
Py 'cook validate' 'lv_cook.py' @('validate', $cookPath) 'LV_COOK_ROUNDTRIP_OK' | Out-Null
# Read after validate: it adds the texture checks to package.json.
$package = Get-Content -LiteralPath $cook.packageOut -Raw | ConvertFrom-Json -AsHashtable

Step 'Composite check: our multilayers and decals as the game blends them (assertions + previews)'
$compositeReport = Join-Path $work 'composite.json'
$checkCfg = [ordered]@{}
foreach ($k in $compositeCfg.Keys) { $checkCfg[$k] = $compositeCfg[$k] }
$checkCfg.preparedDir = $cook.preparedDir; $checkCfg.prefix = $prefix; $checkCfg.decals = $cook.decals
$checkCfg.art = $artDir; $checkCfg.package = $cook.packageOut; $checkCfg.decalAlpha = 'mask'
$checkCfg.minPrimary = $MinPrimary; $checkCfg.maxTrimRecolouredExcess = $MaxTrimRecolouredExcess; $checkCfg.minDecalVisible = $MinDecalVisible
$checkCfg.minDecalOnComponent = $MinDecalOnComponent; $checkCfg.maxDecalFloating = $MaxDecalFloating
$checkCfg.reportOut = $compositeReport
if (-not $SkipPreview) { $checkCfg.layerSheets = @($lv.designs | ForEach-Object { $_.id }) }
$checkCfgPath = Join-Path $work 'composite-check-cfg.json'
Write-Utf8NoBom $checkCfgPath ($checkCfg | ConvertTo-Json -Depth 8)
Py 'composite check' 'lv_composite.py' @('check', '--cfg', $checkCfgPath) 'LV_COMPOSITE_OK' | Out-Null
$composite = Get-Content -LiteralPath $compositeReport -Raw | ConvertFrom-Json -AsHashtable

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
foreach ($t in $textures) {
    $dst = Join-Path $stage $t.depot
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath (Join-Path $xbm2 "$($t.stem).xbm") -Destination $dst
    $expected += $t.depot
}
$expected = @($expected | Sort-Object)

# --------------------------------------------------------------------------- 9. archive
Step 'Pack and verify the archive'
$packedDir = Reset-Dir (Join-Path $work 'packed')
Wk 'pack' @('pack', $stage, '--outpath', $packedDir) | Out-Null
$packed = Join-Path $packedDir 'stage.archive'
if (-not (Test-Path -LiteralPath $packed)) { Fail "pack produced no $packed" }
$archive = Join-Path $packedDir "$($lv.archiveName).archive"
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

Step 'No vanilla bytes: every game file the build read against every cooked file (plates.cjs scan)'
# plates.cjs fails on any shared binary block; lv_scan.py check accepts the names tables, the
# vertex format descriptors and the known blocks of the baseline, and fails on any other.
$scanPlan = Join-Path $work 'scan/scan-plan.json'
$scanJson = Join-Path $work 'scan/scan.json'
if (Test-Path -LiteralPath $scanJson) { Remove-Item -LiteralPath $scanJson -Force }
Py 'no-vanilla-bytes scan: plan' 'lv_scan.py' @('plan', $work, $scanPlan) 'LV_SCAN_PLAN_OK' | Out-Null
$scanOut = & $node (Join-Path $kitRoot 'plates/native/plates.cjs') scan $scanPlan $stage 2>&1 | ForEach-Object { "$_" }
$scanCode = $LASTEXITCODE
if ($scanCode -eq 0) {
    $scanLine = $scanOut | Where-Object { $_ -match '^PLATES_SCAN_OK' } | Select-Object -First 1
    Write-Host "   $scanLine"
} elseif (-not (Test-Path -LiteralPath $scanJson) -or -not ($scanOut -match 'PLATES_FAILED scan: \d+ binary 64-byte blocks')) {
    Fail "no-vanilla-bytes scan failed (exit $scanCode).`n$(($scanOut | Select-Object -Last 10) -join "`n")"
} else {
    $scanLine = Py 'no-vanilla-bytes scan: known blocks' 'lv_scan.py' @('check', $scanPlan, $ScanBaseline) 'LV_SCAN_OK' |
        Where-Object { $_ -match '^LV_SCAN_OK' } | Select-Object -First 1
}

# --------------------------------------------------------------------------- 10. ZIP
Step 'preload_mod ZIP (archive + TweakXL YAML)'
$resourceDir = Reset-Dir (Join-Path $script:OutRoot "resource/$($lv.resource)")
$zipName = "$($lv.archiveName)_$rev12.zip"
$zipPath = Join-Path $resourceDir "dist/$zipName"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zipPath) | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipArchive = "archive/pc/mod/$($lv.archiveName).archive"
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

# --------------------------------------------------------------------------- 11. resource
Step 'Draft Light RP resource'
New-Item -ItemType Directory -Force -Path (Join-Path $resourceDir 'server') | Out-Null
Copy-Item -LiteralPath $cook.luaOut -Destination (Join-Path $resourceDir 'server/liveries.lua')
Copy-Item -LiteralPath $cook.profilesOut -Destination (Join-Path $resourceDir 'profiles.json')
Write-Utf8NoBom (Join-Path $resourceDir 'open77.lua') (@'
-- Light RP vehicle liveries (DRAFT). Ships the TweakXL records Vehicle.o77_livery_<design>_<model>
-- and their textures, meshes and decal entities as one inert preload_mod: the launcher projects
-- it before the game starts, TweakXL creates the records at boot and appends them to each
-- model's AppearancesToColorTemplate. Needs the TweakXL loader resource in resources.load.
-- Generated by scripts/vehicle-kit/liveries/build-liveries.ps1 (revision @@REV@@). Edit the
-- spec, not this file.
resource '@@RESOURCE@@'
version '@@VERSION@@'
auto_start true
dependency 'tweakxl >=@@TWEAKXL@@'
preload_mod 'dist/@@ZIP@@'
server_script 'server/liveries.lua'
server_script 'server/main.lua'
-- world.vehicles + world.vehicles.appearance: setPaintProfile (D9) for the lab command.
permissions { 'world.vehicles', 'world.vehicles.appearance' }
'@).Replace('@@REV@@', $rev12).Replace('@@RESOURCE@@', $lv.resource).Replace('@@VERSION@@', $ResourceVersion).Replace('@@TWEAKXL@@', $TweakXlMin).Replace('@@ZIP@@', $zipName)
Write-Utf8NoBom (Join-Path $resourceDir 'server/main.lua') ((Get-Content -LiteralPath (Join-Path $here 'lua/liveries_main.lua') -Raw).Replace('@@RESOURCE@@', $lv.resource))

# --------------------------------------------------------------------------- 12. manifest
Step 'Manifest'
Copy-Item -LiteralPath $cook.yamlOut -Destination (Join-Path $script:OutRoot 'open77-lightrp-liveries.yaml') -Force
$records = @($package.records)
$manifest = [ordered]@{
    schema = 'open77.vehicle-liveries.build/1'
    revision = $revision; depotPrefix = $prefix
    tools = [ordered]@{ wolvenkit = $wkVersion; node = (& $node --version); tweakxlMin = $TweakXlMin }
    templatesNotShipped = [ordered]@{ $ContainerMesh = $containerSha }
    referencedNotShipped = [ordered]@{ masks = $maskDepots; others = $AllowedReferences + @($lv.finishes.Values) }
    readNotShipped = [ordered]@{ genericMasks = $genericDepots; meshes = $compositeInputs.meshes.Count; mltemplates = $templateDepots.Count; materialInstances = $materialDepots.Count }
    composite = [ordered]@{
        limits = $composite.limits; spacing = $composite.spacing; decalAlpha = $composite.decalAlpha
        primaryShare = [ordered]@{}
    }
    zip = [ordered]@{ name = $zipName; sha256 = (Sha256 $zipPath); bytes = $zipBytes; entries = $zipEntries }
    archive = [ordered]@{ name = "$($lv.archiveName).archive"; sha256 = (Sha256 $archive); bytes = (Get-Item -LiteralPath $archive).Length; entries = $entries.Count }
    scan = $scanLine
    records = $records.Count
    models = $package.models
    textures = $package.texturesChecked
    previews = @(Get-ChildItem -LiteralPath $previewRoot -Recurse -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { [IO.Path]::GetRelativePath($script:OutRoot, $_.FullName).Replace('\', '/') })
    deployed = $false
}
foreach ($key in ($composite.models.Keys | Sort-Object)) {
    $manifest.composite.primaryShare[$key] = [ordered]@{}
    foreach ($did in ($composite.models[$key].designs.Keys | Sort-Object)) {
        $manifest.composite.primaryShare[$key][$did] = $composite.models[$key].designs[$did].primaryShare
    }
}
Copy-Item -LiteralPath $rolesPath -Destination (Join-Path $script:OutRoot 'layer-roles.json') -Force
Copy-Item -LiteralPath $compositeReport -Destination (Join-Path $script:OutRoot 'composite.json') -Force
Write-Utf8NoBom (Join-Path $script:OutRoot 'manifest.json') ($manifest | ConvertTo-Json -Depth 16)
$sumFiles = @($zipPath, $archive, (Join-Path $script:OutRoot 'open77-lightrp-liveries.yaml'), (Join-Path $resourceDir 'open77.lua'),
    (Join-Path $resourceDir 'server/main.lua'), (Join-Path $resourceDir 'server/liveries.lua'), (Join-Path $resourceDir 'profiles.json'))
$sums = foreach ($f in $sumFiles) { "{0}  {1}" -f (Sha256 $f), [IO.Path]::GetRelativePath($script:OutRoot, $f).Replace('\', '/') }
Write-Utf8NoBom (Join-Path $script:OutRoot 'SHA256SUMS') (($sums -join "`n") + "`n")

Step 'Done'
Write-Host "   resource  $resourceDir"
Write-Host "   zip       $zipPath ($zipBytes bytes)"
Write-Host "   yaml      $(Join-Path $script:OutRoot 'open77-lightrp-liveries.yaml')"
Write-Host "   previews  $previewRoot"
Write-Host "VK_LIVERIES_OK revision=$rev12 records=$($records.Count) files=$($entries.Count) zip=$zipBytes (not deployed)"
