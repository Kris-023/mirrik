<#
.SYNOPSIS
    The half of install.ps1 that only a real Windows machine can answer.

.DESCRIPTION
    tools/windows/test-install.ps1 covers roughly 30 of the 35 case groups by stubbing out
    everything that needs Windows. The rest is exactly the part where a stub proves
    nothing: does the shortcut really carry the hotkey, does the PATH entry in the
    registry really work, is a running .exe really unwritable. This runs those for real
    and then puts the machine back.

    Sandboxed as far as Windows allows: APPDATA and LOCALAPPDATA point into a temp
    directory, so the install folder, the state folder and the Start menu shortcut all
    land there and never touch your real ones.

    The user PATH is the exception, and you should know it before you run this. It lives
    in HKCU\Environment, which no environment variable can redirect, so this really does
    write to your PATH - and then really does put it back, byte for byte including its
    registry type. The raw value is saved first and restored in a finally block, so even
    Ctrl+C or a failed case leaves it as it was. If a run ever dies hard enough to skip
    that, the value is in $env:TEMP\mirrik-testbench-path-backup.txt.

    No -Filter here, unlike its sibling: these cases are one sequence (install, look,
    uninstall, look again) and running half of them would leave the machine half
    installed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/windows/test-install-windows.ps1
#>

$ErrorActionPreference = 'Stop'

$Repo = (Get-Item (Join-Path $PSScriptRoot '../..')).FullName
$Installer = Join-Path $Repo 'install.ps1'
$Release = Join-Path $Repo 'target\release'

$script:pass = 0
$script:fail = 0

# ASCII markers on purpose. Windows PowerShell 5.1 reads a UTF-8 file without a BOM as
# ANSI, and a tick or a cross then arrives as bytes that break the parse. The sibling
# bench ran into exactly that and carries a BOM now; ASCII needs no BOM to survive, so
# this half stays as it is.
function Check([string]$name, [scriptblock]$body) {
    $problems = @(& $body | Where-Object { $_ })
    if ($problems.Count -eq 0) {
        Write-Host "  [ok]   $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "         $_" -ForegroundColor Gray }
        $script:fail++
    }
}

function Get-RawUserPath {
    $key = Get-Item 'HKCU:\Environment'
    if ($null -eq $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames')) {
        return [pscustomobject]@{ Value = $null; Kind = $null }
    }
    [pscustomobject]@{
        Value = $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames')
        Kind  = $key.GetValueKind('Path')
    }
}

function Set-RawUserPath($saved) {
    if ($null -eq $saved.Value) { return }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $key.SetValue('Path', $saved.Value, $saved.Kind) } finally { $key.Close() }
}

# The installer asks; this answers. One line per Read-Host, in order.
function Invoke-Installer([string[]]$Answers, [switch]$Uninstall) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Installer)
    if ($Uninstall) { $arguments += '-Uninstall' }
    ($Answers -join "`r`n") | & powershell.exe @arguments 2>&1 | Out-String
}

# ---------------------------------------------------------------- before anything

if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Write-Error 'This bench is the Windows-only half. On Linux, run tools/windows/test-install.ps1.'
    exit 1
}
foreach ($exe in 'mirrik.exe', 'mirrik-gui.exe') {
    if (-not (Test-Path (Join-Path $Release $exe))) {
        Write-Error "Missing $Release\$exe - build first: cargo build --release -p mirrik-cli -p mirrik-gui"
        exit 1
    }
}

$savedPath = Get-RawUserPath
$backupFile = Join-Path $env:TEMP 'mirrik-testbench-path-backup.txt'
Set-Content -Path $backupFile -Value $savedPath.Value -Encoding utf8

