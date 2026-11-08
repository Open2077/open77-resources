#requires -Version 7.0
<#
.SYNOPSIS
    Preview PNGs of the plate pack for the owner and the lead: the design items drawn in 2D,
    and before/after renders of every plate mesh showing where factory print is left visible.

.DESCRIPTION
    Needs a build of design original first (build-plates.ps1): it reads that build's report
    (work/generated/generated.json) for the item layouts and the quad placements.

    1. Items. The original design's library items (one per plate mesh, at its quad's aspect)
       and the superseded fit-rule items (Car 990x300, Moto 600x540) are drawn with
       System.Drawing from the same layouts and colours as native/inkwidget.cjs, in the
       game's own OFL fonts (Orbitron Bold, Rajdhani Bold), exported from the local game to
       TTF with WolvenKit (cached, git-ignored). Text that is too wide shrinks to fit, as
       inkText's AdjustToSize policy does.
    2. Views. native/plates.cjs views ray-traces each plate mesh with its quad from six
       directions (front, 30 and 60 deg above, 45 deg below, 60 deg left and right), in
       three rows: before (fit rule), after (cover rule, plate route) and mount (cover rule
       on our mounted plate, holo chunk masked). The plate body is grey, the factory print
       (the holo chunk) hatched magenta, the quad shows the item image. Print pixels are
       counted in each view.
    3. Sheets. One sheet per plate mesh with captions, plus the item sheet.

    These are offline renders, not game renders: lighting, the screen material and the car
    around the plate are not reproduced. The in-game look must be checked in the lab.
    -InGameShot crops a real in-game screenshot next to them.

    Outputs go to artifacts/vehicle-kit-plates/previews (git-ignored). Reads the game folder
    only to export the fonts once, never writes to it.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/plates/preview-plates.ps1
    pwsh -File scripts/vehicle-kit/plates/preview-plates.ps1 -InGameShot <shot.png> -InGameRect 440,615,300,150
#>
[CmdletBinding()]
param(
    [string[]] $Text = @('OP77-ABC', 'NC-2077', 'OP77LAB'),
    [string] $InGameShot,
    [string] $InGameRect = '440,615,300,150',     # x,y,w,h of the plate in the shot
    [string] $BuildDir,
    [string] $OutDir,
    [string] $GameDirectory,
    [string] $WolvenKitCli
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$kitRoot = $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $kitRoot '../../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')
function Fail([string] $text) { throw "vehicle-kit/plates preview: $text" }

