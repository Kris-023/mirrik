<#
.SYNOPSIS
    Pruefstand fuer install.ps1, ohne etwas am eigenen System zu aendern.

.DESCRIPTION
    Analog zu tools/test-install.sh: jeder Fall bekommt ein frisches, isoliertes HOME
    (APPDATA/LOCALAPPDATA zeigen in ein mktemp-Verzeichnis) und einen frischen pwsh-Prozess
    (tools/test-install-driver.ps1), der install.ps1 dot-sourced - dank dessen Guard
    (`if ($MyInvocation.InvocationName -ne '.')`) fuehrt das nur die Funktionsdefinitionen
    aus, nichts vom eigentlichen Installer. Der Treiber ersetzt danach genau die Funktionen,
    die auf Windows-only-APIs sitzen (Registry, COM, user32-P/Invoke, CIM), durch
    dateibasierte Attrappen; alles andere in install.ps1 laeuft echt.

    Deckt nur ab, was ohne echtes Windows ueberhaupt erreichbar ist - siehe
    the maintainer's private notes fuer die genaue Abgrenzung (die dort
    behauptete Faustregel war "grob 30 von 35"; was hier tatsaechlich steht, ist weniger,
    weil zwei Vorpruefungen an statischen .NET-Eigenschaften haengen, die sich auch mit
    Function-Shadowing nicht ersetzen lassen - Details in der .md).

.PARAMETER Filter
    Nur Faelle ausfuehren, deren Name diesen Text enthaelt.

.EXAMPLE
    tools/test-install.ps1
.EXAMPLE
    tools/test-install.ps1 hotkey
.EXAMPLE
    VERBOSE=1 tools/test-install.ps1
#>
param([string]$Filter = '')

$ErrorActionPreference = 'Stop'
$Repo = (Get-Item (Join-Path $PSScriptRoot '..')).FullName
$Installer = Join-Path $Repo 'install.ps1'
$Driver = Join-Path $PSScriptRoot 'test-install-driver.ps1'
if (-not (Test-Path $Installer)) { Write-Error "install.ps1 nicht gefunden: $Installer"; exit 1 }

$script:pass = 0
$script:fail = 0
$script:failedNames = @()
$verbose = [bool]$env:VERBOSE

function Write-CaseResult([bool]$ok, [string]$name, [string[]]$problems, [string]$out) {
    if ($ok) {
        Write-Host "  ✓ $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  ✗ $name" -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "      $p" -ForegroundColor Gray }
        if ($verbose) { ($out -split "`n" | Select-Object -Last 20) | ForEach-Object { Write-Host "        | $_" -ForegroundColor DarkGray } }
        $script:fail++
        $script:failedNames += $name
    }
}

# Legt einen lauffaehigen Attrappen-Binary an - #!/usr/bin/env bash-Skript, Name endet auf
# .exe, weil install.ps1 genau danach sucht. Linux fuehrt es trotzdem aus: die Endung
# interessiert exec() nicht, nur das Shebang und das x-Bit.
function New-StubBinary([string]$path, [string]$version) {
    @"
#!/usr/bin/env bash
case "`$1" in
  devices) printf '* Speakers  [analog]\n    stub.analog-stereo\n  HDMI Display  [HDMI]\n    stub.hdmi-stereo\n' ;;
  --version) printf 'mirrik $version\n' ;;
  off) : ;;
