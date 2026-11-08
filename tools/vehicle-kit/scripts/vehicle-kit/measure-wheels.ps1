#requires -Version 7.0
<#
.SYNOPSIS
    Measures the stock wheels (rim, tyre, rim centre) of the Light RP dealer models and
    writes the rim mount table, without copying any game file into the repository.

.DESCRIPTION
    Reads docs/generated/vehicle-components-dealer-2.50.json for the rim and tyre
    components of each model's player appearance (plus any other mesh bound to a wheel,
    brake or axle slot, such as a motorcycle brake), then:

      1. extracts those meshes and the models' .app files from the game archives
         (read-only) into -OutDir, outside the repository;
      2. serializes them to JSON and exports the meshes to glb (MeshOnly);
      3. measure-wheels.cjs measures every finest-LOD vertex (radius around the spin
         axis X, outboard face, width) and reads each component's local transform and
         visual scale from the .app, into <OutDir>/measurements.json;
      4. with -Spec, computes the fit of the spec's rims on every model (scale, X offset,
         hide list, right-side turn, per-slot overrides) and writes -FitOut. Run it after
         build-pack to also compare the depth of each rim centre with the stock one.

    Only numbers and component names leave the scratch folder (into -FitOut). Never commit
    anything from -OutDir: it is game data.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/measure-wheels.ps1 -Spec scripts/vehicle-kit/specs/lightrp-rims.json
    pwsh -File scripts/vehicle-kit/measure-wheels.ps1 -SkipExtract -Spec scripts/vehicle-kit/specs/lightrp-rims.json
#>
[CmdletBinding()]
param(
    [string] $Dealer,
    [string] $Spec,
    [string] $FitOut,
    [string] $GameDirectory,
    [string] $OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'open77-vehicle-kit-wheels'),
    [string] $WolvenKitCli,
    # build-pack's work/parts folder, for the centre-depth check (default: the spec's
    # artifacts folder when it has been built).
    [string] $PartsDir,
    # Reuse an earlier extraction (only the measurement and the fit run again).
    [switch] $SkipExtract
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $Dealer) { $Dealer = Join-Path $repo 'docs/generated/vehicle-components-dealer-2.50.json' }
if ($Spec -and -not $FitOut) { $FitOut = [IO.Path]::ChangeExtension((Resolve-Path -LiteralPath $Spec).Path, $null).TrimEnd('.') + '-fit.json' }
$node = (Get-Command node -ErrorAction SilentlyContinue)?.Source
if (-not $node) { throw 'measure-wheels: node (Node.js 18+) not found on PATH' }

$out = [IO.Path]::GetFullPath($OutDir)
if ($out.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) { throw "measure-wheels: $out is inside the repository; game data must stay outside it" }
foreach ($d in 'raw', 'json', 'glb') { New-Item -ItemType Directory -Force -Path (Join-Path $out $d) | Out-Null }

