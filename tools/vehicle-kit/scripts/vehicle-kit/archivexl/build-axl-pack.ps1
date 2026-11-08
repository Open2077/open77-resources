#requires -Version 7.0
<#
.SYNOPSIS
    Builds the ArchiveXL lab packs of the vehicle-customization campaign: E0.6 (appearances
    added to a vanilla vehicle) and E0.7 route W (a text widget over the rear plate).

.DESCRIPTION
    For each pack: read the vanilla entity, appearance resource and referenced resources
    from the local game (read-only, cached under the git-ignored output folder) -> generate
    the WolvenKit JSON of a standalone .app and an ArchiveXL patch .ent -> deserialize ->
    round trip check -> .archive (timestamps pinned) -> .xl -> deterministic preload_mod
    ZIP -> lab resource (open77.lua + server.lua + dist/) and, for E0.7, the hand-installed
    lab REDscript, compile-checked offline with the game's own scc.exe in a scratch tree.

    LAB ONLY. Each new appearance definition is a copy of the vanilla player_01 definition
    of the target vehicle, read from the local game at build time: the archive therefore
    embeds game data and must never be committed, uploaded to the Workshop or distributed.
    Never touches the game folder (extraction and the scc bundle are copies), never
    launches the game, never deploys.

    Same specs + same scripts + same tool version + same game files = same revision, so the
    depot paths (open77\assets\<resource>\<revision12>\...), the archive and the ZIP are
    byte-identical across reruns.

.EXAMPLE
    pwsh -File scripts/vehicle-kit/archivexl/build-axl-pack.ps1
    pwsh -File scripts/vehicle-kit/archivexl/build-axl-pack.ps1 -Pack e07 -SkipRedscriptCheck
#>
[CmdletBinding()]
param(
    [ValidateSet('e06', 'e07', 'all')] [string] $Pack = 'all',
    [string] $OutDir,
    [string] $GameDirectory,
    [string] $WolvenKitCli,
    [switch] $SkipRedscriptCheck,
    [switch] $RefreshVanilla,
    [int] $RedscriptTimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$kitRoot = $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $kitRoot '../../..'))
. (Join-Path $repo 'scripts/find-wolvenkit.ps1')