esac
exit 0
"@ -replace "`r`n", "`n" | Set-Content -Path $path -NoNewline
    & chmod +x $path
}

function New-StubCargo([string]$dir, [string]$logFile, [switch]$Fails) {
    $path = Join-Path $dir 'cargo'
    $fakeMirrik = if ($Fails) { '' } else {
@'
mkdir -p target/release
cat > target/release/mirrik.exe <<'BIN'
#!/usr/bin/env bash
case "$1" in
  devices) printf '* Speakers  [analog]\n    stub.analog-stereo\n  HDMI Display  [HDMI]\n    stub.hdmi-stereo\n' ;;
  --version) printf 'mirrik 0.1.0\n' ;;
esac
exit 0
BIN
cp target/release/mirrik.exe target/release/mirrik-gui.exe
chmod +x target/release/mirrik.exe target/release/mirrik-gui.exe
'@
    }
    $exitLine = if ($Fails) { 'exit 1' } else { 'exit 0' }
    @"
#!/usr/bin/env bash
printf 'cargo %s\n' "`$*" >> "$logFile"
$fakeMirrik
$exitLine
"@ -replace "`r`n", "`n" | Set-Content -Path $path -NoNewline
    & chmod +x $path
}

<#
.SYNOPSIS
    Fuehrt einen Fall aus: eigenes HOME, eigener Installer-Ordner, ein frischer pwsh-Prozess.
#>
function Invoke-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Answers = @(),
        [Parameter(Mandatory)][scriptblock]$Check,
        [switch]$Uninstall,
        [string]$AltGr = '',
        [string]$Adapters = '',
        [string]$SessionName = '',
        [switch]$NoBinaries,
        [switch]$NoCargo,
        [switch]$CargoFails,
        [switch]$Admin,
        [string]$Preinstalled = '',
        [hashtable]$PreShortcuts = @{},
        [string]$PrePath = '',
        [string]$StrayMirrikDir = '',
        [switch]$RawAnswers
    )
    if ($Filter -and $Name -notlike "*$Filter*") { return }

    $home_ = Join-Path ([IO.Path]::GetTempPath()) ("mirrik-ps-test-" + [Guid]::NewGuid().ToString('N'))
    $fakeRoot = Join-Path $home_ 'repo'
    $appdata = Join-Path $home_ 'AppData\Roaming'
    $localAppdata = Join-Path $home_ 'AppData\Local'
    # {HOME} und {TARGET} in Antworten/PrePath duerfen sich erst hier aufloesen - vorher ist
    # weder das Test-HOME noch der Standard-Zielordner bekannt. Ohne das wuerde ein Fall, der
    # einen eigenen Pfad tippt, versehentlich einen Pfad auf dem echten System anfassen.
    $defaultTarget = Join-Path $localAppdata 'Programs\Mirrik'
    $Answers = $Answers | ForEach-Object { $_ -replace '\{HOME\}', $home_ -replace '\{TARGET\}', $defaultTarget }
    $PrePath = $PrePath -replace '\{HOME\}', $home_ -replace '\{TARGET\}', $defaultTarget
    $startMenu = Join-Path $appdata 'Microsoft\Windows\Start Menu\Programs'
    $fakeBin = Join-Path $home_ 'fakebin'
    $sysBin = Join-Path $home_ 'sysbin'
    $logFile = Join-Path $home_ 'stub.log'
    New-Item -ItemType Directory -Force -Path $fakeRoot, $appdata, $localAppdata, $startMenu, $fakeBin, $sysBin | Out-Null
    New-Item -ItemType File -Force -Path $logFile | Out-Null

    # Nur env und bash - genug, damit die #!/usr/bin/env bash-Attrappen laufen, aber kein
    # echtes System-PATH, in dem sich ein echtes cargo (z.B. ueber rustup) verstecken und
    # einen "kein cargo installiert"-Fall stillschweigend verfaelschen koennte - genau das
    # ist beim Bauen dieses Pruefstands passiert.
    foreach ($t in @('env', 'bash', 'mkdir', 'cp', 'chmod', 'cat')) {
        $src = (Get-Command $t -ErrorAction SilentlyContinue).Source
        if ($src) { Copy-Item $src (Join-Path $sysBin $t); & chmod +x (Join-Path $sysBin $t) }
    }

    Copy-Item $Installer (Join-Path $fakeRoot 'install.ps1')

    if (-not $NoBinaries) {
        New-StubBinary (Join-Path $fakeRoot 'mirrik.exe') '0.1.0'
        New-StubBinary (Join-Path $fakeRoot 'mirrik-gui.exe') '0.1.0'
    }
    if (-not $NoCargo) { New-StubCargo -dir $fakeBin -logFile $logFile -Fails:$CargoFails }

    if ($Preinstalled) {
        $existingDir = Join-Path $localAppdata 'Programs\Mirrik'
        New-Item -ItemType Directory -Force -Path $existingDir | Out-Null
        New-StubBinary (Join-Path $existingDir 'mirrik.exe') $Preinstalled
        New-StubBinary (Join-Path $existingDir 'mirrik-gui.exe') $Preinstalled
    }

    if ($StrayMirrikDir) {
        $strayDir = Join-Path $home_ $StrayMirrikDir
        New-Item -ItemType Directory -Force -Path $strayDir | Out-Null
        New-StubBinary (Join-Path $strayDir 'mirrik.exe') '0.0.1-stray'
        $PrePath = if ($PrePath) { "$PrePath;$strayDir" } else { $strayDir }
    }
    if ($PrePath) { Set-Content -Path (Join-Path $home_ 'fake-user-path.txt') -Value $PrePath -NoNewline }

    $shortcuts = @{}
    foreach ($rel in $PreShortcuts.Keys) {
        $lnkPath = Join-Path $startMenu $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $lnkPath) | Out-Null
        New-Item -ItemType File -Force -Path $lnkPath | Out-Null
        $shortcuts[$lnkPath] = @{ TargetPath = ''; WorkingDirectory = ''; Description = ''; HotKey = $PreShortcuts[$rel] }
    }
    if ($shortcuts.Count -gt 0) {
        ($shortcuts | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $home_ 'fake-shortcuts.json')
    }

    # [Environment]::OSVersion meldet unter Linux/pwsh eine Version < 10 (hier "7.1", stabil
    # ueber alle Faelle) - das ist genau der Zweig "Windows aelter als 10" aus Schritt 1 und
    # feuert deshalb bei JEDEM Fall zuerst, real und unfaked. Statt in jedem Fall eine
    # unwichtige erste Antwort mitzuschleppen, uebernimmt das der Treiber zentral; wer den
    # Zweig selbst testen will (siehe unten), setzt -RawAnswers und antwortet selbst.
    $allAnswers = if ($RawAnswers) { $Answers } else { @('y') + $Answers }
    $stdin = ($allAnswers -join "`n") + "`n"
    $envBlock = @{
        MIRRIK_TEST_HOME      = $home_
        MIRRIK_TEST_INSTALLER = (Join-Path $fakeRoot 'install.ps1')
        MIRRIK_TEST_ALTGR     = $AltGr
        MIRRIK_TEST_ADAPTERS  = $Adapters
        MIRRIK_TEST_ADMIN     = if ($Admin) { '1' } else { '' }
        APPDATA               = $appdata
        LOCALAPPDATA          = $localAppdata
        ProgramData           = (Join-Path $home_ 'ProgramData')
        PROCESSOR_ARCHITECTURE = 'AMD64'
        SESSIONNAME           = $SessionName
        # Die Stub-Binaries sind #!/usr/bin/env bash-Skripte - env und bash muessen also
        # noch auffindbar sein. Nur /usr/bin:/bin dazu, kein sonstiges System-PATH: die
        # eigentlichen Werkzeuge (cargo, mirrik.exe) kommen ausschliesslich aus $fakeBin
        # bzw. dem Zielordner, echte auf dem System installierte gleichnamige faenden sonst
        # unbemerkt statt der Attrappe statt.
        PATH                  = "${fakeBin}:${sysBin}"
        HOME                  = $home_
    }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    foreach ($a in @('-NoLogo', '-NoProfile', '-File', $Driver)) { $psi.ArgumentList.Add($a) }
    if ($Uninstall) { $psi.ArgumentList.Add('-Uninstall') }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables.Clear()
    foreach ($k in $envBlock.Keys) { $psi.EnvironmentVariables[$k] = $envBlock[$k] }
    # PATH muss auch pwsh selbst noch finden koennen, sonst startet der Kindprozess nicht.
    $psi.EnvironmentVariables['PATH'] = "${fakeBin}:${sysBin}:$(Split-Path $psi.FileName)"

    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($stdin)
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $out = $stdout + $stderr

    $ctx = [pscustomobject]@{
        Out = $out; ExitCode = $proc.ExitCode; Home = $home_; FakeRoot = $fakeRoot
        LogFile = $logFile; StartMenu = $startMenu; LocalAppData = $localAppdata
        AppData = $appdata; ShortcutFile = (Join-Path $home_ 'fake-shortcuts.json')
        PathFile = (Join-Path $home_ 'fake-user-path.txt')
    }
    # @(...) um einen Aufruf, der intern $null zurueckgibt (eine leere @() kollabiert beim
    # Return zu $null, sobald sie durch += aus lauter leeren Teilergebnissen entsteht),
    # liefert ein Array mit einem $null-Element - Count 1 statt 0. Deshalb wird gefiltert,
    # nicht nur gezaehlt.
    $problems = @(@(& $Check $ctx) | Where-Object { $_ })
    Write-CaseResult -ok ($problems.Count -eq 0) -name $Name -problems $problems -out $out
    Remove-Item -Recurse -Force $home_ -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- gemeinsame Pruefungen

function Test-InstalledOk($ctx) {
    $problems = @()
    if ($ctx.ExitCode -ne 0) { $problems += "Exit-Code $($ctx.ExitCode) statt 0" }
    $dir = Join-Path $ctx.LocalAppData 'Programs\Mirrik'
    if (-not (Test-Path (Join-Path $dir 'mirrik.exe')))     { $problems += 'mirrik.exe nicht installiert' }
    if (-not (Test-Path (Join-Path $dir 'mirrik-gui.exe'))) { $problems += 'mirrik-gui.exe nicht installiert' }
    if ($ctx.Out -notmatch 'Mirrik sees 2 output device') { $problems += 'Schritt 7 hat die Geraete nicht gelesen' }
    return $problems
}

function Test-ShortcutHotkey($ctx, [string]$expected) {
    if (-not (Test-Path $ctx.ShortcutFile)) { return @('keine Verknuepfung angelegt') }
    $data = Get-Content $ctx.ShortcutFile -Raw | ConvertFrom-Json -AsHashtable
    # Gezielt Mirrik.lnk, nicht "irgendein Eintrag mit Hotkey" - bei vorbelegten Kombinationen
    # (PreShortcuts) liegt daneben ein zweiter Eintrag mit Hotkey, und Hashtable-Reihenfolge
    # ist nicht garantiert.
    $key = $data.Keys | Where-Object { $_ -like '*Mirrik.lnk' } | Select-Object -First 1
    if (-not $key) { return @('kein Mirrik.lnk-Eintrag in der Attrappen-Verknuepfung') }
    $entry = $data[$key]
    if (-not $entry.HotKey) { return @('Mirrik.lnk hat keinen Hotkey') }
    if ($entry.HotKey -ne $expected) { return @("Hotkey ist '$($entry.HotKey)' statt '$expected'") }
    return @()
}

# ================================================================== FAELLE

Write-Host 'install.ps1 — Pruefstand'
Write-Host 'Attrappen-HOME je Fall, echtes System unberuehrt' -ForegroundColor DarkGray
Write-Host ''

# --- Gruppe: Confirm-Semantik (leer=Vorgabe, y/yes, n/no, Unsinn -> erneute Frage) -------

Invoke-Case -Name 'confirm-build-leer-ist-ja' `
    -Answers @('', '', '', 'n') -NoBinaries -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'Build them now') { $p += 'Frage wurde nicht gestellt' }
        return $p
    }

