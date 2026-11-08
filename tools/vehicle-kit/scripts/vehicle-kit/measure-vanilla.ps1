#requires -Version 7.0
<#
.SYNOPSIS
    Measures a vanilla vehicle part (pivot, spin axis, radius, LODs, materials, slot binding)
    without copying anything into the repository.

.DESCRIPTION
    Extracts the matching game files into -OutDir (default: %TEMP%\open77-vehicle-kit-measure,
    refused inside the repository), serializes them to JSON, exports the meshes to glb with
    WolvenKit (MeshOnly) and prints their layout with native/measure-mesh.cjs. The game folder
    is only read. Nothing produced here may be committed: it is game data.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/measure-vanilla.ps1
    pwsh -File scripts/vehicle-kit/measure-vanilla.ps1 -Name 'v_sport2_quadra_type66__ext01_wheel_f_01' -Folder 'base\vehicles\sport\v_sport2_quadra_type66\entities'
#>
[CmdletBinding()]
param(
    # Base name shared by the .mesh (under <Folder>\meshes) and the wheel .ent (under <Folder>).
    [string] $Name = 'v_standard2_archer_hella__ext01_wheel_fl_01',
    [string] $Folder = 'base\vehicles\standard\v_standard2_archer_hella\entities',
    # Extra entity base names to dump next to it (the right wheel reuses the left mesh).
    [string[]] $Entities = @('v_standard2_archer_hella__ext01_wheel_fr_01'),
    [string] $GameDirectory,
    [string] $OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'open77-vehicle-kit-measure'),
    [string] $WolvenKitCli
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')
$cli = Find-WolvenKitCli -Explicit $WolvenKitCli
$node = (Get-Command node -ErrorAction SilentlyContinue)?.Source
if (-not $node) { throw 'measure-vanilla: node (Node.js 18+) not found on PATH' }

foreach ($scope in 'Process', 'User') {
    if (-not $GameDirectory) { $GameDirectory = [Environment]::GetEnvironmentVariable('OP77_GAME_DIR', $scope) }
}
$content = Join-Path "$GameDirectory" 'archive\pc\content'
if (-not (Test-Path -LiteralPath $content)) { throw "measure-vanilla: no game content under '$GameDirectory' (pass -GameDirectory or set OP77_GAME_DIR)" }

$out = [IO.Path]::GetFullPath($OutDir)
if ($out.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) { throw "measure-vanilla: $out is inside the repository; game data must stay outside it" }
foreach ($d in 'raw', 'json', 'glb') { New-Item -ItemType Directory -Force -Path (Join-Path $out $d) | Out-Null }

$folderRx = [regex]::Escape($Folder.TrimEnd('\'))
$names = (@($Name) + $Entities | ForEach-Object { [regex]::Escape($_) }) -join '|'
$regex = "^$folderRx\\(meshes\\($([regex]::Escape($Name)))\.mesh|($names)\.ent)$"
$meshRx = "^$folderRx\\meshes\\$([regex]::Escape($Name))\.mesh$"

function Wk([string[]] $arguments)
{
    $output = & $cli @arguments --verbosity Minimal 2>&1 | ForEach-Object { "$_" }
    $output | Where-Object { $_ -match 'Error' } | ForEach-Object { Write-Host "   $_" }
    if ($LASTEXITCODE -ne 0) { throw "measure-vanilla: cp77tools $($arguments[0]) failed (exit $LASTEXITCODE)" }
}

Write-Host "Extracting $regex"
Wk @('extract', $content, '--regex', $regex, '--outpath', (Join-Path $out 'raw'), '--gamepath', $GameDirectory)
$files = @(Get-ChildItem -LiteralPath (Join-Path $out 'raw') -Recurse -File | Where-Object { $_.Extension -in '.mesh', '.ent' })
if (-not $files) { throw "measure-vanilla: nothing matched $regex" }
Wk (@('convert', 'serialize') + $files.FullName + @('--outpath', (Join-Path $out 'json')))
# MeshOnly: geometry without materials (the material export needs a depot and is not needed here).
Wk @('uncook', $content, '--regex', $meshRx, '--outpath', (Join-Path $out 'glb'), '--gamepath', $GameDirectory, '--mesh-export-type', 'MeshOnly')

$report = @(Get-ChildItem -LiteralPath (Join-Path $out 'json') -File -Filter '*.json' | Sort-Object Name) +
          @(Get-ChildItem -LiteralPath (Join-Path $out 'glb') -Recurse -File -Filter '*.glb')
& $node (Join-Path $PSScriptRoot 'native/measure-mesh.cjs') @($report.FullName)
if ($LASTEXITCODE -ne 0) { throw 'measure-vanilla: measure-mesh.cjs failed' }
Write-Host "`nGame data left in $out (outside the repository; do not commit it)."
