#requires -Version 7.0
<#
.SYNOPSIS
    Builds the Light RP ORIGINAL sticker pack, end to end: motif textures + decal meshes +
    TweakXL YAML + .archive + preload_mod ZIP + draft resource, from specs/original-stickers.json.

.DESCRIPTION
    One sticker set = one theme on one dealer model: one decal per placement zone its motifs
    name (hood, roof, trunk, rear, doors, sills, wings), each hung on the stock panel the zone
    finds on that model. Everything the pack carries is ours: the motif art (st_draw.py or a
    committed PNG), the textures, the decal meshes (a grid laid on the measured panel), the
    material instances and the decal entities. The game supplies references by depot path
    (stickers.mi, the flat normal) and, never shipped, the measurement inputs: the stock meshes,
    their material chains, and the container whose CR2W shell receives our imported geometry
    (the livery pack's).

    Steps: body-kit cache (outside the repository; extracted when a model is missing) ->
    placement inputs: raw meshes and .mi chains as WolvenKit JSON (read-only, cached) -> motif
    textures (st_art.py) -> zones, hosts, fit, decal meshes, assertions, decal budget
    (st_place.py place) -> review boards (st_board.py, via place) -> [ -ReviewOnly stops here ]
    -> revision -> textures with the sticker setups (two-pass import) -> meshes on the
    container (--keep) -> cook (st_ocook.py: materials, entities, YAML, Lua catalogue) ->
    deserialize, round trip -> pack, pin timestamps, byte check -> no-vanilla-bytes scan
    (plates.cjs scan; the CR2W names tables it reports are verified by st_ocook.py scan-names)
    -> ZIP (archive + YAML) -> draft resource -> manifest.

    Never writes in the game folder, never launches the game, never deploys. The game files the
    build reads (and their JSON) live in -GameCache and -MeasureWork, both in %TEMP% by default
    and refused inside the repository. The output folder must still be git-ignored when it is in
    the repository: it holds the build's own intermediates and the review boards.
    Same spec + scripts + tools + game build = same revision and the same bytes.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/stickers/build-original-stickers.ps1
    pwsh -File scripts/vehicle-kit/stickers/build-original-stickers.ps1 -ReviewOnly -Models hella,caliburn
#>
[CmdletBinding()]
param(
    [string] $Spec = (Join-Path $PSScriptRoot 'specs/original-stickers.json'),
    [string] $OutDir,
    [string] $GameDirectory,
    [string] $WolvenKitCli,
    [string] $Uv,
    # Body-kit measurement cache (outside the repository). Its own folder by default: an
    # extraction rewrites the cache's measure.json for the models it extracted.
    [string] $MeasureWork,
    # Game files read for the placement (raw meshes, .mi chains, the container) and their
    # WolvenKit JSON: outside the repository, %TEMP% by default. Read-only cache, never shipped.
    [string] $GameCache,
    # The component table of the models (docs/generated): the player table covers the dealer
    # models and every vanilla player body of the spec's extendedModels, with their trims.
    [string] $Dealer,
    # Placement raster (metres), decal grid step, decal offset off the panel.
    [double] $Step = 0.01,
    [double] $Spacing = 0.02,
    [double] $Offset = 0.004,
    # Build assertions of st_place.py, on the motif's opaque texels.
    [double] $MinCarried = 0.97,
    [double] $MinVisible = 0.97,
    [double] $MinOnHost = 0.98,
    [double] $MaxFloating = 0.01,
    # A comma-separated subset of the spec's models (review iterations only: a pack is always all of them).
    [string] $Models,
    # Stop after the review boards: no WolvenKit import, no cook, no pack.
    [switch] $ReviewOnly,
    [string] $ResourceVersion = '0.1.0',
    # Same TweakXL floor as the stage, livery and sticker packs (E0.8 proved 1.12.0 on this build).
    [string] $TweakXlMin = '1.12.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$here = $PSScriptRoot
$kitRoot = [IO.Path]::GetFullPath((Join-Path $here '..'))
$repo = [IO.Path]::GetFullPath((Join-Path $here '../../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')
$YamlName = 'open77-lightrp-original-stickers.yaml'
$ZipYaml = "r6/tweaks/LightRP/$YamlName"
$MaxZipBytes = 64MB          # Warden upload ceiling (same as build-pack.ps1)
# Never shipped: its CR2W shell receives our imported geometry (build-liveries.ps1's container).
$ContainerMesh = 'base\gameplay\vehicles\visual_customization\decals\rayfield_caliburn\meshes\v_sport1_rayfield_caliburn__ext01_door_fl_numbers_01.mesh'
# Vanilla resources our files may reference by depot path (decision D6): lv_cook.decal_material's.
$AllowedReferences = @('base\vehicles\common\materials\stickers.mi', 'engine\textures\editor\normal.xbm')

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail([string] $text) { throw "vehicle-original-stickers: $text" }
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
    $inside = @($script:OutRoot, $script:GameRoot) | Where-Object { $_ -and $full.StartsWith($_ + [IO.Path]::DirectorySeparatorChar) }
    if (-not $inside) { Fail "refusing to clear $full (outside $script:OutRoot and $script:GameRoot)" }
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
    $errors = @($output | Where-Object { $_ -match '\[\s*\d+:\s*Error\s*\]|^Traceback|^st_[a-z]+: |^lv_[a-z]+: |PLATES_FAILED' })
    foreach ($line in $output) {
        if ($line -match 'Garment support is enabled') { continue }   # WolvenKit noise on every static mesh import
        if ($line -match '^(ST_|LV_|VK_|PLATES_)|\[\s*\d+:\s*(Error|Warning)\s*\]|^Traceback|^\s+File "|^st_[a-z]+: |^lv_[a-z]+: |^[a-z0-9]+ +(set|zone|skip|art) ') { Write-Host "   $line" }
    }
    if ($code -ne 0 -or $errors.Count -gt 0 -or ($marker -and -not ($output -match [regex]::Escape($marker)))) {
        $tail = ($output | Select-Object -Last 25) -join "`n"
        Fail "$label failed (exit $code).`n$tail"
    }
    return $output
}

function Wk([string] $label, [string[]] $arguments) { Invoke-Tool "WolvenKit $label" $script:Cli $arguments $null }
# WolvenKit 8.20 answers exit code 3 to every FOLDER import, successful or not (measured by
# build-liveries.ps1): the import counts as done only when it imported exactly what we staged.
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
    Invoke-Tool $label $script:UvExe (@('run', '--no-project', '--with', 'pillow==13.0.0', '--with', 'numpy==2.5.4', 'python', '-I', $script) + $arguments) $marker
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

# Extracts the missing $raw depot paths into game/raw (read-only on the game), serializes the
# missing $json ones into game/json under flat names.
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

# --------------------------------------------------------------------------- 0. inputs
Step 'Resolving inputs and tools'
$SpecPath = (Resolve-Path -LiteralPath $Spec).Path
$os = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json -AsHashtable
if ($os.schema -ne 'open77.vehicle-original-stickers/1') { Fail "spec schema must be open77.vehicle-original-stickers/1 ($SpecPath)" }
if ($os.resource -notmatch '^[a-z0-9_-]{1,64}$') { Fail "resource '$($os.resource)' must match [a-z0-9_-]{1,64}" }
if ($os.archiveName -notmatch '^[A-Za-z0-9_]{3,64}$' -or $os.archiveName -match '^Open77(Mirror|RP)?$') { Fail "archiveName '$($os.archiveName)' is invalid or collides with a platform archive" }
if ($Models -and -not $ReviewOnly) { Fail '-Models is for -ReviewOnly iterations: a pack always covers every model of the spec' }
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
if (-not $node) { Fail 'node (Node.js 18+) not found on PATH (archive timestamp normalization, byte scan)' }
if (-not $MeasureWork) { $MeasureWork = Join-Path ([IO.Path]::GetTempPath()) 'open77-vehicle-kit-measure\original-stickers' }
$MeasureWork = [IO.Path]::GetFullPath($MeasureWork)
if ($MeasureWork.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) { Fail "-MeasureWork $MeasureWork is inside the repository; game data must stay outside it" }

if (-not $OutDir) { $OutDir = Join-Path $repo 'artifacts/vehicle-kit/original-stickers' }
$script:OutRoot = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $script:OutRoot | Out-Null
if ($script:OutRoot.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    & git -C $repo check-ignore -q -- (Join-Path $script:OutRoot 'probe.archive')
    if ($LASTEXITCODE -ne 0) { Fail "output folder $script:OutRoot is inside the repository but not git-ignored" }
}
$work = Join-Path $script:OutRoot 'work'
if (-not $Dealer) { $Dealer = Join-Path $repo 'docs/generated/vehicle-components-player-bodies-2.50.json' }
$Dealer = (Resolve-Path -LiteralPath $Dealer).Path
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (-not $GameCache) { $GameCache = Join-Path ([IO.Path]::GetTempPath()) 'open77-vehicle-kit-game\original-stickers' }
$script:GameRoot = [IO.Path]::GetFullPath($GameCache)
if ($script:GameRoot.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) { Fail "-GameCache $script:GameRoot is inside the repository; game files must stay outside it" }
New-Item -ItemType Directory -Force -Path $script:GameRoot | Out-Null
$gameRaw = Join-Path $script:GameRoot 'raw'
$gameFlat = Join-Path $script:GameRoot 'flat'
$gameJson = Join-Path $script:GameRoot 'json'
$meshJsonDir = Join-Path $script:GameRoot 'meshjson'
Write-Host "   WolvenKit $wkVersion  uv $script:UvExe  game $GameDirectory  cache $MeasureWork  game files $script:GameRoot"

# --------------------------------------------------------------------------- 1. placement inputs
Step 'Placement inputs: body-kit cache, raw meshes and material chains as JSON (read-only, cached, never shipped)'
$placeCfgPath = Join-Path $work 'place-cfg.json'
$previewRoot = Join-Path $script:OutRoot 'preview'
$artDir = Join-Path $work 'art'
$placeDir = Join-Path $work 'place'
$placeCfg = [ordered]@{
    spec = $SpecPath; dealer = $Dealer; measureWork = $MeasureWork; meshJson = $meshJsonDir; gameJson = @($gameJson)
    inputsOut = (Join-Path $work 'place-inputs.json'); game = $GameDirectory; cli = $script:Cli
    art = $artDir; out = $placeDir; boards = (Join-Path $previewRoot 'boards'); overviews = (Join-Path $previewRoot 'overview')
    only = ($Models ?? '')
    step = $Step; spacing = $Spacing; offset = $Offset
    limits = [ordered]@{ minCarried = $MinCarried; minVisible = $MinVisible; minOnHost = $MinOnHost; maxFloating = $MaxFloating }
}
Write-Utf8NoBom $placeCfgPath ($placeCfg | ConvertTo-Json -Depth 8)
# The material chains (.mi -> .mi -> .mt) are only known once the meshes and the first .mi
# files are serialized: list, fetch, and list again until nothing is missing.
for ($pass = 1; ; $pass++) {
    Py 'placement inputs' (Join-Path $here 'st_place.py') @('inputs', '--cfg', $placeCfgPath) 'ST_INPUTS_OK' | Out-Null
    $inputs = Get-Content -LiteralPath $placeCfg.inputsOut -Raw | ConvertFrom-Json -AsHashtable
    if (@($inputs.missingModels).Count) {
        if ($pass -gt 1) { Fail "the body-kit cache still lacks $($inputs.missingModels -join ', ') after an extraction" }
        Write-Host "   extracting the body-kit cache for: $($inputs.missingModels -join ', ')"
        Py 'body-kit extract' (Join-Path $here 'st_place.py') @('extract', '--cfg', $placeCfgPath) 'ST_EXTRACT_OK' | Out-Null
        continue
    }
    if ($inputs.complete) { break }
    if ($pass -ge 7) { Fail 'placement inputs still incomplete after 7 passes (material chain deeper than expected?)' }
    Sync-GameFiles @($inputs.materials) @($inputs.materials)
    $needMesh = @($inputs.meshes.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $meshJsonDir ((Flat $_) + '.json'))) } | Sort-Object)
    if ($needMesh.Count) {
        $meshFlat = Reset-Dir (Join-Path $script:GameRoot 'meshflat')
        foreach ($m in $needMesh) { Copy-Item -LiteralPath $inputs.meshes[$m] -Destination (Join-Path $meshFlat (Flat $m)) }
        New-Item -ItemType Directory -Force -Path $meshJsonDir | Out-Null
        Wk "serialize $($needMesh.Count) meshes" @('convert', 'serialize', $meshFlat, '--outpath', $meshJsonDir) | Out-Null
        $null = Reset-Dir $meshFlat
    }
}
Sync-GameFiles @($ContainerMesh) @()
$containerSha = Sha256 (Join-Path $gameRaw $ContainerMesh)
Write-Host "   $($inputs.meshes.Count) stock meshes, $(@($inputs.materials).Count) material instances; container $containerSha"