# --------------------------------------------------------------------------- plan
# Rim and tyre components of the player appearance, from the offline inventory.
$doc = Get-Content -LiteralPath $Dealer -Raw | ConvertFrom-Json -AsHashtable
$models = @()
$meshes = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$apps = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($m in $doc.models) {
    $player = $m.playerAppearance
    $app = @($m.appearances | Where-Object { $_.name -eq $player }) | Select-Object -First 1
    if (-not $app) { throw "measure-wheels: $($m.key) has no entity appearance '$player'" }
    $comps = @()
    $seen = @{}
    foreach ($c in $m.components) {
        if (-not $c.inPlayerAppearance) { continue }
        $flags = @($c.flags)
        if ($flags -contains 'shadow') { continue }
        $mesh = if ($c.ContainsKey('mesh')) { $c['mesh'] } else { $null }
        $parent = if ($c.ContainsKey('parent')) { $c['parent'] } else { $null }
        $slot = if ($parent -and $parent.ContainsKey('slotName')) { $parent['slotName'] } else { $null }
        # Rims and tyres, plus any other mesh bound to a wheel, brake or axle slot (the Apollo
        # front brake and hub): the fit reports what else shares the wheel centre.
        $role = if ($flags -contains 'rim') { 'rim' } elseif ($flags -contains 'tire') { 'tire' }
                elseif ($mesh -and $slot -match '^(wheel|brake|axle)') { 'other' } else { $null }
        if (-not $role) { continue }
        $key = "$($c.name)|$mesh"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $comps += [ordered]@{ name = $c.name; type = $c.type; mesh = $mesh; slot = $slot; role = $role; flags = $flags }
        if ($mesh) { [void] $meshes.Add($mesh) }
    }
    [void] $apps.Add($app.app)
    $models += [ordered]@{
        key = $m.key; label = $m.label; record = $m.record; vehicleType = $m.tweakdb.vehicleType
        entity = $m.entity.path; app = $app.app; appearance = $app.appearanceName; playerAppearance = $player
        tweakdbWheels = $m.wheels; wheelSlots = $m.wheelSlots; components = $comps
    }
}
$plan = [ordered]@{ dealer = [IO.Path]::GetRelativePath($repo, $Dealer).Replace('\', '/'); gameVersion = $doc.gameVersion
                    outDir = $out; meshes = @($meshes); apps = @($apps); models = $models }
$planPath = Join-Path $out 'plan.json'
[IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 32), [Text.UTF8Encoding]::new($false))
Write-Host "measure-wheels: $($models.Count) models, $($meshes.Count) meshes, $($apps.Count) .app files"