Invoke-Case -Name 'confirm-build-nein-bricht-ab' `
    -Answers @('n') -NoBinaries -Check {
        param($ctx)
        $p = @()
        if ($ctx.ExitCode -eq 0) { $p += 'Exit-Code 0, obwohl abgebrochen werden sollte' }
        if (Test-Path (Join-Path $ctx.LocalAppData 'Programs\Mirrik\mirrik.exe')) { $p += 'trotz Ablehnung installiert' }
        return $p
    }

Invoke-Case -Name 'confirm-build-yes-ausgeschrieben' `
    -Answers @('yes', '', '', 'n') -NoBinaries -Check { param($ctx) Test-InstalledOk $ctx }

Invoke-Case -Name 'confirm-build-no-ausgeschrieben' `
    -Answers @('no') -NoBinaries -Check {
        param($ctx)
        $p = @()
        if ($ctx.ExitCode -eq 0) { $p += 'Exit-Code 0, obwohl abgebrochen werden sollte' }
        return $p
    }

Invoke-Case -Name 'confirm-unsinn-dann-gueltig' `
    -Answers @('vielleicht', 'y', '', '', 'n') -NoBinaries -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'Please answer y or n') { $p += 'keine erneute Frage nach Unsinn' }
        return $p
    }

Invoke-Case -Name 'confirm-path-frage-vorgabe-ja' `
    -Answers @('', '', 'n') -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'Added\. Open a new terminal') { $p += 'PATH-Zweig lief nicht mit Vorgabe ja' }
        return $p
    }

# --- Gruppe: Zielordner --------------------------------------------------------------

Invoke-Case -Name 'zielordner-vorgabe' -Answers @('', '', 'y') -Check { param($ctx) Test-InstalledOk $ctx }

Invoke-Case -Name 'zielordner-eigener-pfad' -Answers @('{HOME}/custom-target', '', 'y') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -ne 0) { $p += "Exit-Code $($ctx.ExitCode) statt 0" }
    if (-not (Test-Path (Join-Path $ctx.Home 'custom-target\mirrik.exe'))) { $p += 'nicht im getippten Zielordner installiert' }
    return $p
}

Invoke-Case -Name 'zielordner-verbotene-zeichen-dann-gueltig' `
    -Answers @('mirrik|bad', '', '', 'y') -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'does not allow') { $p += 'keine Warnung zu verbotenen Zeichen' }
        return $p
    }