# --------------------------------------------------------------------------- 2. art + placement
Step 'Motif textures (original art, Pillow)'
$null = Reset-Dir $artDir
if (Test-Path -LiteralPath $previewRoot) { $null = Reset-Dir $previewRoot }
Py 'art' (Join-Path $here 'st_art.py') @('--spec', $SpecPath, '--out', $artDir, '--preview', (Join-Path $previewRoot 'motifs')) 'ST_ART_OK' | Out-Null
$art = Get-Content -LiteralPath (Join-Path $artDir 'art.json') -Raw | ConvertFrom-Json -AsHashtable

Step 'Zones, hosts, fit, decal meshes and the decal budget (numpy), review boards'
$null = Reset-Dir $placeDir
Py 'place' (Join-Path $here 'st_place.py') @('place', '--cfg', $placeCfgPath) 'ST_PLACE_OK' | Out-Null
$placements = Get-Content -LiteralPath (Join-Path $placeDir 'placements.json') -Raw | ConvertFrom-Json -AsHashtable
if ($ReviewOnly) {
    Step 'Done (review only: nothing imported, cooked or packed)'
    Write-Host "   boards    $(Join-Path $previewRoot 'boards')"
    Write-Host "   overview  $(Join-Path $previewRoot 'overview')"
    Write-Host "   placement $(Join-Path $placeDir 'placements.json')"
    Write-Host "VK_ORIGINAL_STICKERS_REVIEW_OK sets=$(@($placements.sets).Count) decals=$($placements.totals.decals)"
    return
}

