<#
.SYNOPSIS
    fmt -> clippy -> cargo test (the four Windows crates) -> the installer bench, one
    line of balance at the end. Windows counterpart to tools/check.sh.

.DESCRIPTION
    Run this on Windows. The bench step is tools/windows/test-install-windows.ps1, the
    one that talks to the real registry and the real Start menu - not its sibling
    test-install.ps1, which despite the folder name only runs on Linux (its stub
    binaries are bash scripts that merely end in .exe).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/check.ps1
.EXAMPLE
    pwsh tools/check.ps1
#>
$ErrorActionPreference = 'Stop'
$Repo = (Get-Item (Join-Path $PSScriptRoot '..')).FullName
Set-Location $Repo

$Crates = @('-p', 'mirrik-core', '-p', 'mirrik-backend-windows', '-p', 'mirrik-cli', '-p', 'mirrik-gui')
$ok = @()
$failed = $null

# Whichever PowerShell is running this one - powershell.exe or pwsh.exe. The bench needs
# its own process (it ends in `exit`, which would take this script down with it), and
# hard-coding either name breaks on the machines that only have the other.
$Self = (Get-Process -Id $PID).Path

function Invoke-Step([string]$Label, [scriptblock]$Body) {
    if ($failed) { return }
    # $LASTEXITCODE only tells you anything if the step actually got as far as running a
    # program. A missing one throws instead, and with $ErrorActionPreference = 'Stop' that
    # would end the whole run right here - no balance line, just the exception. A failed
    # step is a result, so catch it and let it be one.
    try {
        & $Body
        $code = $LASTEXITCODE
    } catch {
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Gray
        $code = 1
    }
    if ($code -eq 0) { $script:ok += $Label } else { $script:failed = $Label }
}

Invoke-Step 'fmt'    { cargo fmt --check }
Invoke-Step 'clippy' { cargo clippy --release @Crates -- -D warnings }
Invoke-Step 'test'   { cargo test --release @Crates }
Invoke-Step 'bench'  {
    & $Self -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'windows/test-install-windows.ps1')
}

Write-Host ''
if ($failed) {
    # Without the guard the first step failing reads "check.ps1:  passed, fmt failed".
    $before = if ($ok) { "$($ok -join ', ') passed, " } else { '' }
    Write-Host "check.ps1: $before$failed failed - stopped there" -ForegroundColor Red
    exit 1
}
Write-Host "check.ps1: all green ($($ok -join ', '))" -ForegroundColor Green