Invoke-Case -Name 'zielordner-schon-vorhanden-gleiche-fassung' `
    -Preinstalled '0.1.0' -Answers @('', '', 'y') -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'Replacing what is already there') { $p += 'kein Hinweis auf die vorhandene Fassung' }
        return $p
    }

Invoke-Case -Name 'zielordner-schon-vorhanden-andere-fassung' `
    -Preinstalled '0.0.9' -Answers @('', '', 'y') -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'mirrik 0\.0\.9') { $p += 'die ersetzte Fassung wird nicht genannt' }
        return $p
    }

# --- Gruppe: Hotkey-Taste --------------------------------------------------------------

Invoke-Case -Name 'hotkey-gueltige-taste' -Answers @('', '', 'y', 'J', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+J'
    return $p
}

Invoke-Case -Name 'hotkey-mehrzeichig-dann-gueltig' -Answers @('', '', 'y', 'abc', 'K', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'One letter or digit') { $p += 'keine erneute Frage nach mehrzeichiger Eingabe' }
    $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+K'
    return $p
}

Invoke-Case -Name 'hotkey-sonderzeichen-dann-gueltig' -Answers @('', '', 'y', '%', 'L', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+L'
    return $p
}

Invoke-Case -Name 'hotkey-altgr-kollision-uebernommen' -Answers @('', '', 'y', 'Q', 'n') `
    -AltGr 'Q=@,E=€' -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'AltGr') { $p += 'keine AltGr-Warnung' }
        $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+Q'
        return $p
    }

Invoke-Case -Name 'hotkey-vergebene-kombination-dann-andere' -Answers @('', '', 'y', 'Q', 'y', 'K', 'y') `
    -PreShortcuts @{ 'Other.lnk' = 'CTRL+ALT+Q' } -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'already used by the shortcut') { $p += 'kein Hinweis auf die belegte Kombination' }
        $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+K'
        return $p
    }