# --------------------------------------------------------------------------- 3. revision
$hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
$add = { param($text) $hasher.AppendData([Text.Encoding]::UTF8.GetBytes([string] $text + "`n")) }
& $add ((Get-Content -LiteralPath $SpecPath -Raw) -replace "`r`n", "`n")
$sources = @('st_draw.py', 'st_art.py', 'st_place.py', 'st_board.py', 'st_ocook.py', 'lua/stickers_main.lua' | ForEach-Object { Get-Item -LiteralPath (Join-Path $here $_) }) +
    @('lv_cook.py', 'lv_common.py', 'lv_surface.py', 'lv_art.py' | ForEach-Object { Get-Item -LiteralPath (Join-Path $kitRoot "liveries/$_") }) + @(Get-Item -LiteralPath $PSCommandPath)
foreach ($f in ($sources | Sort-Object Name)) {
    & $add $f.Name; & $add ((Get-Content -LiteralPath $f.FullName -Raw) -replace "`r`n", "`n")
}
foreach ($f in (Get-ChildItem -LiteralPath $artDir -Filter '*.png' -File | Sort-Object Name)) { & $add "$($f.Name) $(Sha256 $f.FullName)" }
foreach ($f in (Get-ChildItem -LiteralPath $placeDir -Recurse -Filter '*.glb' -File | Sort-Object FullName)) { & $add "$([IO.Path]::GetRelativePath($placeDir, $f.FullName).Replace('\', '/')) $(Sha256 $f.FullName)" }
& $add "$ContainerMesh $containerSha"
# The trims each set lists come from the component table (placements.json `records`).
& $add "$([IO.Path]::GetFileName($Dealer)) $(Sha256 $Dealer)"
& $add "$wkVersion|tweakxl>=$TweakXlMin|step=$Step|spacing=$Spacing|offset=$Offset"
$revision = ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
$rev12 = $revision.Substring(0, 12)
$prefix = "open77\assets\$($os.resource)\$rev12"
Write-Host "   revision $revision  ->  $prefix"

