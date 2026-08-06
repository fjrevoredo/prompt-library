#Requires -Version 5.1
<#
.SYNOPSIS
Mirrors this repo's Espanso prompts into the live Espanso config on Windows.

.DESCRIPTION
Copies espanso\match\prompt-library\ from this repo into
<espanso config>\match\prompt-library\, validates the resulting config, then
restarts Espanso and confirms it came back up.

The Windows counterpart of sync-prompts.sh. Uses robocopy, which ships with
Windows 10/11, so no extra tooling is needed.

.PARAMETER DryRun
Show what would change without writing anything. Skips validate and restart.

.PARAMETER NoRestart
Sync and validate, but leave the running daemon alone.

.PARAMETER Target
Sync somewhere else instead of the live config. The leaf folder must be named
'prompt-library'. Implies no validate and no restart, since Espanso does not
read from there.

.EXAMPLE
.\sync-prompts.ps1 -DryRun

.EXAMPLE
.\sync-prompts.ps1

.NOTES
ESPANSO_BIN and ESPANSO_CONFIG_DIR override binary and config-dir lookup.
Espanso honours ESPANSO_CONFIG_DIR too, so the script and the daemon agree.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoRestart,
    [string]$Target
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceDir = Join-Path $PSScriptRoot 'espanso\match\prompt-library'
# The subtree name is also the safety guard: the sync target must end in this.
$SubtreeName = 'prompt-library'

function Die {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("error: $Message")
    exit 1
}

# The Windows installer's directory is not documented upstream, so resolve via
# PATH first and fall back to probing the plausible install locations.
function Resolve-EspansoBin {
    if ($env:ESPANSO_BIN) {
        if (-not (Test-Path -LiteralPath $env:ESPANSO_BIN -PathType Leaf)) {
            Die "ESPANSO_BIN does not point at a file: $($env:ESPANSO_BIN)"
        }
        return $env:ESPANSO_BIN
    }

    # 'espanso env-path register' puts the CLI on PATH; this is the common case.
    foreach ($name in @('espanso', 'espanso.cmd', 'espanso.exe', 'espansod.exe')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }

    $roots = @()
    if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Programs') }

    foreach ($root in $roots) {
        # espanso.exe is the CLI; espansod.exe is the daemon and only a fallback.
        foreach ($exe in @('espanso.exe', 'espansod.exe')) {
            $candidate = Join-Path $root (Join-Path 'Espanso' $exe)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }

    Die "espanso binary not found. Run 'espanso env-path register' to put it on PATH, or set ESPANSO_BIN to its absolute path."
}

function Resolve-ConfigDir {
    param([Parameter(Mandatory)][string]$EspansoBin)

    if ($env:ESPANSO_CONFIG_DIR) { return $env:ESPANSO_CONFIG_DIR }

    $output = & $EspansoBin path config 2>$null
    if ($LASTEXITCODE -eq 0 -and $output) {
        $first = @($output)[0]
        if ($first) { return $first.Trim() }
    }

    if (-not $env:APPDATA) {
        Die "cannot locate the Espanso config dir: APPDATA is unset. Set ESPANSO_CONFIG_DIR."
    }
    return (Join-Path $env:APPDATA 'espanso')
}

# robocopy /MIR deletes whatever is not in the source, so it is only safe inside
# our own subfolder. A mis-resolved config dir must not be able to wipe
# match\base.yml or match\packages\ (which lives *inside* match\).
function Assert-TargetIsSubtree {
    param([Parameter(Mandatory)][string]$Path)
    $leaf = Split-Path -Path $Path.TrimEnd('\', '/') -Leaf
    if ($leaf -ne $SubtreeName) {
        Die "refusing to sync: target leaf folder must be '$SubtreeName', got '$Path'"
    }
}

function Sync-Prompts {
    param(
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][bool]$IsDryRun
    )

    # /MIR == /E + /PURGE, the equivalent of rsync --delete.
    $roboArgs = @(
        $SourceDir.TrimEnd('\', '/'),
        $TargetDir.TrimEnd('\', '/'),
        '/MIR', '/XF', '.DS_Store', '/NJH', '/NJS', '/NP', '/R:2', '/W:2'
    )
    if ($IsDryRun) { $roboArgs += '/L' }

    & robocopy @roboArgs

    # robocopy uses 0-7 for success (bit flags for what it changed) and >=8 for
    # failure, so a nonzero exit is not on its own an error.
    if ($LASTEXITCODE -ge 8) {
        Die "robocopy failed with exit code $LASTEXITCODE"
    }
}

# 'match list' parses the real on-disk config, so a zero exit is a genuine
# YAML + schema check with no extra dependencies.
function Test-EspansoConfig {
    param([Parameter(Mandatory)][string]$EspansoBin)
    & $EspansoBin match list --only-triggers | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Die "Espanso rejected the config. The files are already copied into place; fix the yml in $SourceDir and re-run."
    }
}

# 'espanso restart' reports success even when the worker then dies on startup,
# so confirm the daemon is actually up. 'status' exits 0 running / 4 not running.
function Assert-EspansoRunning {
    param([Parameter(Mandatory)][string]$EspansoBin)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        & $EspansoBin status | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    Die "espanso is not running after restart. Check '$EspansoBin log'."
}

if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    Die "source directory not found: $SourceDir"
}

if (-not (Get-Command robocopy -CommandType Application -ErrorAction SilentlyContinue)) {
    Die "robocopy not found. It ships with Windows 10/11 - check that C:\Windows\System32 is on PATH."
}

$espansoBin = Resolve-EspansoBin

if ($Target) {
    $targetDir = $Target
    $isLive = $false
}
else {
    $configDir = Resolve-ConfigDir -EspansoBin $espansoBin
    # Sanity-check the resolution before building a /MIR target out of it.
    # Espanso creates this directory on first launch.
    if (-not $configDir) {
        Die "could not resolve the Espanso config dir; set ESPANSO_CONFIG_DIR"
    }
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
        Die "resolved Espanso config dir does not exist: $configDir. Start Espanso once, or set ESPANSO_CONFIG_DIR."
    }
    $targetDir = Join-Path $configDir (Join-Path 'match' $SubtreeName)
    $isLive = $true
}

Assert-TargetIsSubtree -Path $targetDir

Write-Host "platform: windows"
Write-Host "syncing $SourceDir -> $targetDir"
Sync-Prompts -TargetDir $targetDir -IsDryRun ([bool]$DryRun)

if ($DryRun) {
    Write-Host 'dry run: nothing written, skipping validate and restart'
    exit 0
}

if (-not $isLive) {
    Write-Host 'custom -Target: skipping validate and restart (Espanso does not read from there)'
    exit 0
}

Test-EspansoConfig -EspansoBin $espansoBin
Write-Host 'config validated'

# auto_restart is on by default, but restarting explicitly makes the result
# deterministic instead of depending on the file watcher.
if ($NoRestart) {
    Write-Host 'skipping restart as requested'
}
else {
    & $espansoBin restart
    Assert-EspansoRunning -EspansoBin $espansoBin
    Write-Host 'espanso restarted and running'
}