if (-not $GameDirectory) { foreach ($scope in 'Process', 'User') { if (-not $GameDirectory) { $GameDirectory = [Environment]::GetEnvironmentVariable('OP77_GAME_DIR', $scope) } } }
if (-not $GameDirectory -or -not (Test-Path -LiteralPath (Join-Path $GameDirectory 'archive\pc\content'))) { Fail "game directory not found (got '$GameDirectory')" }
if (-not $BuildDir) { $BuildDir = Join-Path $repo 'artifacts/vehicle-kit-plates/original' }
if (-not $OutDir) { $OutDir = Join-Path $repo 'artifacts/vehicle-kit-plates/previews' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if ($OutDir.StartsWith([IO.Path]::GetFullPath($GameDirectory), [StringComparison]::OrdinalIgnoreCase)) { Fail 'the output folder may not be inside the game directory' }
$planFile = Join-Path $BuildDir 'work/generated/plan.json'
$reportFile = Join-Path $BuildDir 'work/generated/generated.json'
foreach ($f in $planFile, $reportFile) { if (-not (Test-Path -LiteralPath $f)) { Fail "no ${f}: run build-plates.ps1 -Design original first" } }
$itemDir = Join-Path $OutDir 'items'
New-Item -ItemType Directory -Force -Path $OutDir, $itemDir | Out-Null

$spec = Get-Content -LiteralPath (Join-Path $kitRoot 'specs/plates.json') -Raw | ConvertFrom-Json
$design = $spec.designs.original
$report = Get-Content -LiteralPath $reportFile -Raw | ConvertFrom-Json
$items = @($report.items)
$legacy = @($report.legacyItems.PSObject.Properties.Value)

# --------------------------------------------------------------------------- fonts (TTF from the game, cached)
$fontDir = Join-Path $OutDir 'fonts'
$wanted = [ordered]@{ text = 'base\gameplay\gui\fonts\orbitron\orbitron-bold.fnt'; region = 'base\gameplay\gui\fonts\raj\raj-bold.fnt' }
$ttf = [ordered]@{}
foreach ($k in $wanted.Keys) { $ttf[$k] = Join-Path $fontDir (($wanted[$k] -replace '\\', '/') -replace '\.fnt$', '.ttf') }
if (@($ttf.Values | Where-Object { -not (Test-Path -LiteralPath $_) }).Count) {
    $cli = Find-WolvenKitCli -Explicit $WolvenKitCli
    $rx = '^(' + ((@($wanted.Values) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
    $out = & $cli uncook (Join-Path $GameDirectory 'archive\pc\content') --regex $rx --outpath $fontDir --gamepath $GameDirectory --verbosity Minimal 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "font export failed: $($out | Select-Object -Last 5)" }
}
foreach ($f in $ttf.Values) { if (-not (Test-Path -LiteralPath $f)) { Fail "no TTF at $f" } }

Add-Type -AssemblyName System.Drawing
$collection = [Drawing.Text.PrivateFontCollection]::new()
foreach ($f in $ttf.Values) { $collection.AddFontFile($f) }
$families = @{}
foreach ($fam in $collection.Families) { $families[$fam.Name] = $fam }
function Family([string] $file)
{
    $probe = [Drawing.Text.PrivateFontCollection]::new(); $probe.AddFontFile($file)
    $name = $probe.Families[0].Name; $probe.Dispose()
    return $families[$name]
}
$textFamily = Family $ttf.text
$regionFamily = Family $ttf.region

function Color([double[]] $c) { [Drawing.Color]::FromArgb([int]($c[3] * 255), [int]([Math]::Min(1, $c[0]) * 255), [int]([Math]::Min(1, $c[1]) * 255), [int]([Math]::Min(1, $c[2]) * 255)) }

# Centred text in a box, shrunk until it fits (inkText textOverflowPolicy AdjustToSize).
function Draw-Fitted($g, [Drawing.FontFamily] $family, [string] $s, [double] $size, [Drawing.RectangleF] $box, [Drawing.Color] $color, [double] $tracking)
{
    $format = [Drawing.StringFormat]::GenericTypographic.Clone()
    $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
    $format.FormatFlags = $format.FormatFlags -bor [Drawing.StringFormatFlags]::NoWrap
    $font = $null
    for ($px = $size; $px -gt 8; $px -= 2) {
        if ($font) { $font.Dispose() }
        $font = [Drawing.Font]::new($family, [float] $px, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $m = $g.MeasureString($s, $font, [Drawing.PointF]::new(0, 0), $format)
        if (($m.Width + $tracking * $s.Length) -le $box.Width -and $m.Height -le $box.Height * 1.25) { break }
    }
    $brush = [Drawing.SolidBrush]::new($color)
    $g.DrawString($s, $font, $brush, $box, $format)
    $brush.Dispose(); $font.Dispose(); $format.Dispose()
}

# One library item, from its layout (inkwidget.cjs layoutFor / LEGACY_LAYOUTS): the
# background over the whole item, the design inside the face (the holo rectangle).
function Render-Item($L, [string] $s)
{
    $c = $design.colors
    $F = $L.face
    $bmp = [Drawing.Bitmap]::new([int] $L.w, [int] $L.h)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $fill = { param($color, $x, $y, $w, $h) $b = [Drawing.SolidBrush]::new((Color $color)); $g.FillRectangle($b, [float] $x, [float] $y, [float] $w, [float] $h); $b.Dispose() }
    & $fill $c.background 0 0 $L.w $L.h
    & $fill $c.band $F.x $F.y $F.w $L.band
    $label = $design.regionLabel.($L.label)
    Draw-Fitted $g $regionFamily $label.ToUpperInvariant() $L.bandFont ([Drawing.RectangleF]::new($F.x, $F.y, $F.w, $L.band)) (Color $c.region) 6
    & $fill $c.border $F.x ($F.y + $L.band) $F.w $L.border
    & $fill $c.border $F.x ($F.y + $F.h - $L.border) $F.w $L.border
    & $fill $c.border $F.x $F.y $L.border $F.h
    & $fill $c.border ($F.x + $F.w - $L.border) $F.y $L.border $F.h
    $pad = $L.border * 3
    Draw-Fitted $g $textFamily $s.ToUpperInvariant() $L.textFont ([Drawing.RectangleF]::new($F.x + $pad, $F.y + $L.textTop, $F.w - 2 * $pad, $F.h - $L.textTop - $pad)) (Color $c.text) 4
    $g.Dispose()
    return $bmp
}

function Save([Drawing.Image] $img, [string] $path) { $img.Save($path, [Drawing.Imaging.ImageFormat]::Png); Write-Host "   $path"; return $path }
function Slug([string] $s) { ($s -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant() }
$made = @()

# --------------------------------------------------------------------------- 1. items
Write-Host "== items (2D, game fonts $($textFamily.Name) + $($regionFamily.Name))"
foreach ($L in $items) {
    $bmp = Render-Item $L $Text[0]; $made += Save $bmp (Join-Path $itemDir "$($L.name).png"); $bmp.Dispose()
    foreach ($s in $Text) { $bmp = Render-Item $L $s; $made += Save $bmp (Join-Path $OutDir "original-$($L.name.ToLowerInvariant())-$(Slug $s).png"); $bmp.Dispose() }
}
foreach ($L in $legacy) { $bmp = Render-Item $L $Text[0]; $made += Save $bmp (Join-Path $itemDir "legacy-$($L.name).png"); $bmp.Dispose() }

# Item sheet: every sample text on every item, all at the same height.
$cellH = 200; $gap = 30
$widths = @($items | ForEach-Object { [int]($_.w * $cellH / $_.h) })
$sheet = [Drawing.Bitmap]::new([int](($widths | Measure-Object -Sum).Sum + ($items.Count + 1) * $gap), [int]($Text.Count * ($cellH + $gap) + $gap + 24))
$g = [Drawing.Graphics]::FromImage($sheet); $g.Clear([Drawing.Color]::FromArgb(255, 58, 60, 66)); $g.InterpolationMode = 'HighQualityBicubic'
$caption = [Drawing.Font]::new('Arial', 13, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$x = $gap
for ($k = 0; $k -lt $items.Count; $k++) {
    $L = $items[$k]
    $g.DrawString("$($L.name)  $($L.w)x$($L.h)", $caption, [Drawing.Brushes]::White, $x, 6)
    for ($i = 0; $i -lt $Text.Count; $i++) { $b = Render-Item $L $Text[$i]; $g.DrawImage($b, $x, 24 + $gap + $i * ($cellH + $gap), $widths[$k], $cellH); $b.Dispose() }
    $x += $widths[$k] + $gap
}
$g.Dispose()
$made += Save $sheet (Join-Path $OutDir 'original-sheet.png'); $sheet.Dispose()

# --------------------------------------------------------------------------- 2. views
Write-Host '== views (offline ray trace of each plate mesh)'
$out = & node (Join-Path $kitRoot 'native/plates.cjs') views $planFile $OutDir 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0 -or -not ($out -match '^PLATES_VIEWS')) { Fail "views failed:`n$($out -join "`n")" }
$out | Where-Object { $_ -match '^PLATES_' } | ForEach-Object { Write-Host "   $_" }
$viewInfo = Get-Content -LiteralPath (Join-Path $OutDir 'views/views.json') -Raw | ConvertFrom-Json

# --------------------------------------------------------------------------- 3. sheets
$rowNames = [ordered]@{ before = 'BEFORE: fit rule (2026-11-05)'; after = 'AFTER: cover rule, plate route'; mount = 'AFTER: cover rule, mount route (holo masked)' }
$vw = [int] $viewInfo.size[0]; $vh = [int] $viewInfo.size[1]
$label = 230; $capH = 22; $title = 40
$small = [Drawing.Font]::new('Arial', 13, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$big = [Drawing.Font]::new('Arial', 18, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$red = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 255, 90, 200)); $green = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 120, 230, 140))
foreach ($mesh in $viewInfo.meshes.PSObject.Properties) {
    $stem = $mesh.Name -replace '\.mesh$', ''
    $views = @($viewInfo.views)
    $img = [Drawing.Bitmap]::new($label + $views.Count * $vw, $title + $rowNames.Count * ($vh + $capH))
    $g = [Drawing.Graphics]::FromImage($img); $g.Clear([Drawing.Color]::FromArgb(255, 30, 32, 38))
    $p = $report.plates.PSObject.Properties | Where-Object { $_.Name.EndsWith("\$($mesh.Name)") } | Select-Object -First 1
    $c = $p.Value.cover; $l = $p.Value.legacy
    $g.DrawString("$($mesh.Name): magenta = factory print. Quad before $($l.sizeMm[0]) x $($l.sizeMm[1]) mm, after $($c.sizeMm[0]) x $($c.sizeMm[1]) mm ($($c.marginMm) mm margin, $($c.gapMm) mm gap), item $($mesh.Value.item)", $big, [Drawing.Brushes]::White, 8, 10)
    $r = 0
    foreach ($row in $rowNames.Keys) {
        $y = $title + $r * ($vh + $capH)
        $g.DrawString($rowNames[$row], $small, [Drawing.Brushes]::White, [Drawing.RectangleF]::new(8, $y + $vh / 2 - 20, $label - 16, 60))
        for ($k = 0; $k -lt $views.Count; $k++) {
            $v = $views[$k]
            $file = Join-Path $OutDir "views/$stem-$row-$($v.name).png"
            $tile = [Drawing.Bitmap]::FromFile($file); $g.DrawImage($tile, $label + $k * $vw, $y, $vw, $vh); $tile.Dispose()
            $px = [int] $mesh.Value.rows.$row.($v.name)
            $g.DrawString("$($v.name): $px print px", $small, ($(if ($px) { $red } else { $green })), $label + $k * $vw + 6, $y + $vh + 3)
        }
        $r++
    }
    $g.Dispose()
    $made += Save $img (Join-Path $OutDir "cover-$stem.png"); $img.Dispose()
}

if ($InGameShot) {
    Write-Host '== in-game shot (cropped, not touched)'
    if (-not (Test-Path -LiteralPath $InGameShot)) { Fail "no screenshot at $InGameShot" }
    $shot = [Drawing.Bitmap]::FromFile([IO.Path]::GetFullPath($InGameShot))
    $n = @($InGameRect -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { [int] $_ })
    if ($n.Count -ne 4) { Fail "-InGameRect wants x,y,w,h (got '$InGameRect')" }
    $rect = [Drawing.Rectangle]::new($n[0], $n[1], $n[2], $n[3])
    $scale = 3
    $crop = [Drawing.Bitmap]::new($rect.Width * $scale, $rect.Height * $scale)
    $g = [Drawing.Graphics]::FromImage($crop); $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($shot, [Drawing.Rectangle]::new(0, 0, $crop.Width, $crop.Height), $rect, [Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $made += Save $crop (Join-Path $OutDir 'ingame-crop.png')
    $crop.Dispose(); $shot.Dispose()
}
$red.Dispose(); $green.Dispose(); $small.Dispose(); $big.Dispose(); $caption.Dispose()
$collection.Dispose()
Write-Host "PLATES_PREVIEWS $($made.Count) files in $OutDir"