# --------------------------------------------------------------------------- 4. textures
Step 'Textures: PNG -> xbm with the sticker setups (BC7 sRGB colour + alpha cut-out, BC4 mask)'
$xbm1 = Reset-Dir (Join-Path $work 'xbm/default')
$xbm1Json = Reset-Dir (Join-Path $work 'xbm/default-json')
$xbm2 = Reset-Dir (Join-Path $work 'xbm/final')
$xbm2Json = Reset-Dir (Join-Path $work 'xbm/final-json')
$textures = @()
foreach ($stem0 in ($art.motifs.Keys | Sort-Object)) {
    foreach ($k in 'd', 'm') {
        $depot = "$prefix\textures\${stem0}_$k.xbm"
        $stem = (Flat $depot).Substring(0, (Flat $depot).Length - 4)
        Copy-Item -LiteralPath (Join-Path $artDir "${stem0}_$k.png") -Destination (Join-Path $xbm1 "$stem.png")
        $textures += [ordered]@{ motif = $stem0; depot = $depot; kind = $k; stem = $stem; size = @($art.motifs[$stem0].texture)
            json = (Join-Path $xbm1Json "$stem.xbm.json"); roundtrip = (Join-Path $xbm2Json "$stem.xbm.json") }
    }
}
Wk-ImportFolder 'import textures (default setup)' $xbm1 $textures.Count
Wk 'serialize textures' @('convert', 'serialize', $xbm1, '--outpath', $xbm1Json) | Out-Null
$cookPath = Join-Path $work 'cook.json'
$cook = [ordered]@{
    spec = $SpecPath; placements = (Join-Path $placeDir 'placements.json'); prefix = $prefix; resource = $os.resource
    revision = $revision; wolvenkit = $wkNumeric; textures = $textures; meshes = @(); allowedReferences = $AllowedReferences
    preparedDir = (Join-Path $work 'prepared'); roundtripDir = (Join-Path $work 'roundtrip')
    yamlOut = (Join-Path $work $YamlName); luaOut = (Join-Path $work 'stickers.lua')
    catalogueOut = (Join-Path $work 'catalogue.json'); packageOut = (Join-Path $work 'package.json')
}
Write-Utf8NoBom $cookPath ($cook | ConvertTo-Json -Depth 16)
Py 'xbm setups' (Join-Path $kitRoot 'liveries/lv_cook.py') @('xbm-setup', $cookPath) 'LV_XBM_SETUP_OK' | Out-Null
Wk 'deserialize texture templates' @('convert', 'deserialize', $xbm1Json, '--outpath', $xbm2) | Out-Null
foreach ($t in $textures) { Copy-Item -LiteralPath (Join-Path $xbm1 "$($t.stem).png") -Destination (Join-Path $xbm2 "$($t.stem).png") }
Wk-ImportFolder 'import textures (--keep: our setups)' $xbm2 $textures.Count -Keep
Get-ChildItem -LiteralPath $xbm2 -Filter '*.png' | Remove-Item -Force
Wk 'serialize final textures' @('convert', 'serialize', $xbm2, '--outpath', $xbm2Json) | Out-Null

