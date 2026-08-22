<#
.SYNOPSIS
    fmt -> clippy -> cargo test (the four Windows crates) -> the installer bench, one
    line of balance at the end. Windows counterpart to tools/check.sh.

.EXAMPLE
    pwsh tools/check.ps1
#>
$ErrorActionPreference = 'Stop'
$Repo = (Get-Item (Join-Path $PSScriptRoot '..')).FullName
Set-Location $Repo

$Crates = @('-p', 'mirrik-core', '-p', 'mirrik-backend-windows', '-p', 'mirrik-cli', '-p', 'mirrik-gui')
$ok = @()
$failed = $null

function Invoke-Step([string]$Label, [scriptblock]$Body) {
    if ($failed) { return }
    & $Body
    if ($LASTEXITCODE -eq 0) { $script:ok += $Label } else { $script:failed = $Label }
}

Invoke-Step 'fmt'    { cargo fmt --check }
Invoke-Step 'clippy' { cargo clippy --release @Crates -- -D warnings }
Invoke-Step 'test'   { cargo test --release @Crates }
Invoke-Step 'bench'  { pwsh (Join-Path $PSScriptRoot 'windows/test-install.ps1') }

Write-Host ''
if ($failed) {
    Write-Host "check.ps1: $($ok -join ', ') passed, $failed failed - stopped there" -ForegroundColor Red
    exit 1
}
Write-Host "check.ps1: all green ($($ok -join ', '))" -ForegroundColor Green