# --- Gruppe: Bau-Zweig ------------------------------------------------------------------

Invoke-Case -Name 'bau-binaries-vorhanden-kein-cargo-noetig' -Answers @('', '', 'n') -Check { param($ctx) Test-InstalledOk $ctx }

Invoke-Case -Name 'bau-fehlt-mit-cargo-akzeptiert' -NoBinaries -Answers @('y', '', '', 'n') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ((Get-Content $ctx.LogFile -Raw) -notmatch '-p mirrik-cli -p mirrik-gui') {
        $p += 'cargo wurde nicht mit -p fuer beide Pakete aufgerufen'
    }
    return $p
}

Invoke-Case -Name 'bau-fehlt-mit-cargo-abgelehnt' -NoBinaries -Answers @('n') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'Exit-Code 0, obwohl abgebrochen werden sollte' }
    if ($ctx.Out -notmatch 'cargo build --release -p mirrik-cli -p mirrik-gui') { $p += 'kein Hinweis, wie man selbst baut' }
    return $p
}

Invoke-Case -Name 'bau-fehlt-ohne-cargo' -NoBinaries -NoCargo -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'Exit-Code 0, obwohl abgebrochen werden sollte' }
    if ($ctx.Out -notmatch 'Rust is not installed either') { $p += 'kein Hinweis, dass auch Rust fehlt' }
    return $p
}