# --------------------------------------------------------------------------- 5. meshes
Step 'Decal meshes: glb -> WolvenKit import on the container'
$meshDir = Reset-Dir (Join-Path $work 'mesh/import')
$meshJson = Reset-Dir (Join-Path $work 'mesh/import-json')
$meshes = @()
foreach ($set in $placements.sets) {
    foreach ($d in $set.decals) {
        $depot = "$prefix\meshes\$($set.model)\$($set.theme)_$($d.zone).mesh"
        $stem = (Flat $depot).Substring(0, (Flat $depot).Length - 5)
        Copy-Item -LiteralPath (Join-Path $gameRaw $ContainerMesh) -Destination (Join-Path $meshDir "$stem.mesh")
        Copy-Item -LiteralPath (Join-Path $placeDir $d.glb) -Destination (Join-Path $meshDir "$stem.glb")
        $meshes += [ordered]@{ model = $set.model; theme = $set.theme; zone = $d.zone; importedJson = (Join-Path $meshJson "$stem.mesh.json") }
    }
}
Wk-ImportFolder "import $($meshes.Count) meshes (--keep)" $meshDir $meshes.Count -Keep
Get-ChildItem -LiteralPath $meshDir -Filter '*.glb' | Remove-Item -Force
Wk 'serialize meshes' @('convert', 'serialize', $meshDir, '--outpath', $meshJson) | Out-Null
$cook.meshes = $meshes
Write-Utf8NoBom $cookPath ($cook | ConvertTo-Json -Depth 16)

