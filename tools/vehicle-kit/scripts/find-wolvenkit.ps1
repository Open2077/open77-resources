#requires -Version 7.0
<#
.SYNOPSIS
    Resolves the WolvenKit CLI (cp77tools.exe or WolvenKit.CLI.exe), or fails
    with every location it tried.

.DESCRIPTION
    The asset scripts used to hard-code 'E:\Apps\WolvenKit.Console\WolvenKit.CLI.exe',
    which is one developer's layout: on a machine without an E: drive every asset
    build failed on a path that told the reader nothing about where to put the
    tool. This resolves the CLI the same way launch-debug.ps1 resolves
    OP77_GAME_DIR and launch-ghidra.ps1 resolves the JDK -- explicit argument,
    then environment, then the usual install locations, then PATH -- and when it
    finds nothing it prints every location it looked in.

    Environment variables are read from the process scope AND the user scope.
    That is not redundancy: a shell opened before a variable was created never
    inherits it, which is the normal case for an agent session and a recurring
    source of "it works in my terminal" on this workstation.

    Dot-source it and call Find-WolvenKitCli:

        . "$PSScriptRoot\find-wolvenkit.ps1"
        $cli = Find-WolvenKitCli -Explicit $WolvenKitCli

.PARAMETER Explicit
    A caller-supplied path. Wins when it exists; fails loudly when it does not,
    rather than silently falling back to some other install.
#>

function Find-WolvenKitCli
{
    [CmdletBinding()]
    param(
        [string] $Explicit
    )

    $tried = [System.Collections.Generic.List[string]]::new()

    function Test-Candidate([string] $Path, [string] $Origin)
    {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        $tried.Add(("  {0,-22} {1}" -f $Origin, $Path))
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
        return $null
    }

    # 1. Explicit argument. An explicit path that does not exist is an error,
    #    never a reason to search: silently using a different WolvenKit than the
    #    one the caller named would produce assets nobody can reproduce.
    if (-not [string]::IsNullOrWhiteSpace($Explicit))
    {
        $resolved = Test-Candidate $Explicit 'argument'
        if ($resolved) { return $resolved }
        throw "WolvenKit.CLI.exe not found at the path given with -WolvenKitCli: $Explicit"
    }

    # 2. Environment, process scope then user scope.
    foreach ($scope in 'Process', 'User')
    {
        $value = [Environment]::GetEnvironmentVariable('OP77_WOLVENKIT_CLI', $scope)
        $resolved = Test-Candidate $value "env:$scope"
        if ($resolved) { return $resolved }
    }

    # 3. The dotnet global tool. This is how WolvenKit's CLI actually installs
    #    on this workstation, and it is named cp77tools.exe -- NOT
    #    WolvenKit.CLI.exe. Looking only for the latter is why the first version
    #    of this helper would have missed a working install sitting right there.
    foreach ($leaf in 'cp77tools.exe', 'WolvenKit.CLI.exe')
    {
        $resolved = Test-Candidate (Join-Path $env:USERPROFILE ".dotnet\tools\$leaf") 'dotnet tools'
        if ($resolved) { return $resolved }
    }

    # 4. Usual install locations. WolvenKit ships the CLI beside the app, so both
    #    the installed layout and a portable unzip are covered.
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\WolvenKit'),
        (Join-Path $env:LOCALAPPDATA 'WolvenKit'),
        (Join-Path ${env:ProgramFiles} 'WolvenKit'),
        (Join-Path ${env:ProgramFiles(x86)} 'WolvenKit'),
        'C:\Tools\WolvenKit',
        'C:\WolvenKit',
        'D:\WolvenKit',
        # A tools folder inside the repository, or beside it.
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\WolvenKit'),
        (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools\WolvenKit'),
        (Join-Path $env:USERPROFILE 'WolvenKit')
    ) | Where-Object { $_ }

    foreach ($root in $roots)
    {
        # Record roots that do not exist too. Filtering them out silently made
        # the failure message list only "PATH", which tells the reader nothing
        # about where the tool is expected to live.
        if (-not (Test-Path -LiteralPath $root))
        {
            $tried.Add(("  {0,-22} {1}" -f 'install (absent)', (Join-Path $root 'cp77tools.exe')))
            continue
        }

        foreach ($leaf in 'cp77tools.exe', 'WolvenKit.CLI.exe', 'WolvenKit.Console\WolvenKit.CLI.exe')
        {
            $resolved = Test-Candidate (Join-Path $root $leaf) 'install'
            if ($resolved) { return $resolved }
        }
        # Installers version the directory (WolvenKit-8.x.y), so look one level
        # down before giving up on this root.
        $nested = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { @((Join-Path $_.FullName 'cp77tools.exe'), (Join-Path $_.FullName 'WolvenKit.CLI.exe')) }
        foreach ($candidate in $nested)
        {
            $resolved = Test-Candidate $candidate 'install (nested)'
            if ($resolved) { return $resolved }
        }
    }

    # 5. PATH, under either name.
    foreach ($name in 'cp77tools', 'WolvenKit.CLI')
    {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        $tried.Add(("  {0,-22} {1}" -f 'PATH', "$name(.exe)"))
        if ($command) { return $command.Source }
    }

    $message = @(
        'WolvenKit.CLI.exe not found. Looked in:'
        $tried
        ''
        'Fix by either:'
        '  - passing -WolvenKitCli <path>, or'
        '  - setting the user environment variable OP77_WOLVENKIT_CLI, e.g.'
        '      [Environment]::SetEnvironmentVariable(''OP77_WOLVENKIT_CLI'', ''C:\Users\<you>\.dotnet\tools\cp77tools.exe'', ''User'')'
        ''
        'A shell opened before that variable existed will not see it; open a new'
        'one, or pass -WolvenKitCli for this run.'
    ) -join [Environment]::NewLine
    throw $message
}
