#requires -Version 7.0
<#
.SYNOPSIS
    Builds the owner review board of a rim pack: labelled PNG contact sheets of every rim
    design in every finish, from the renders build-pack.ps1 made (Cycles CPU).

.DESCRIPTION
    Reads the spec and the pack's build folder (default artifacts/vehicle-kit/<resource>,
    git-ignored) and writes into <build>/board:

      board-all.png         every design (rows) in every finish (columns), 3/4 view;
      board-faces.png       every design face-on in its first finish, a catalogue overview
                            (needs build-pack -PreviewViews 4);
      board-<partId>.png    one sheet per design, its finishes side by side, larger: the
                            3/4 view, and under it the face view when it was rendered.

    Each tile is labelled with the design, the part id, the finish id and its slot
    materials; each sheet carries the pack revision and the triangle count. Composition
    only (System.Drawing): nothing is rendered here, and the GPU is never used.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/rim-board.ps1 -Spec scripts/vehicle-kit/specs/lightrp-rims.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Spec,
    [string] $BuildDir,
    [int] $TileWidth = 400,
    [int] $DesignTileWidth = 560,
    [int] $FaceColumns = 6
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Add-Type -AssemblyName System.Drawing
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$kit = Get-Content -LiteralPath $Spec -Raw | ConvertFrom-Json -AsHashtable
if (-not $BuildDir) { $BuildDir = Join-Path $repo "artifacts/vehicle-kit/$($kit.resource)" }
$BuildDir = [IO.Path]::GetFullPath($BuildDir)
$previewDir = Join-Path $BuildDir 'preview'
$partsDir = Join-Path $BuildDir 'work/parts'
$manifestPath = Join-Path $BuildDir 'manifest.json'
if (-not (Test-Path -LiteralPath $previewDir)) { throw "rim-board: no previews in $previewDir (run build-pack.ps1 without -SkipPreview)" }
$revision = if (Test-Path -LiteralPath $manifestPath) { ([string] (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).revision).Substring(0, 12) } else { 'unknown' }
$boardDir = Join-Path $BuildDir 'board'
New-Item -ItemType Directory -Force -Path $boardDir | Out-Null

$rims = @($kit.parts | Where-Object { $_.kind -eq 'rim' })
if (-not $rims) { throw 'rim-board: the spec has no rim parts' }
# Columns follow each design's own finish order (the spec's order).
$columns = ($rims | ForEach-Object { $_.finishes.Count } | Measure-Object -Maximum).Maximum

function Tile-Path([string] $id, [string] $finish, [string] $view = '34')
{
    $file = Join-Path $previewDir "${id}_${finish}_${view}.png"
    if (-not (Test-Path -LiteralPath $file)) { throw "rim-board: missing render $file" }
    $file
}
# Face views exist when build-pack rendered 4 views; then every rim must have them.
$withFace = Test-Path -LiteralPath (Join-Path $previewDir "$($rims[0].id)_$(@($rims[0].finishes.Keys)[0])_face.png")
function Tris([string] $id)
{
    $meta = @((Join-Path $partsDir "$id/$id.part.json"), (Join-Path $partsDir "$id.part.json")) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $meta) { return $null }
    $m = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json -AsHashtable
    ($m.lods.Values | ForEach-Object { $_.triangles } | Measure-Object -Maximum).Maximum
}
function Finish-Text($part, [string] $finish)
{
    $f = $part.finishes[$finish]
    $order = @('rim_main', 'rim_lip', 'rim_detail') | Where-Object { $f.ContainsKey($_) }
    ($order | ForEach-Object { "$($_.Replace('rim_', '')) $($f[$_])" }) -join ' · '
}