# --------------------------------------------------------------------------- 6. cook
Step 'Cook (material instances, decal meshes and entities, YAML, Lua catalogue)'
$null = Reset-Dir $cook.preparedDir
Py 'cook prepare' (Join-Path $here 'st_ocook.py') @('prepare', $cookPath) 'ST_OCOOK_PREPARED' | Out-Null
$deser = Reset-Dir (Join-Path $work 'deserialized')
Wk 'deserialize' @('convert', 'deserialize', $cook.preparedDir, '--outpath', $deser) | Out-Null
$null = Reset-Dir $cook.roundtripDir
Wk 'round trip serialize' @('convert', 'serialize', $deser, '--outpath', $cook.roundtripDir) | Out-Null
Py 'cook validate' (Join-Path $here 'st_ocook.py') @('validate', $cookPath) 'ST_OCOOK_ROUNDTRIP_OK' | Out-Null
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
foreach ($t in $textures) {
    $dst = Join-Path $stage $t.depot
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath (Join-Path $xbm2 "$($t.stem).xbm") -Destination $dst
    $expected += $t.depot
}
$expected = @($expected | Sort-Object)

# --------------------------------------------------------------------------- 7. archive
Step 'Pack and verify the archive'
$packedDir = Reset-Dir (Join-Path $work 'packed')
Wk 'pack' @('pack', $stage, '--outpath', $packedDir) | Out-Null
$packed = Join-Path $packedDir 'stage.archive'
if (-not (Test-Path -LiteralPath $packed)) { Fail "pack produced no $packed" }
$archive = Join-Path $packedDir "$($os.archiveName).archive"
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
$vanilla = @((Join-Path $gameRaw $ContainerMesh)) + @($inputs.meshes.Values) + @($inputs.materials | ForEach-Object { Join-Path $gameRaw $_ })
$scanPlan = Join-Path $work 'scan-plan.json'
Write-Utf8NoBom $scanPlan ([ordered]@{ vanillaFiles = @($vanilla | Sort-Object -Unique); reportDir = $work } | ConvertTo-Json -Depth 4)
$scanJson = Join-Path $work 'scan.json'
if (Test-Path -LiteralPath $scanJson) { Remove-Item -LiteralPath $scanJson -Force }
$scanOut = & $node (Join-Path $kitRoot 'plates/native/plates.cjs') scan $scanPlan $stage 2>&1 | ForEach-Object { "$_" }
$scanCode = $LASTEXITCODE
$scanLine = $scanOut | Where-Object { $_ -match '^PLATES_SCAN_OK' } | Select-Object -First 1
if ($scanCode -ne 0) {
    # plates.cjs fails on any shared binary block. Our meshes keep the container's CR2W layout,
    # so they share its names table (offset + hash of each name) with every mesh of the game:
    # st_ocook.py scan-names accepts a block only inside a verified names table, nothing else.
    if (-not (Test-Path -LiteralPath $scanJson) -or -not ($scanOut -match 'PLATES_FAILED scan: \d+ binary 64-byte blocks')) {
        Fail "no-vanilla-bytes scan failed (exit $scanCode).`n$(($scanOut | Select-Object -Last 10) -join "`n")"
    }
    $namesOut = Py 'no-vanilla-bytes scan: names tables' (Join-Path $here 'st_ocook.py') @('scan-names', $scanPlan) 'ST_SCAN_NAMES_OK'
    $scanLine = $namesOut | Where-Object { $_ -match '^ST_SCAN_NAMES_OK' } | Select-Object -First 1
}
if (-not $scanLine) { Fail "no-vanilla-bytes scan printed no result line.`n$(($scanOut | Select-Object -Last 10) -join "`n")" }
if ($scanCode -eq 0) { Write-Host "   $scanLine" }      # the names-table check prints its own line

# --------------------------------------------------------------------------- 8. ZIP
Step 'preload_mod ZIP (archive + TweakXL YAML)'
$resourceDir = Reset-Dir (Join-Path $script:OutRoot "resource/$($os.resource)")
$zipName = "$($os.archiveName)_$rev12.zip"
$zipPath = Join-Path $resourceDir "dist/$zipName"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zipPath) | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipArchive = "archive/pc/mod/$($os.archiveName).archive"
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

# --------------------------------------------------------------------------- 9. resource
Step 'Draft Light RP resource'
New-Item -ItemType Directory -Force -Path (Join-Path $resourceDir 'server') | Out-Null
Copy-Item -LiteralPath $cook.luaOut -Destination (Join-Path $resourceDir 'server/stickers.lua')
Copy-Item -LiteralPath $cook.catalogueOut -Destination (Join-Path $resourceDir 'catalogue.json')
Write-Utf8NoBom (Join-Path $resourceDir 'open77.lua') (@'
-- Light RP ORIGINAL vehicle stickers (DRAFT). Ships the TweakXL records Vehicle.o77_os_* (one
-- decal: our .ent -> our .mesh -> our .xbm, hung on a stock panel) and Vehicle.o77_sticker_os_*
-- (one set: a theme on a model, its decal list), as one inert preload_mod: the launcher
-- projects it before the game starts and TweakXL creates the records at boot. Needs the
-- TweakXL loader resource in resources.load, and the wave-2 natives (registerStickers,
-- setStickers) to be applied. Lab command: /@@COMMAND@@ (restricted).
-- Generated by scripts/vehicle-kit/stickers/build-original-stickers.ps1 (revision @@REV@@).
-- Edit the spec, not this file.
resource '@@RESOURCE@@'
version '@@VERSION@@'
auto_start true
dependency 'tweakxl >=@@TWEAKXL@@'
preload_mod 'dist/@@ZIP@@'
server_script 'server/stickers.lua'
server_script 'server/main.lua'
-- world.vehicles + world.vehicles.appearance: registerStickers / setStickers for the lab command.
permissions { 'world.vehicles', 'world.vehicles.appearance' }
'@).Replace('@@REV@@', $rev12).Replace('@@RESOURCE@@', $os.resource).Replace('@@VERSION@@', $ResourceVersion).Replace('@@TWEAKXL@@', $TweakXlMin).Replace('@@ZIP@@', $zipName).Replace('@@COMMAND@@', $os.command)
Write-Utf8NoBom (Join-Path $resourceDir 'server/main.lua') ((Get-Content -LiteralPath (Join-Path $here 'lua/stickers_main.lua') -Raw).Replace('@@RESOURCE@@', $os.resource))

# --------------------------------------------------------------------------- 10. manifest
Step 'Manifest'
$yamlCopy = Join-Path $script:OutRoot $YamlName
Copy-Item -LiteralPath $cook.yamlOut -Destination $yamlCopy -Force
$manifest = [ordered]@{
    schema = 'open77.vehicle-original-stickers.build/1'
    revision = $revision; depotPrefix = $prefix
    tools = [ordered]@{ wolvenkit = $wkVersion; node = (& $node --version); tweakxlMin = $TweakXlMin }
    templatesNotShipped = [ordered]@{ $ContainerMesh = $containerSha }
    referencedNotShipped = $AllowedReferences
    readNotShipped = [ordered]@{ meshes = $inputs.meshes.Count; materialInstances = @($inputs.materials).Count }
    scan = $scanLine
    placement = [ordered]@{ limits = $placements.limits; totals = $placements.totals; decalsPerModel = $placements.decalsPerModel; skipped = $placements.skipped
                            droppedSets = @($placements.droppedSets | ForEach-Object { [ordered]@{ model = $_.model; theme = $_.theme; decals = $_.decals; reason = $_.reason } })
                            modelsWithoutSets = $placements.modelsWithoutSets; trimsRefused = $placements.trimsRefused }
    yaml = [ordered]@{ name = $YamlName; sha256 = (Sha256 $yamlCopy); bytes = (Get-Item -LiteralPath $yamlCopy).Length;
                       decalRecords = @($package.decalRecords).Count; stickerRecords = @($package.stickerRecords).Count }
    zip = [ordered]@{ name = $zipName; sha256 = (Sha256 $zipPath); bytes = $zipBytes; entries = $zipEntries }
    archive = [ordered]@{ name = "$($os.archiveName).archive"; sha256 = (Sha256 $archive); bytes = (Get-Item -LiteralPath $archive).Length; entries = $entries.Count }
    textures = $package.texturesChecked
    previews = @(Get-ChildItem -LiteralPath $previewRoot -Recurse -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { [IO.Path]::GetRelativePath($script:OutRoot, $_.FullName).Replace('\', '/') })
    deployed = $false
}
Copy-Item -LiteralPath (Join-Path $placeDir 'placements.json') -Destination (Join-Path $script:OutRoot 'placements.json') -Force
Write-Utf8NoBom (Join-Path $script:OutRoot 'manifest.json') ($manifest | ConvertTo-Json -Depth 16)
$sumFiles = @($zipPath, $archive, $yamlCopy, (Join-Path $resourceDir 'open77.lua'), (Join-Path $resourceDir 'server/main.lua'),
    (Join-Path $resourceDir 'server/stickers.lua'), (Join-Path $resourceDir 'catalogue.json'))
$sums = foreach ($f in $sumFiles) { "{0}  {1}" -f (Sha256 $f), [IO.Path]::GetRelativePath($script:OutRoot, $f).Replace('\', '/') }
Write-Utf8NoBom (Join-Path $script:OutRoot 'SHA256SUMS') (($sums -join "`n") + "`n")

Step 'Done'
Write-Host "   resource  $resourceDir"
Write-Host "   zip       $zipPath ($zipBytes bytes)"
Write-Host "   yaml      $yamlCopy"
Write-Host "   boards    $(Join-Path $previewRoot 'boards')"
Write-Host "   overview  $(Join-Path $previewRoot 'overview')"
Write-Host "VK_ORIGINAL_STICKERS_OK revision=$rev12 sets=$(@($package.stickerRecords).Count) decals=$(@($package.decalRecords).Count) files=$($entries.Count) zip=$zipBytes (not deployed)"