Invoke-Case -Name 'bau-cargo-schlaegt-fehl' -NoBinaries -CargoFails -Answers @('y') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'Exit-Code 0, obwohl der Bau fehlgeschlagen ist' }
    if ($ctx.Out -notmatch 'cargo build failed') { $p += 'kein Hinweis auf den fehlgeschlagenen Bau' }
    return $p
}

# --- Gruppe: PATH ------------------------------------------------------------------------

Invoke-Case -Name 'path-fehlt-akzeptiert' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if (-not (Test-Path $ctx.PathFile)) { $p += 'PATH wurde nicht geschrieben' }
    return $p
}

Invoke-Case -Name 'path-fehlt-abgelehnt' -Answers @('', 'n', 'n') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'Skipped\. The window works') { $p += 'kein Hinweis auf Ueberspringen' }
    return $p
}

Invoke-Case -Name 'path-schon-drin-erkannt' -Answers @('', '') -PrePath '{TARGET}' -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'That folder is already on your PATH') { $p += 'vorhandener PATH-Eintrag wurde nicht erkannt' }
    return $p
}

Invoke-Case -Name 'path-anderes-mirrik-schon-vorhanden' -Answers @('', '', 'y') `
    -StrayMirrikDir 'other-mirrik' -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'another mirrik\.exe already on your PATH') { $p += 'kein Hinweis auf den fremden mirrik.exe-Fund' }
        return $p
    }

# --- Gruppe: Vorpruefungen (nur was ohne Windows tatsaechlich erreichbar ist) -----------

# [Environment]::OSVersion liefert unter Linux/pwsh selbst eine Version < 10 - deshalb ist
# dieser Zweig hier IMMER aktiv (siehe -RawAnswers weiter oben) und braucht keine Attrappe.
# Die PowerShell-Mindestversion (Zeile ~269) dagegen laesst sich nicht erreichen: die laeuft,
# bevor irgendeine Funktion definiert ist, gegen $PSVersionTable direkt - siehe .md.
Invoke-Case -Name 'vorpruefung-altes-windows-abgelehnt' -RawAnswers -Answers @('n') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'Exit-Code 0, obwohl abgebrochen werden sollte' }
    if ($ctx.Out -notmatch 'has not') { $p += 'keine Warnung zur alten Windows-Version' }
    return $p
}

Invoke-Case -Name 'vorpruefung-altes-windows-akzeptiert' -RawAnswers -Answers @('y', '', '', 'y') -Check {
    param($ctx) Test-InstalledOk $ctx
}

Invoke-Case -Name 'vorpruefung-administrator-warnung' -Admin -Answers @('n') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'Exit-Code 0, obwohl abgebrochen werden sollte' }
    if ($ctx.Out -notmatch 'running this as administrator') { $p += 'keine Administrator-Warnung' }
    return $p
}

Invoke-Case -Name 'vorpruefung-kein-administrator-keine-warnung' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -match 'running this as administrator') { $p += 'Warnung erschien, obwohl nicht Administrator' }
    return $p
}

Invoke-Case -Name 'vorpruefung-basic-adapter-warnung' -Adapters 'Microsoft Basic Display Adapter' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'OpenGL 2\.0 or better') { $p += 'keine Warnung zum Basic-Adapter' }
    return $p
}

Invoke-Case -Name 'vorpruefung-echter-adapter-keine-warnung' -Adapters 'NVIDIA GeForce RTX 4070' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -match 'OpenGL 2\.0 or better') { $p += 'Warnung erschien trotz echtem Adapter' }
    return $p
}

Invoke-Case -Name 'vorpruefung-rdp-hinweis' -SessionName 'RDP-Tcp#1' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'Remote Desktop session') { $p += 'kein RDP-Hinweis' }
    return $p
}

# --- Gruppe: Zweiter Lauf, Deinstallation, Deinstallation ohne Installation ------------

Invoke-Case -Name 'zweiter-lauf-ersetzt-laufende-fassung' -Preinstalled '0.0.5' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'mirrik 0\.0\.5') { $p += 'die ersetzte Fassung wird nicht genannt' }
    return $p
}

Invoke-Case -Name 'deinstallation-raeumt-alles-ab' -Uninstall -RawAnswers -Preinstalled '0.1.0' `
    -PreShortcuts @{ 'Mirrik.lnk' = 'CTRL+ALT+J' } -Answers @('y') -Check {
        param($ctx)
        $p = @()
        if ($ctx.ExitCode -ne 0) { $p += "Exit-Code $($ctx.ExitCode) statt 0" }
        $dir = Join-Path $ctx.LocalAppData 'Programs\Mirrik'
        if (Test-Path $dir) { $p += 'Programmordner ist nach der Deinstallation noch da' }
        if ($ctx.Out -notmatch 'Nothing of Mirrik is left') { $p += 'keine Abschlussmeldung' }
        return $p
    }

