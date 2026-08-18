<#
Heads up: tools/test-install.ps1 starts this as a fresh pwsh process for every single
case - you shouldn't be running it directly.

Dot-sourcing install.ps1 only defines its functions, thanks to its guard - nothing
actually runs yet. What we do here is swap out just the functions that touch
Windows-only APIs (registry, COM, user32 P/Invoke) for file-based stubs living under
$env:MIRRIK_TEST_HOME. Everything else in install.ps1 (Say/Ask/Confirm, the path logic,
copying files, reading the PE header) runs completely for real, untouched. Once that's
set up, we call Invoke-MirrikInstaller exactly like install.ps1 does at its own end -
if it hits an `exit`, that only closes this process, not your session.
#>
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

# We grab this BEFORE dot-sourcing, and here's why: install.ps1 has its own
# param([switch]$Uninstall), and dot-sourcing shares the same scope as this file. Call
# the dot-source line without arguments and install.ps1's own parameter quietly rebinds
# our variable of the same name back to $false - wiping out whatever came in from the
# command line, with no warning at all.
$doUninstall = $Uninstall.IsPresent

$fakePathFile     = Join-Path $env:MIRRIK_TEST_HOME 'fake-user-path.txt'
$fakeShortcutFile = Join-Path $env:MIRRIK_TEST_HOME 'fake-shortcuts.json'

. $env:MIRRIK_TEST_INSTALLER

# ---- Registry stand-in: Get-/Set-UserPathRaw just read and write a file in the test HOME ----
function Get-UserPathRaw {
    if (Test-Path $fakePathFile) { (Get-Content $fakePathFile -Raw) -replace "`n$", '' } else { '' }
}
function Set-UserPathRaw([string]$value) {
    Set-Content -Path $fakePathFile -Value $value -NoNewline
}
# The real version broadcasts a change to every open window. A test process has no
# windows to tell, so there's simply nothing to do here.
function Publish-EnvironmentChange { }

# The real Unblock-File strips the "downloaded from the internet" flag (the
# Zone.Identifier ADS) - an NTFS-only concept that Linux doesn't have at all. So there's
# no need for a stand-in here: with no download flag to begin with, there's nothing to
# remove.
function Unblock-File {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject, [string]$Path)
    process { }
}

# ---- AltGr layout stand-in: read from an env var instead of the real keyboard layout ----
function Get-AltGrKeys {
    $result = @{}
    if ($env:MIRRIK_TEST_ALTGR) {
        foreach ($pair in ($env:MIRRIK_TEST_ALTGR -split ',')) {
            if (-not $pair) { continue }
            $k, $v = $pair -split '=', 2
            $result[$k] = $v
        }
    }
    return $result
}

# ---- COM shortcut stand-in: a JSON file stands in for a real .lnk file's contents ----
function Read-FakeShortcuts {
    if (Test-Path $fakeShortcutFile) {
        $raw = Get-Content $fakeShortcutFile -Raw
        if ($raw) { return $raw | ConvertFrom-Json -AsHashtable }
    }
    return @{}
}
function Write-FakeShortcuts([hashtable]$table) {
    $table | ConvertTo-Json -Depth 5 | Set-Content $fakeShortcutFile
}
function Get-ShortcutTarget([string]$path) {
    $t = Read-FakeShortcuts
    if ($t.ContainsKey($path)) { return $t[$path].TargetPath }
    return $null
}
function Get-ShortcutHotkey([string]$path) {
    $t = Read-FakeShortcuts
    if ($t.ContainsKey($path)) { return $t[$path].HotKey }
    return $null
}
function New-MirrikShortcut {
    param([string]$Path, [string]$TargetPath, [string]$WorkingDirectory, [string]$Description, [string]$HotKey)
    $t = Read-FakeShortcuts
    $t[$Path] = @{
        TargetPath = $TargetPath; WorkingDirectory = $WorkingDirectory
        Description = $Description; HotKey = $HotKey
    }
    Write-FakeShortcuts $t
    # We still create the empty file so that Test-Path $shortcutPath comes back true
    # afterwards - just like it would for a real .lnk file.
    New-Item -ItemType File -Force -Path $Path | Out-Null
}

# ---- Administrator check stand-in: an env var instead of a real Windows identity ----
function Test-RunningAsAdministrator {
    if ($env:MIRRIK_TEST_ADMIN -eq '1') {
        return @{ IsAdmin = $true; Name = 'TESTMACHINE\Administrator' }
    }
    return @{ IsAdmin = $false; Name = $null }
}

# ---- Graphics driver stand-in: an env var instead of a real CIM query ----
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName, [string]$ErrorActionParam)
    if ($ClassName -ne 'Win32_VideoController') { return @() }
    if (-not $env:MIRRIK_TEST_ADAPTERS) { return @() }
    return ($env:MIRRIK_TEST_ADAPTERS -split ',' | ForEach-Object { [pscustomobject]@{ Name = $_ } })
}

Invoke-MirrikInstaller -Uninstall:$doUninstall