$sandbox = Join-Path $env:TEMP ("mirrik-testbench-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$realAppData = $env:APPDATA
$realLocalAppData = $env:LOCALAPPDATA

Write-Host ''
Write-Host 'install.ps1 - the Windows-only half' -ForegroundColor Cyan
Write-Host '-----------------------------------' -ForegroundColor Cyan
Write-Host "  sandbox:   $sandbox" -ForegroundColor DarkGray
Write-Host "  user PATH: saved, restored at the end (backup: $backupFile)" -ForegroundColor DarkGray
Write-Host ''

try {
    $env:APPDATA = Join-Path $sandbox 'Roaming'
    $env:LOCALAPPDATA = Join-Path $sandbox 'Local'
    # Windows itself would have created this; nothing in install.ps1 does, because on a
    # real machine the Start menu is always already there.
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $startMenu | Out-Null

    $target = Join-Path $env:LOCALAPPDATA 'Programs\Mirrik'
    $shortcut = Join-Path $startMenu 'Mirrik.lnk'
    $cli = Join-Path $target 'mirrik.exe'
    $gui = Join-Path $target 'mirrik-gui.exe'

    # Answers: keep the offered folder, yes to PATH, yes to the shortcut, keep the
    # suggested key. The sandboxed Start menu is empty, so the suggestion never collides
    # and the sequence stays the same on every machine.
    $out = Invoke-Installer @('', 'y', 'y', '')

    Check 'the installer ran to the end' {
        if ($out -notmatch 'Done') { 'no "Done" heading - the run stopped early' }
        if ($out -match 'PowerShell 5.1 or newer') { 'it refused on the PowerShell version' }
    }

    Check 'both programs are in the install folder' {
        if (-not (Test-Path $cli)) { "no mirrik.exe in $target" }
        if (-not (Test-Path $gui)) { "no mirrik-gui.exe in $target" }
    }

    Check 'the installed copy actually runs' {
        $version = & $cli --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { "mirrik --version exited $LASTEXITCODE" }
        if ($version -notmatch 'mirrik \d+\.\d+\.\d+') { "unexpected version line: $($version.Trim())" }
    }

    # This is the case a stub cannot reach: not "we wrote a .lnk" but "Windows reads a
    # hotkey back out of it".
    Check 'the shortcut carries target, folder and hotkey' {
        if (-not (Test-Path $shortcut)) { return "no Mirrik.lnk in $startMenu" }
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
        if ($link.TargetPath -ne $gui) { "target is '$($link.TargetPath)', expected '$gui'" }
        if ($link.WorkingDirectory -ne $target) { "working directory is '$($link.WorkingDirectory)'" }
        if (-not $link.Hotkey) { 'no hotkey on the shortcut' }
        # Windows stores the combination the other way round from how install.ps1 offers
        # it, which is exactly why the installer checks both spellings when looking for
        # clashes. Accept either here rather than pinning the order.
        elseif ($link.Hotkey -notmatch '^(Alt\+Ctrl|Ctrl\+Alt)\+[A-Z0-9]$') {
            "hotkey looks wrong: '$($link.Hotkey)'"
        }
    }

    Check 'the PATH entry is in the registry, and nothing else moved' {
        $now = Get-RawUserPath
        $entries = @($now.Value -split ';' | Where-Object { $_ -ne '' })
        if ($entries -notcontains $target) { "no entry for $target" }
        # The type matters as much as the value: writing it back as a plain string would
        # bake everyone's %USERPROFILE% into a literal path, silently and for good.
        if ($now.Kind -ne $savedPath.Kind) { "registry type changed from $($savedPath.Kind) to $($now.Kind)" }
        $without = ($entries | Where-Object { $_ -ne $target }) -join ';'
        if ($without -ne $savedPath.Value) { 'the rest of the PATH is not what it was' }
    }

    # A child of this process is no help here: Windows hands a new process its parent's
    # environment, not a fresh one, so it would never see the entry no matter what the
    # registry says - that is the whole reason install.ps1 says "open a new terminal".
    # So the probe composes its PATH the way a new session does, machine first then user,
    # and reads both out of the registry itself rather than being handed a value.
    Check 'a new session builds a PATH that finds mirrik' {
        $compose = @'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')
(Get-Command mirrik -ErrorAction SilentlyContinue).Source
'@
        $probe = & powershell.exe -NoProfile -Command $compose 2>&1 | Out-String
        if ($probe.Trim() -ne $cli) { "a fresh session resolves mirrik to '$($probe.Trim())'" }
    }

    Check 'a running .exe cannot be overwritten' {
        $running = Start-Process $gui -PassThru
        try {
            Start-Sleep -Seconds 2
            if ($running.HasExited) { return "the window exited on its own (code $($running.ExitCode))" }
            try {
                Copy-Item (Join-Path $Release 'mirrik-gui.exe') $gui -Force -ErrorAction Stop
                'Windows allowed the copy over a running .exe'
            } catch {
                # The expected outcome. This is what the installer's kill-and-copy dance
                # in step 3 exists for.
            }
        } finally {
            if (-not $running.HasExited) { $running.Kill(); $running.WaitForExit() }
        }
    }

    # ---------------------------------------------------------------- and back out

    $out = Invoke-Installer @('y') -Uninstall

    Check 'uninstall removes all four pieces' {
        if (Test-Path $target) { "the install folder is still there: $target" }
        if (Test-Path $shortcut) { 'the shortcut is still there' }
        if (Test-Path (Join-Path $env:LOCALAPPDATA 'mirrik')) { 'the state folder is still there' }
        $now = Get-RawUserPath
        if ($now.Value -ne $savedPath.Value) { 'the PATH is not byte-for-byte what it was' }
        if ($now.Kind -ne $savedPath.Kind) { "registry type left as $($now.Kind)" }
    }

    Check 'uninstalling twice says so instead of failing' {
        $again = Invoke-Installer @('y') -Uninstall
        if ($again -notmatch 'nothing to remove') { "no 'nothing to remove' - it said: $($again.Trim())" }
    }
}
finally {
    $env:APPDATA = $realAppData
    $env:LOCALAPPDATA = $realLocalAppData
    Set-RawUserPath $savedPath
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "  $($script:pass) checks, all green" -ForegroundColor Green
    Write-Host '  Your PATH, Start menu and install folder are as they were.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}
Write-Host "  $($script:pass) green, $($script:fail) failed" -ForegroundColor Red
Write-Host ''
exit 1