Invoke-Case -Name 'deinstallation-abgelehnt-aendert-nichts' -Uninstall -RawAnswers -Preinstalled '0.1.0' `
    -PreShortcuts @{ 'Mirrik.lnk' = 'CTRL+ALT+J' } -Answers @('n') -Check {
        param($ctx)
        $p = @()
        $dir = Join-Path $ctx.LocalAppData 'Programs\Mirrik'
        if (-not (Test-Path $dir)) { $p += 'Programmordner wurde trotz Ablehnung entfernt' }
        if ($ctx.Out -notmatch 'Nothing was changed') { $p += 'keine Bestaetigung, dass nichts geaendert wurde' }
        return $p
    }

Invoke-Case -Name 'deinstallation-ohne-installation' -Uninstall -RawAnswers -Answers @() -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -ne 0) { $p += "Exit-Code $($ctx.ExitCode) statt 0" }
    if ($ctx.Out -notmatch 'there is nothing to remove') { $p += 'keine Meldung, dass nichts installiert ist' }
    return $p
}

# ==================================================================

Write-Host ''
Write-Host "  $($script:pass) bestanden, $($script:fail) durchgefallen"
if ($script:fail -gt 0) {
    Write-Host "  Durchgefallen: $($script:failedNames -join ', ')" -ForegroundColor Red
    exit 1
}
exit 0