$ink = [Drawing.Color]::FromArgb(235, 236, 238)
$dim = [Drawing.Color]::FromArgb(150, 153, 160)
$bg = [Drawing.Color]::FromArgb(24, 25, 28)
$panel = [Drawing.Color]::FromArgb(34, 36, 40)
$fontTitle = [Drawing.Font]::new('Bahnschrift', 26, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$fontName = [Drawing.Font]::new('Bahnschrift', 19, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$fontSmall = [Drawing.Font]::new('Bahnschrift', 14, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)

function New-Sheet([int] $w, [int] $h)
{
    $bmp = [Drawing.Bitmap]::new($w, $h)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear($bg)
    , @($bmp, $g)
}
function Draw-Text($g, [string] $text, $font, $color, [float] $x, [float] $y)
{
    $brush = [Drawing.SolidBrush]::new($color)
    $g.DrawString($text, $font, $brush, $x, $y)
    $brush.Dispose()
}
function Draw-Tile($g, [string] $file, [int] $x, [int] $y, [int] $w, [string] $line1, [string] $line2)
{
    $img = [Drawing.Image]::FromFile($file)
    try {
        $h = [int] [Math]::Round($w * $img.Height / $img.Width)
        $g.DrawImage($img, $x, $y, $w, $h)
        $brush = [Drawing.SolidBrush]::new($panel)
        $g.FillRectangle($brush, $x, $y + $h, $w, 52)
        $brush.Dispose()
        Draw-Text $g $line1 $fontName $ink ($x + 10) ($y + $h + 4)
        Draw-Text $g $line2 $fontSmall $dim ($x + 10) ($y + $h + 29)
        $h + 52
    }
    finally { $img.Dispose() }
}
function Save-Sheet($sheet, [string] $path)
{
    $sheet[1].Dispose()
    $sheet[0].Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $sheet[0].Dispose()
    Write-Host "   $path"
}

$first = [Drawing.Image]::FromFile((Tile-Path $rims[0].id @($rims[0].finishes.Keys)[0]))
$aspect = $first.Height / $first.Width
$first.Dispose()
$header = 92
$footer = 34
$foot = "Original geometry generated by scripts/vehicle-kit/blender/make_rim.py. Cycles CPU render; the tyre is the generic preview tyre, not a game tyre."

# ------------------------------------------------------------------- one sheet, all designs
$gap = 12
$labelW = 230
$tileH = [int] [Math]::Round($TileWidth * $aspect) + 52
$W = $labelW + $columns * ($TileWidth + $gap) + $gap
$H = $header + $rims.Count * ($tileH + $gap) + $footer
$sheet = New-Sheet $W $H
$g = $sheet[1]
Draw-Text $g "$($kit.resource)  -  rim catalogue, $($rims.Count) designs" $fontTitle $ink 18 16
Draw-Text $g "pack revision $revision   ·   3/4 view of every design in every finish" $fontSmall $dim 20 56
$y = $header
foreach ($p in $rims) {
    $tris = Tris $p.id
    Draw-Text $g $p.label $fontName $ink 18 ($y + 12)
    Draw-Text $g $p.id $fontSmall $dim 18 ($y + 40)
    Draw-Text $g "style $($p.params.style)" $fontSmall $dim 18 ($y + 60)
    if ($tris) { Draw-Text $g "$tris tris, 1 LOD" $fontSmall $dim 18 ($y + 80) }
    $fs = @($p.finishes.Keys)
    for ($c = 0; $c -lt $fs.Count; $c++) {
        $f = $fs[$c]
        $x = $labelW + $c * ($TileWidth + $gap)
        [void] (Draw-Tile $g (Tile-Path $p.id $f) $x $y $TileWidth "$($p.label) · $f" (Finish-Text $p $f))
    }
    $y += $tileH + $gap
}
Draw-Text $g $foot $fontSmall $dim 18 ($H - 26)
Save-Sheet $sheet (Join-Path $boardDir 'board-all.png')

# ------------------------------------------------------------------- catalogue overview, face-on
$sheets = 1
if ($withFace) {
    $faceAspect = 1.0
    $img = [Drawing.Image]::FromFile((Tile-Path $rims[0].id @($rims[0].finishes.Keys)[0] 'face'))
    $faceAspect = $img.Height / $img.Width
    $img.Dispose()
    $cols = [Math]::Min($FaceColumns, $rims.Count)
    $rows = [Math]::Ceiling($rims.Count / $cols)
    $tileH = [int] [Math]::Round($TileWidth * $faceAspect) + 52
    $W = $cols * ($TileWidth + $gap) + $gap
    $H = $header + $rows * ($tileH + $gap) + $footer
    $sheet = New-Sheet $W $H
    $g = $sheet[1]
    Draw-Text $g "$($kit.resource)  -  $($rims.Count) designs, face-on" $fontTitle $ink 18 16
    Draw-Text $g "pack revision $revision   ·   first finish of each design; board-<part>.png shows all of them" $fontSmall $dim 20 56
    for ($i = 0; $i -lt $rims.Count; $i++) {
        $p = $rims[$i]
        $f = @($p.finishes.Keys)[0]
        $tris = Tris $p.id
        $x = $gap + ($i % $cols) * ($TileWidth + $gap)
        $y = $header + [Math]::Floor($i / $cols) * ($tileH + $gap)
        $sub = "$($p.id) · $($p.finishes.Count) finishes" + $(if ($tris) { " · $tris tris" } else { '' })
        [void] (Draw-Tile $g (Tile-Path $p.id $f 'face') $x $y $TileWidth $p.label $sub)
    }
    Draw-Text $g $foot $fontSmall $dim 18 ($H - 26)
    Save-Sheet $sheet (Join-Path $boardDir 'board-faces.png')
    $sheets++
}

# ------------------------------------------------------------------- one sheet per design
$views = @('34') + $(if ($withFace) { @('face') } else { @() })
foreach ($p in $rims) {
    $fs = @($p.finishes.Keys)
    $tileH = [int] [Math]::Round($DesignTileWidth * $aspect) + 52
    $W = $fs.Count * ($DesignTileWidth + $gap) + $gap
    $H = $header + $views.Count * ($tileH + $gap) + $footer
    $sheet = New-Sheet $W $H
    $g = $sheet[1]
    $tris = Tris $p.id
    Draw-Text $g "$($p.label)   ($($p.id))" $fontTitle $ink 18 16
    Draw-Text $g ("style $($p.params.style)   ·   " + $(if ($tris) { "$tris tris, 1 LOD   ·   " } else { '' }) + "$($kit.resource) revision $revision") $fontSmall $dim 20 56
    for ($v = 0; $v -lt $views.Count; $v++) {
        for ($c = 0; $c -lt $fs.Count; $c++) {
            $x = $gap + $c * ($DesignTileWidth + $gap)
            $y = $header + $v * ($tileH + $gap)
            $line1 = if ($views[$v] -eq 'face') { "$($fs[$c]) · face" } else { "$($fs[$c])" }
            [void] (Draw-Tile $g (Tile-Path $p.id $fs[$c] $views[$v]) $x $y $DesignTileWidth $line1 (Finish-Text $p $fs[$c]))
        }
    }
    Draw-Text $g $foot $fontSmall $dim 18 ($H - 26)
    Save-Sheet $sheet (Join-Path $boardDir "board-$($p.id).png")
    $sheets++
}
Write-Host "VK_RIM_BOARD_OK sheets=$sheets -> $boardDir"
