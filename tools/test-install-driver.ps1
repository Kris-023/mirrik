<#
Wird von tools/test-install.ps1 als frischer pwsh-Prozess je Fall gestartet - nie direkt.

Dot-sourced install.ps1 definiert dank seines Guards nur Funktionen, fuehrt nichts aus.
Was hier folgt, ersetzt genau die Funktionen, die auf Windows-only-APIs sitzen (Registry,
COM, user32-P/Invoke), durch dateibasierte Attrappen unter $env:MIRRIK_TEST_HOME - der
Rest von install.ps1 (Say/Ask/Confirm, Pfadlogik, Kopiervorgaenge, PE-Header-Lesen) laeuft
unveraendert und echt. Danach wird Invoke-MirrikInstaller genauso aufgerufen wie am
Skriptende von install.ps1 selbst; ein `exit` darin beendet nur diesen Prozess.
#>
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

# Gerettet VOR dem Dot-Source: install.ps1 hat selbst ein param([switch]$Uninstall), und
# Dot-Sourcing laeuft im selben Scope wie hier - ohne Argumente an die Dot-Source-Zeile
# bindet dessen eigener Parameter die gleichnamige Variable neu auf $false und ueberschreibt
# damit lautlos, was gerade von der Kommandozeile kam.
$doUninstall = $Uninstall.IsPresent

$fakePathFile     = Join-Path $env:MIRRIK_TEST_HOME 'fake-user-path.txt'
$fakeShortcutFile = Join-Path $env:MIRRIK_TEST_HOME 'fake-shortcuts.json'

. $env:MIRRIK_TEST_INSTALLER

# ---- Registry (Get-/Set-UserPathRaw) -> eine Datei im Test-HOME ----
function Get-UserPathRaw {
    if (Test-Path $fakePathFile) { (Get-Content $fakePathFile -Raw) -replace "`n$", '' } else { '' }
}
function Set-UserPathRaw([string]$value) {
    Set-Content -Path $fakePathFile -Value $value -NoNewline
}
# Broadcasts an alle Fenster - in einem Testprozess gibt es keine und nichts zu tun.
function Publish-EnvironmentChange { }

# Streicht die "aus dem Internet heruntergeladen"-Markierung (Zone.Identifier ADS) -
# ein Windows-NTFS-Konzept, das Linux gar nicht kennt. Kein Aequivalent noetig: ohne
# Downloadmarkierung gibt es unter Linux nichts zu entfernen.
function Unblock-File {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject, [string]$Path)
    process { }
}

# ---- AltGr-Layout -> aus einer Umgebungsvariable statt aus dem echten Keyboard-Layout ----
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

# ---- COM-Verknuepfungen -> JSON-Datei statt echter .lnk-Inhalte ----
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
    # Damit Test-Path $shortcutPath danach true ist, wie bei einer echten .lnk-Datei.
    New-Item -ItemType File -Force -Path $Path | Out-Null
}

# ---- Administrator-Status -> aus einer Umgebungsvariable statt einer echten Windows-Identity ----
function Test-RunningAsAdministrator {
    if ($env:MIRRIK_TEST_ADMIN -eq '1') {
        return @{ IsAdmin = $true; Name = 'TESTMACHINE\Administrator' }
    }
    return @{ IsAdmin = $false; Name = $null }
}

# ---- Grafiktreiber -> aus einer Umgebungsvariable statt einer echten CIM-Abfrage ----
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName, [string]$ErrorActionParam)
    if ($ClassName -ne 'Win32_VideoController') { return @() }
    if (-not $env:MIRRIK_TEST_ADAPTERS) { return @() }
    return ($env:MIRRIK_TEST_ADAPTERS -split ',' | ForEach-Object { [pscustomobject]@{ Name = $_ } })
}

Invoke-MirrikInstaller -Uninstall:$doUninstall