# --------------------------------------------------------------------------- extract
if (-not $SkipExtract) {
    . (Join-Path $repo 'scripts/find-wolvenkit.ps1')
    $cli = Find-WolvenKitCli -Explicit $WolvenKitCli
    foreach ($scope in 'Process', 'User') {
        if (-not $GameDirectory) { $GameDirectory = [Environment]::GetEnvironmentVariable('OP77_GAME_DIR', $scope) }
    }
    if (-not $GameDirectory -or -not (Test-Path -LiteralPath (Join-Path $GameDirectory 'archive\pc\content'))) {
        throw "measure-wheels: no game content under '$GameDirectory' (pass -GameDirectory or set OP77_GAME_DIR)"
    }
    function Wk([string[]] $arguments)
    {
        $output = & $cli @arguments --verbosity Minimal 2>&1 | ForEach-Object { "$_" }
        $output | Where-Object { $_ -match 'Error' } | ForEach-Object { Write-Host "   $_" }
        if ($LASTEXITCODE -ne 0) { throw "measure-wheels: cp77tools $($arguments[0]) failed (exit $LASTEXITCODE)" }
    }
    $all = @($meshes) + @($apps)
    # One regex per 40 paths: the player-vehicle plan (every appearance of ~90 records)
    # names hundreds of meshes, past the command-line length a single regex would need.
    function Chunks([string[]] $paths)
    {
        for ($i = 0; $i -lt $paths.Count; $i += 40) {
            $part = $paths[$i..([Math]::Min($i + 39, $paths.Count - 1))]
            , ('^(' + (($part | ForEach-Object { [regex]::Escape($_.ToLowerInvariant()) }) -join '|') + ')$')
        }
    }
    # uncook also writes the meshes' textures and material templates next to the glb: game
    # data, left in the scratch folder with the rest.
    # Base content first, then EP1: an EP1 copy of the same path overwrites the base one,
    # as EP1 archives shadow the base game.
    foreach ($folder in 'content', 'ep1') {
        $src = Join-Path $GameDirectory "archive\pc\$folder"
        if (-not (Test-Path -LiteralPath $src)) { continue }
        Write-Host "Extracting from $folder"
        foreach ($rx in @(Chunks $all)) { Wk @('extract', $src, '--regex', $rx, '--outpath', (Join-Path $out 'raw'), '--gamepath', $GameDirectory) }
        foreach ($meshRx in @(Chunks @($meshes))) { Wk @('uncook', $src, '--regex', $meshRx, '--outpath', (Join-Path $out 'glb'), '--gamepath', $GameDirectory, '--mesh-export-type', 'MeshOnly') }
    }
    Remove-Item -LiteralPath (Join-Path $out 'json') -Recurse -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $out 'json') | Out-Null
    function Serialize([string[]] $depotPaths)
    {
        $missing = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path $out 'raw') $_)) })
        if ($missing) { throw "measure-wheels: not extracted: $($missing -join ', ')" }
        $files = @($depotPaths | ForEach-Object { Get-Item -LiteralPath (Join-Path (Join-Path $out 'raw') $_) })
        # convert serialize flattens names: every basename must be unique.
        $dupes = @($files | Group-Object Name | Where-Object Count -gt 1)
        if ($dupes) { throw "measure-wheels: duplicate basenames: $($dupes.Name -join ', ')" }
        for ($i = 0; $i -lt $files.Count; $i += 25) {
            $batch = $files[$i..([Math]::Min($i + 24, $files.Count - 1))]
            Wk (@('convert', 'serialize') + $batch.FullName + @('--outpath', (Join-Path $out 'json')))
        }
    }
    function Extract([string[]] $depotPaths)
    {
        foreach ($folder in 'content', 'ep1') {
            $src = Join-Path $GameDirectory "archive\pc\$folder"
            if (-not (Test-Path -LiteralPath $src)) { continue }
            foreach ($rx in @(Chunks $depotPaths)) { Wk @('extract', $src, '--regex', $rx, '--outpath', (Join-Path $out 'raw'), '--gamepath', $GameDirectory) }
        }
    }
    # measure-wheels.cjs reads the meshes from their glb and the components from the .app
    # JSON: only the .app files are serialized (mesh basenames repeat across vehicles).
    Serialize @($apps)
    # Slot frames: each entity's vehicle_slots (slot -> bone + relative transform) and the
    # reference pose of its deformation rig.
    $ents = @($models | ForEach-Object { $_.entity } | Sort-Object -Unique)
    Write-Host "Extracting $($ents.Count) entity templates"
    Extract $ents
    Serialize $ents
    $rigs = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $ents) {
        $text = Get-Content -LiteralPath (Join-Path (Join-Path $out 'json') ((Split-Path -Leaf $e) + '.json')) -Raw
        # JSON escapes the backslashes of depot paths.
        foreach ($m in [regex]::Matches($text, '"([A-Za-z0-9_\\]+\.rig)"')) { [void] $rigs.Add($m.Groups[1].Value.Replace('\\', '\')) }
    }
    Write-Host "Extracting $($rigs.Count) rigs"
    Extract @($rigs)
    Serialize @($rigs)
}

# --------------------------------------------------------------------------- measure + fit
$tool = Join-Path $PSScriptRoot 'measure-wheels.cjs'
& $node $tool measure $planPath (Join-Path $out 'measurements.json')
if ($LASTEXITCODE -ne 0) { throw 'measure-wheels: measurement failed' }
if ($Spec) {
    if (-not $PartsDir) {
        $resource = (Get-Content -LiteralPath $Spec -Raw | ConvertFrom-Json).resource
        $PartsDir = Join-Path $repo "artifacts/vehicle-kit/$resource/work/parts"
    }
    $fitArgs = @((Join-Path $out 'measurements.json'), (Resolve-Path -LiteralPath $Spec).Path, $FitOut)
    if (Test-Path -LiteralPath $PartsDir) { $fitArgs += (Resolve-Path -LiteralPath $PartsDir).Path }
    & $node $tool fit @fitArgs
    if ($LASTEXITCODE -ne 0) { throw 'measure-wheels: fit failed' }
}
Write-Host "`nGame data left in $out (outside the repository; do not commit it)."