$Packs = [ordered]@{
    e06 = [ordered]@{ spec = 'specs/e06-appearance.json'; server = 'lua/e06_server.lua'; reds = @() }
    e07 = [ordered]@{ spec = 'specs/e07-plate.json'; server = 'lua/e07_server.lua'; reds = @('reds/Open77VehiclePlateLab.reds') }
}
$LabPermissions = @('world.vehicles', 'world.vehicles.appearance', 'network.events', 'players.life.read')
$FixedZipTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail([string] $text) { throw "vehicle-kit/archivexl: $text" }

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
    $errors = @($output | Where-Object { $_ -match '\[\s*\d+:\s*Error\s*\]|Error:|AXL_FAILED|AXL_ARCHIVE_FAILED' })
    foreach ($line in $output) {
        if ($line -match '^AXL_|\[\s*\d+:\s*(Error|Warning)\s*\]|Error') { Write-Host "   $line" }
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

function Get-Prop($object, [string] $name) { $p = $object.PSObject.Properties[$name]; if ($p) { return $p.Value } return $null }

# Every depot path a spec reads or references: they must all exist in the local game.
function Get-SpecDepotPaths($spec)
{
    $paths = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    [void] $paths.Add($spec.entity)
    [void] $paths.Add($spec.appearanceResource)
    $screen = Get-Prop $spec 'screenMesh'
    if ($screen) { [void] $paths.Add($screen.path) }
    foreach ($c in $spec.components.PSObject.Properties.Value) {
        foreach ($field in 'mesh', 'widget') { $v = Get-Prop $c $field; if ($v) { [void] $paths.Add($v) } }
    }
    return @($paths)
}

function Test-LabRedscript([string[]] $labFiles, [string] $work)
{
    $scc = Join-Path $GameDirectory 'engine\tools\scc.exe'
    if (-not (Test-Path -LiteralPath $scc)) { Fail "scc.exe not found at $scc (-SkipRedscriptCheck to skip)" }
    $bundle = Join-Path $GameDirectory 'r6\cache\final.redscripts.bk'      # redscript's vanilla backup, when it made one
    if (-not (Test-Path -LiteralPath $bundle)) { $bundle = Join-Path $GameDirectory 'r6\cache\final.redscripts' }
    $root = Reset-Dir (Join-Path $work 'scc')
    $scripts = Join-Path $root 'r6\scripts'
    New-Item -ItemType Directory -Force -Path (Join-Path $scripts 'Open77'), (Join-Path $scripts 'Open77Lab'), (Join-Path $root 'r6\cache') | Out-Null
    # The lab scripts call Open77 natives declared by the client's own REDscript: compile them together.
    Copy-Item -Path (Join-Path $repo 'client\redscript\*.reds') -Destination (Join-Path $scripts 'Open77')
    foreach ($f in $labFiles) { Copy-Item -LiteralPath $f -Destination (Join-Path $scripts 'Open77Lab') }
    # A copy, never a hardlink: scc renames the bundle it finds next to the scripts.
    $cache = Join-Path $root 'r6\cache\final.redscripts'
    Copy-Item -LiteralPath $bundle -Destination $cache
    $stdout = Join-Path $root 'scc-stdout.txt'
    $process = Start-Process -FilePath $scc -ArgumentList @('-compile', "`"$scripts`"", "`"$cache`"") -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError (Join-Path $root 'scc-stderr.txt')
    # On a compile error scc opens a modal window and never exits when its output is
    # redirected: watch its output and kill it once it has reported.
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
    $labWarnings = @($lines | Where-Object { $_ -match '\[WARN' -and $_ -match 'Open77Lab' })
    $summary = @($lines | Where-Object { $_ -match 'Completed with' }) | Select-Object -Last 1
    $exit = if ($killed) { 'killed' } else { $process.ExitCode }
    if ($errors.Count -or $exit -ne 0) {
        $context = ($lines | Where-Object { $_ -notmatch '^r6\\' } | Select-Object -Last 40) -join "`n"
        Fail "lab REDscript does not compile (scc exit $exit):`n$context"
    }
    if (-not ($lines -match 'Succesfully written|Successfully written')) { Fail 'scc reported no error but wrote no bundle' }
    foreach ($w in $labWarnings) { Write-Warning $w }
    Write-Host "   scc: $summary (lab-script warnings: $($labWarnings.Count))"
    return [ordered]@{ compiler = 'engine\tools\scc.exe'; result = 'ok'; summary = "$summary"; labWarnings = $labWarnings.Count; bundle = (Split-Path -Leaf $bundle) }
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

if (-not $OutDir) { $OutDir = Join-Path $repo 'artifacts/vehicle-kit-archivexl' }
$script:OutRoot = [IO.Path]::GetFullPath($OutDir)
if ($script:OutRoot.StartsWith($GameDirectory, [StringComparison]::OrdinalIgnoreCase)) { Fail 'the output folder may not be inside the game directory' }
New-Item -ItemType Directory -Force -Path $script:OutRoot | Out-Null
if ($script:OutRoot.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    & git -C $repo check-ignore -q -- (Join-Path $script:OutRoot 'probe.archive')
    if ($LASTEXITCODE -ne 0) { Fail "output folder $script:OutRoot is inside the repository but not git-ignored" }
}
Write-Host "   WolvenKit $wkVersion, node $nodeVersion, game $GameDirectory"
Write-Host "   output    $script:OutRoot"

$selected = if ($Pack -eq 'all') { @($Packs.Keys) } else { @($Pack) }
$results = [ordered]@{}

foreach ($key in $selected) {
    $def = $Packs[$key]
    $specPath = Join-Path $kitRoot $def.spec
    $spec = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json
    if ($spec.schema -ne 'open77.vehicle-kit.archivexl/1') { Fail "$($def.spec): unexpected schema $($spec.schema)" }
    if ($spec.resource -notmatch '^[a-z][a-z0-9_]{2,63}$') { Fail "$($def.spec): resource name $($spec.resource) is not a valid resource slug" }
    if ($spec.archiveName -notmatch '^[a-z0-9_]+$') { Fail "$($def.spec): archive name $($spec.archiveName) must be lowercase" }
    $packRoot = Join-Path $script:OutRoot $key
    New-Item -ItemType Directory -Force -Path $packRoot | Out-Null

    # ----------------------------------------------------------------------- 1. vanilla (cached)
    Step "$key ($($spec.experiment)): vanilla resources (read-only, cached, never shipped)"
    $depotPaths = Get-SpecDepotPaths $spec
    $vanillaDir = Join-Path $packRoot 'vanilla'
    $local = { param($p) Join-Path $vanillaDir ($p -replace '\\', '/') }
    $missing = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (& $local $_)) })
    if ($RefreshVanilla -or $missing.Count) {
        $vanillaDir = Reset-Dir $vanillaDir
        $pattern = '^(' + (($depotPaths | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
        foreach ($folder in 'archive\pc\content', 'archive\pc\ep1') {
            $source = Join-Path $GameDirectory $folder
            if (-not (Test-Path -LiteralPath $source)) { continue }
            $still = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (& $local $_)) })
            if (-not $still.Count) { break }
            Wk "extract from $folder" @('extract', $source, '--regex', $pattern, '--outpath', $vanillaDir, '--gamepath', $GameDirectory) | Out-Null
        }
        $missing = @($depotPaths | Where-Object { -not (Test-Path -LiteralPath (& $local $_)) })
        if ($missing.Count) { Fail "not found in the game archives: $($missing -join ', ')" }
    }
    $vanillaHashes = [ordered]@{}
    foreach ($p in $depotPaths) { $vanillaHashes[$p] = Sha256 (& $local $p) }
    $vanillaJsonDir = Join-Path $packRoot 'vanilla-json'
    $toSerialize = @($spec.entity, $spec.appearanceResource)
    $screen = Get-Prop $spec 'screenMesh'
    if ($screen) { $toSerialize += $screen.path }
    $jsonOf = @{}
    foreach ($p in $toSerialize) {
        $leaf = ($p -split '\\')[-1]
        $json = Join-Path $vanillaJsonDir "$leaf.json"
        $stamp = "$json.sha256"
        if ($RefreshVanilla -or -not (Test-Path -LiteralPath $json) -or -not (Test-Path -LiteralPath $stamp) -or (Read-Text $stamp).Trim() -ne $vanillaHashes[$p]) {
            New-Item -ItemType Directory -Force -Path $vanillaJsonDir | Out-Null
            Wk "serialize $leaf" @('convert', 'serialize', (& $local $p), '--outpath', $vanillaJsonDir) | Out-Null
            if (-not (Test-Path -LiteralPath $json)) { Fail "serialize produced no $json" }
            Write-Utf8NoBom $stamp $vanillaHashes[$p]
        }
        $jsonOf[$p] = $json
    }
    foreach ($p in $depotPaths) { Write-Host "   $($vanillaHashes[$p].Substring(0, 16))  $p" }

    # ----------------------------------------------------------------------- 2. revision
    $pipelineFiles = @(Get-ChildItem -LiteralPath (Join-Path $kitRoot 'native') -Filter '*.cjs' -File | Sort-Object Name) +
                     @(Get-Item -LiteralPath $PSCommandPath) + @(Get-Item -LiteralPath (Join-Path $kitRoot $def.server)) +
                     @($def.reds | ForEach-Object { Get-Item -LiteralPath (Join-Path $kitRoot $_) })
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $add = { param($text) $hasher.AppendData([Text.Encoding]::UTF8.GetBytes([string] $text + "`n")) }
    & $add (Read-Text $specPath)
    foreach ($f in $pipelineFiles) { & $add $f.Name; & $add (Read-Text $f.FullName) }
    & $add $wkVersion
    foreach ($p in $depotPaths) { & $add "$p=$($vanillaHashes[$p])" }
    $revision = ([BitConverter]::ToString($hasher.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
    $rev12 = $revision.Substring(0, 12)
    $prefix = "open77\assets\$($spec.resource)\$rev12"
    Write-Host "   revision $revision  ->  $prefix"

    # ----------------------------------------------------------------------- 3. generate
    Step "$key`: generate, deserialize, round trip"
    $work = Join-Path $packRoot 'work'
    $genDir = Reset-Dir (Join-Path $work 'generated')
    $genJsonDir = Join-Path $genDir 'json'
    $vanillaPlan = [ordered]@{ ent = $jsonOf[$spec.entity]; app = $jsonOf[$spec.appearanceResource] }
    if ($screen) { $vanillaPlan.screenMesh = $jsonOf[$screen.path] }
    $planFile = Join-Path $genDir 'plan.json'
    Write-Utf8NoBom $planFile ([ordered]@{ spec = $specPath; prefix = $prefix; outDir = $genJsonDir; vanilla = $vanillaPlan } | ConvertTo-Json -Depth 8)
    $generator = Join-Path $kitRoot 'native/axl-generate.cjs'
    Invoke-Tool 'generate' $node @($generator, $planFile) 'AXL_GENERATED' | Out-Null
    $report = Get-Content -LiteralPath (Join-Path $genDir 'generated.json') -Raw | ConvertFrom-Json
    $expected = @($report.files | Sort-Object)
    foreach ($f in $expected) { if (-not $f.StartsWith("$prefix\")) { Fail "generated file $f is outside $prefix" } }

    $stageDir = Reset-Dir (Join-Path $work 'stage')
    $stagePrefix = Join-Path $stageDir $prefix
    New-Item -ItemType Directory -Force -Path $stagePrefix | Out-Null
    $jsonFiles = @(Get-ChildItem -LiteralPath $genJsonDir -Filter '*.json' -File | Sort-Object Name | ForEach-Object FullName)
    Wk 'deserialize' (@('convert', 'deserialize') + $jsonFiles + @('--outpath', $stagePrefix)) | Out-Null
    $staged = @(Get-ChildItem -LiteralPath $stageDir -Recurse -File | ForEach-Object { $_.FullName.Substring($stageDir.Length + 1) } | Sort-Object)
    if (Compare-Object $staged $expected) { Fail "staged files differ from the generated list:`n$(Compare-Object $staged $expected | Out-String)" }
    $roundtripDir = Reset-Dir (Join-Path $work 'roundtrip')
    Wk 'round trip serialize' @('convert', 'serialize', $stageDir, '--outpath', $roundtripDir) | Out-Null
    Invoke-Tool 'round trip check' $node @($generator, 'validate', $planFile, $roundtripDir) 'AXL_ROUNDTRIP_OK' | Out-Null

    # ----------------------------------------------------------------------- 4. archive
    Step "$key`: pack and verify the archive"
    $packedDir = Reset-Dir (Join-Path $work 'packed')
    Wk 'pack' @('pack', $stageDir, '--outpath', $packedDir) | Out-Null
    $packed = Join-Path $packedDir 'stage.archive'
    if (-not (Test-Path -LiteralPath $packed)) { Fail "pack produced no $packed" }
    $archive = Join-Path $packedDir "$($spec.archiveName).archive"
    Move-Item -LiteralPath $packed -Destination $archive -Force
    Invoke-Tool 'normalize archive' $node @((Join-Path $kitRoot 'native/normalize-archive.cjs'), $archive) 'AXL_ARCHIVE_NORMALIZED' | Out-Null
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
        $receipts += [ordered]@{ path = $rel; sha256 = $h; bytes = (Get-Item -LiteralPath $a).Length }
    }

    # ----------------------------------------------------------------------- 5. .xl
    $props = @('appearances')
    if (@($spec.entityVisualTags).Count) { $props += 'visualTags' }
    $xlText = @"
# Open77 lab pack $($spec.archiveName) ($($spec.experiment)), revision $rev12. LAB ONLY: embeds copies of
# vanilla appearance data, never distribute. Generated by scripts/vehicle-kit/archivexl/build-axl-pack.ps1.
# The patch .ent adds appearance entries to the vanilla entity ($($props -join ' + ')); its bare
# entEntity root is not merged because 'entity' and 'components' are not in props.
resource:
  patch:
    $($report.entPatch):
      props: [ $($props -join ', ') ]
      targets:
        - $($spec.entity)
"@
    $xlName = "$($spec.archiveName).archive.xl"
    $xlPath = Join-Path $packedDir $xlName
    Write-Utf8NoBom $xlPath $xlText

    # ----------------------------------------------------------------------- 6. preload_mod ZIP + lab resource
    Step "$key`: preload_mod ZIP and lab resource"
    $resourceDir = Reset-Dir (Join-Path $packRoot "resource/$($spec.resource)")
    $zipName = "$($spec.archiveName)_$rev12.zip"
    $zipPath = Join-Path $resourceDir "dist/$zipName"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zipPath) | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipLayout = [ordered]@{ "archive/pc/mod/$($spec.archiveName).archive" = $archive; "archive/pc/mod/$xlName" = $xlPath }
    $fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    try {
        $zip = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($name in $zipLayout.Keys) {
            $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $FixedZipTime
            $dst = $entry.Open(); $src = [IO.File]::OpenRead($zipLayout[$name])
            try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
        }
        $zip.Dispose()
    } finally { $fs.Dispose() }
    $check = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try { $zipEntries = @($check.Entries | ForEach-Object { $_.FullName }) } finally { $check.Dispose() }
    if (Compare-Object $zipEntries @($zipLayout.Keys)) { Fail "ZIP layout is wrong: $($zipEntries -join ', ')" }

    $permissionList = ($LabPermissions | ForEach-Object { "'$_'" }) -join ', '
    Write-Utf8NoBom (Join-Path $resourceDir 'open77.lua') @"
-- Open77 vehicle-customization lab, experiment $($spec.experiment). LAB ONLY: never start it on a public server.
-- Generated by scripts/vehicle-kit/archivexl/build-axl-pack.ps1 (revision $rev12). Edit the spec, not this file.
-- The preload_mod embeds copies of vanilla appearance data: never publish it to the Workshop.
resource '$($spec.resource)'
version '0.1.0'
auto_start false
reload_policy 'reconnect'
server_script 'server.lua'
preload_mod 'dist/$zipName'
permissions { $permissionList }
"@
    $serverSource = Join-Path $kitRoot $def.server
    $head = [IO.File]::ReadAllBytes($serverSource)
    if ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) { Fail "$($def.server) has a BOM: a Lua resource must not" }
    $serverText = (Read-Text $serverSource).Replace('@@REVISION@@', $rev12)
    Write-Utf8NoBom (Join-Path $resourceDir 'server.lua') $serverText

    # ----------------------------------------------------------------------- 7. lab REDscript (E0.7)
    $redsInfo = $null
    if ($def.reds.Count) {
        Step "$key`: lab REDscript (hand install, never in the ZIP)"
        $labDir = Reset-Dir (Join-Path $packRoot 'lab-install')
        $labScripts = Join-Path $labDir 'r6\scripts\Open77Lab'
        New-Item -ItemType Directory -Force -Path $labScripts | Out-Null
        $labFiles = @()
        foreach ($r in $def.reds) {
            $src = Join-Path $kitRoot $r
            $dst = Join-Path $labScripts (Split-Path -Leaf $r)
            Write-Utf8NoBom $dst (Read-Text $src)
            $labFiles += $dst
        }
        $redsInfo = [ordered]@{ installUnder = 'r6/scripts/Open77Lab/'; files = @($labFiles | ForEach-Object { [ordered]@{ name = (Split-Path -Leaf $_); sha256 = (Sha256 $_) } }) }
        if ($SkipRedscriptCheck) { Write-Warning 'lab REDscript NOT compile-checked (-SkipRedscriptCheck)'; $redsInfo.check = 'skipped' }
        else { $redsInfo.check = Test-LabRedscript $labFiles $work }
    }

    # ----------------------------------------------------------------------- 8. manifest
    $manifest = [ordered]@{
        schema = 'open77.vehicle-kit.archivexl-build/1'
        experiment = $spec.experiment
        resource = $spec.resource
        record = $spec.record
        entity = $spec.entity
        revision = $revision
        prefix = $prefix
        labOnly = 'the archive embeds copies of vanilla appearance definitions read from the local game: never commit, upload or distribute it'
        tools = [ordered]@{ wolvenkit = $wkVersion; node = $nodeVersion }
        vanilla = $vanillaHashes
        appearances = @($report.definitions | ForEach-Object {
            $d = $_
            $entry = @($report.entries | Where-Object { $_.appearanceName -eq $d.name })
            [ordered]@{ serverString = $d.name; entry = ($entry.Count -gt 0); expect = $d.expect }
        })
        files = $receipts
        archive = [ordered]@{ path = $archive; sha256 = (Sha256 $archive); bytes = (Get-Item -LiteralPath $archive).Length; entries = $entries }
        xl = [ordered]@{ path = $xlPath; sha256 = (Sha256 $xlPath); text = $xlText }
        zip = [ordered]@{ path = $zipPath; sha256 = (Sha256 $zipPath); bytes = (Get-Item -LiteralPath $zipPath).Length; entries = $zipEntries }
        resourceDir = $resourceDir
        redscript = $redsInfo
    }
    Write-Utf8NoBom (Join-Path $packRoot 'manifest.json') ($manifest | ConvertTo-Json -Depth 16)
    $sums = @("$($manifest.archive.sha256)  $($spec.archiveName).archive", "$($manifest.xl.sha256)  $xlName", "$($manifest.zip.sha256)  $zipName")
    if ($redsInfo) { foreach ($f in $redsInfo.files) { $sums += "$($f.sha256)  $($f.name)" } }
    Write-Utf8NoBom (Join-Path $packRoot 'SHA256SUMS') ($sums -join "`n")
    $results[$key] = $manifest
    Write-Host "   archive $($manifest.archive.sha256)  $archive"
    Write-Host "   zip     $($manifest.zip.sha256)  $zipPath"
    Write-Host "   resource $resourceDir"
}

Step 'Done'
foreach ($key in $results.Keys) {
    $m = $results[$key]
    Write-Host ("AXL_PACK_OK {0} {1} revision={2} archive={3} zip={4}" -f $key, $m.resource, $m.revision.Substring(0, 12), $m.archive.sha256, $m.zip.sha256)
}
