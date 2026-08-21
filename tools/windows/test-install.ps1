<#
.SYNOPSIS
    Test bench for install.ps1 - runs it through its paces without touching your actual system.

.DESCRIPTION
    Works the same way as tools/linux/test-install.sh: every case gets its own fresh, isolated
    HOME (APPDATA/LOCALAPPDATA point into a mktemp directory) plus a fresh pwsh process
    (tools/windows/test-install-driver.ps1) that dot-sources install.ps1. Thanks to its guard
    (`if ($MyInvocation.InvocationName -ne '.')`), that only loads the function
    definitions - none of the actual installer runs yet. From there, the driver swaps
    out just the functions sitting on Windows-only APIs (registry, COM, user32 P/Invoke,
    CIM) for file-based stubs. Everything else in install.ps1 still runs for real.

    Worth knowing: this only covers what's actually reachable without a real Windows
    machine - roughly 30 of the 35 known case groups. The rest stay out for two reasons:
    two of the prechecks depend on static .NET properties that even function-shadowing
    can't fake, and some effects (an actual shortcut, the registry PATH, a locked .exe)
    can only really be seen on real Windows.

.PARAMETER Filter
    Only run the cases whose name contains this text.

.EXAMPLE
    tools/windows/test-install.ps1
.EXAMPLE
    tools/windows/test-install.ps1 hotkey
.EXAMPLE
    VERBOSE=1 tools/windows/test-install.ps1
#>
param([string]$Filter = '')

$ErrorActionPreference = 'Stop'
$Repo = (Get-Item (Join-Path $PSScriptRoot '../..')).FullName
$Installer = Join-Path $Repo 'install.ps1'
$Driver = Join-Path $PSScriptRoot 'test-install-driver.ps1'
if (-not (Test-Path $Installer)) { Write-Error "install.ps1 not found: $Installer"; exit 1 }

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

# This builds a stub binary you can actually run: a #!/usr/bin/env bash script whose
# filename ends in .exe, since that's exactly what install.ps1 looks for. Linux is happy
# to run it anyway - exec() doesn't care about the file extension, only the shebang line
# and the executable bit.
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

function New-StubCargo([string]$dir, [string]$logFile, [switch]$Fails, [string]$Version = '1.99.0') {
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
    # `--version` is handled first and returns immediately - real `cargo --version` has no
    # side effects, and this stub must not either. Without this branch, install.ps1's MSRV
    # check (which shells out to `cargo --version`) would trigger the fake-build lines
    # below just by asking, before "Build them now?" is even shown.
    @"
#!/usr/bin/env bash
if [ "`$1" = "--version" ]; then
    printf 'cargo $Version (0000000000 2026-01-01)\n'
    exit 0
fi
printf 'cargo %s\n' "`$*" >> "$logFile"
$fakeMirrik
$exitLine
"@ -replace "`r`n", "`n" | Set-Content -Path $path -NoNewline
    & chmod +x $path
}

<#
.SYNOPSIS
    Runs exactly one test case, each with its own HOME, its own installer folder, and its own fresh pwsh process.
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
        [switch]$PreConfig,
        [switch]$RawAnswers,
        [string]$CargoVersion = '1.99.0'
    )
    if ($Filter -and $Name -notlike "*$Filter*") { return }

    $home_ = Join-Path ([IO.Path]::GetTempPath()) ("mirrik-ps-test-" + [Guid]::NewGuid().ToString('N'))
    $fakeRoot = Join-Path $home_ 'repo'
    $appdata = Join-Path $home_ 'AppData\Roaming'
    $localAppdata = Join-Path $home_ 'AppData\Local'
    # {HOME} and {TARGET} placeholders in the answers/PrePath can only be resolved from
    # this point on - before here, we don't yet know the test HOME or the default target
    # folder. Skip this and a case that types its own path could end up accidentally
    # touching something on your real system.
    $defaultTarget = Join-Path $localAppdata 'Programs\Mirrik'
    $Answers = $Answers | ForEach-Object { $_ -replace '\{HOME\}', $home_ -replace '\{TARGET\}', $defaultTarget }
    $PrePath = $PrePath -replace '\{HOME\}', $home_ -replace '\{TARGET\}', $defaultTarget
    $startMenu = Join-Path $appdata 'Microsoft\Windows\Start Menu\Programs'
    $fakeBin = Join-Path $home_ 'fakebin'
    $sysBin = Join-Path $home_ 'sysbin'
    $logFile = Join-Path $home_ 'stub.log'
    New-Item -ItemType Directory -Force -Path $fakeRoot, $appdata, $localAppdata, $startMenu, $fakeBin, $sysBin | Out-Null
    New-Item -ItemType File -Force -Path $logFile | Out-Null

    # We only copy in env and bash here - just enough to let the #!/usr/bin/env bash
    # stubs run. We deliberately don't give it the real system PATH, because a real
    # cargo hiding in there (say, from rustup) could sneak in and quietly ruin a "no
    # cargo installed" case. That's not a hypothetical - it actually happened while this
    # test bench was being built.
    foreach ($t in @('env', 'bash', 'mkdir', 'cp', 'chmod', 'cat')) {
        $src = (Get-Command $t -ErrorAction SilentlyContinue).Source
        if ($src) { Copy-Item $src (Join-Path $sysBin $t); & chmod +x (Join-Path $sysBin $t) }
    }

    Copy-Item $Installer (Join-Path $fakeRoot 'install.ps1')
    # Just enough of the real Cargo.toml for the MSRV check to read the same line it would
    # in the real repository - the rest of the workspace manifest is irrelevant here.
    "[workspace.package]`nrust-version = `"1.95`"`n" | Set-Content -Path (Join-Path $fakeRoot 'Cargo.toml') -NoNewline

    if (-not $NoBinaries) {
        New-StubBinary (Join-Path $fakeRoot 'mirrik.exe') '0.1.0'
        New-StubBinary (Join-Path $fakeRoot 'mirrik-gui.exe') '0.1.0'
    }
    if (-not $NoCargo) { New-StubCargo -dir $fakeBin -logFile $logFile -Fails:$CargoFails -Version $CargoVersion }

    if ($Preinstalled) {
        $existingDir = Join-Path $localAppdata 'Programs\Mirrik'
        New-Item -ItemType Directory -Force -Path $existingDir | Out-Null
        New-StubBinary (Join-Path $existingDir 'mirrik.exe') $Preinstalled
        New-StubBinary (Join-Path $existingDir 'mirrik-gui.exe') $Preinstalled
    }

    # A settings file the user wrote. The installer never creates one, so a case that
    # wants to see how the uninstaller treats it has to put it there itself.
    if ($PreConfig) {
        $cfgDir = Join-Path $appdata 'mirrik'
        New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
        Set-Content -Path (Join-Path $cfgDir 'config.toml') -Value '# mine'
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

    # A quirk worth knowing: [Environment]::OSVersion reports a version below 10 under
    # Linux/pwsh (always "7.1" here, the same in every case). That happens to be exactly
    # the "Windows older than 10" branch from step 1, so it fires first for EVERY case -
    # for real, not faked. Rather than making every single case carry around an
    # irrelevant first answer just to get past it, we handle that centrally right here.
    # If you actually want to test that branch yourself (see below), set -RawAnswers and
    # answer it directly.
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
        # Since the stub binaries are #!/usr/bin/env bash scripts, env and bash still
        # need to be findable - so we add /usr/bin:/bin and nothing more from the system
        # PATH. Every actual tool (cargo, mirrik.exe) has to come from $fakeBin or the
        # target folder instead. Without this restriction, a real tool with the same
        # name installed on your system could get picked up unnoticed instead of our
        # stub.
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
    # PATH also needs to be able to find pwsh itself - skip that and the child process
    # never starts.
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
    # Why the @(...) wrapping and the filter: a call that internally returns $null (an
    # empty @() collapses right back to $null once it's been built up via += from
    # nothing but empty pieces) comes back as an array holding one $null element -
    # Count 1, not 0. So we filter out the empties here rather than just counting them.
    $problems = @(@(& $Check $ctx) | Where-Object { $_ })
    Write-CaseResult -ok ($problems.Count -eq 0) -name $Name -problems $problems -out $out
    Remove-Item -Recurse -Force $home_ -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- shared checks, used by several cases below

function Test-InstalledOk($ctx) {
    $problems = @()
    if ($ctx.ExitCode -ne 0) { $problems += "exit code $($ctx.ExitCode) instead of 0" }
    $dir = Join-Path $ctx.LocalAppData 'Programs\Mirrik'
    if (-not (Test-Path (Join-Path $dir 'mirrik.exe')))     { $problems += 'mirrik.exe not installed' }
    if (-not (Test-Path (Join-Path $dir 'mirrik-gui.exe'))) { $problems += 'mirrik-gui.exe not installed' }
    if ($ctx.Out -notmatch 'Mirrik sees 2 output device') { $problems += 'step 7 did not read the devices' }
    return $problems
}

function Test-ShortcutHotkey($ctx, [string]$expected) {
    if (-not (Test-Path $ctx.ShortcutFile)) { return @('no shortcut was created') }
    $data = Get-Content $ctx.ShortcutFile -Raw | ConvertFrom-Json -AsHashtable
    # We look specifically for Mirrik.lnk, not just "any entry with a hotkey" - when a
    # combination is already taken (PreShortcuts), there's a second entry with a hotkey
    # sitting right next to it, and hashtable ordering isn't guaranteed anyway.
    $key = $data.Keys | Where-Object { $_ -like '*Mirrik.lnk' } | Select-Object -First 1
    if (-not $key) { return @('no Mirrik.lnk entry in the stub shortcut') }
    $entry = $data[$key]
    if (-not $entry.HotKey) { return @('Mirrik.lnk has no hotkey') }
    if ($entry.HotKey -ne $expected) { return @("hotkey is '$($entry.HotKey)' instead of '$expected'") }
    return @()
}

# ================================================================== CASES

Write-Host 'install.ps1 — test bench'
Write-Host 'A stub HOME per case, the real system untouched' -ForegroundColor DarkGray
Write-Host ''

# --- Group: Confirm semantics (empty=default, y/yes, n/no, nonsense -> asked again) -----

Invoke-Case -Name 'confirm-build-empty-is-yes' `
    -Answers @('', '', '', 'n') -NoBinaries -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'Build them now') { $p += 'question was not asked' }
        return $p
    }

Invoke-Case -Name 'confirm-build-no-aborts' `
    -Answers @('n') -NoBinaries -Check {
        param($ctx)
        $p = @()
        if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though an abort was expected' }
        if (Test-Path (Join-Path $ctx.LocalAppData 'Programs\Mirrik\mirrik.exe')) { $p += 'installed despite declining' }
        return $p
    }

Invoke-Case -Name 'confirm-build-yes-spelled-out' `
    -Answers @('yes', '', '', 'n') -NoBinaries -Check { param($ctx) Test-InstalledOk $ctx }

Invoke-Case -Name 'confirm-build-no-spelled-out' `
    -Answers @('no') -NoBinaries -Check {
        param($ctx)
        $p = @()
        if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though an abort was expected' }
        return $p
    }

Invoke-Case -Name 'confirm-nonsense-then-valid' `
    -Answers @('maybe', 'y', '', '', 'n') -NoBinaries -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'Please answer y or n') { $p += 'no repeated question after nonsense' }
        return $p
    }

Invoke-Case -Name 'confirm-path-question-default-yes' `
    -Answers @('', '', 'n') -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'Added\. Open a new terminal') { $p += 'PATH branch did not run with the default yes' }
        return $p
    }

# --- Group: target folder --------------------------------------------------------------

Invoke-Case -Name 'target-folder-default' -Answers @('', '', 'y') -Check { param($ctx) Test-InstalledOk $ctx }

Invoke-Case -Name 'target-folder-custom-path' -Answers @('{HOME}/custom-target', '', 'y') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -ne 0) { $p += "exit code $($ctx.ExitCode) instead of 0" }
    if (-not (Test-Path (Join-Path $ctx.Home 'custom-target\mirrik.exe'))) { $p += 'not installed into the typed target folder' }
    return $p
}

Invoke-Case -Name 'target-folder-forbidden-chars-then-valid' `
    -Answers @('mirrik|bad', '', '', 'y') -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'does not allow') { $p += 'no warning about forbidden characters' }
        return $p
    }

Invoke-Case -Name 'target-folder-already-there-same-version' `
    -Preinstalled '0.1.0' -Answers @('', '', 'y') -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'Replacing what is already there') { $p += 'no hint about the existing version' }
        return $p
    }

Invoke-Case -Name 'target-folder-already-there-different-version' `
    -Preinstalled '0.0.9' -Answers @('', '', 'y') -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'mirrik 0\.0\.9') { $p += 'the replaced version is not named' }
        return $p
    }

# --- Group: hotkey key --------------------------------------------------------------

Invoke-Case -Name 'hotkey-valid-key' -Answers @('', '', 'y', 'J', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+J'
    return $p
}

Invoke-Case -Name 'hotkey-multichar-then-valid' -Answers @('', '', 'y', 'abc', 'K', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'One letter or digit') { $p += 'no repeated question after multi-character input' }
    $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+K'
    return $p
}

Invoke-Case -Name 'hotkey-special-char-then-valid' -Answers @('', '', 'y', '%', 'L', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+L'
    return $p
}

Invoke-Case -Name 'hotkey-altgr-collision-overridden' -Answers @('', '', 'y', 'Q', 'n') `
    -AltGr 'Q=@,E=€' -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'AltGr') { $p += 'no AltGr warning' }
        $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+Q'
        return $p
    }

Invoke-Case -Name 'hotkey-taken-combination-then-other' -Answers @('', '', 'y', 'Q', 'y', 'K', 'y') `
    -PreShortcuts @{ 'Other.lnk' = 'CTRL+ALT+Q' } -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'already used by the shortcut') { $p += 'no hint about the taken combination' }
        $p += Test-ShortcutHotkey $ctx 'CTRL+ALT+K'
        return $p
    }

# --- Group: build branch ------------------------------------------------------------------

Invoke-Case -Name 'build-binaries-present-no-cargo-needed' -Answers @('', '', 'n') -Check { param($ctx) Test-InstalledOk $ctx }

Invoke-Case -Name 'build-missing-with-cargo-accepted' -NoBinaries -Answers @('y', '', '', 'n') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ((Get-Content $ctx.LogFile -Raw) -notmatch '-p mirrik-cli -p mirrik-gui') {
        $p += 'cargo was not called with -p for both packages'
    }
    return $p
}

Invoke-Case -Name 'build-missing-with-cargo-declined' -NoBinaries -Answers @('n') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though an abort was expected' }
    if ($ctx.Out -notmatch 'cargo build --release -p mirrik-cli -p mirrik-gui') { $p += 'no hint on how to build it yourself' }
    return $p
}

Invoke-Case -Name 'msrv-too-old-default-no' -NoBinaries -CargoVersion '1.70.0' -Answers @('') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though an abort was expected' }
    if ($ctx.Out -notmatch 'One thing first') { $p += 'no MSRV warning' }
    if ($ctx.Out -notmatch 'rustup update') { $p += 'no hint about rustup update' }
    return $p
}

Invoke-Case -Name 'msrv-sufficient-silent' -NoBinaries -CargoVersion '2.0.0' -Answers @('n') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though an abort was expected' }
    if ($ctx.Out -match 'One thing first') { $p += 'MSRV warning despite a sufficient version' }
    return $p
}

Invoke-Case -Name 'build-missing-without-cargo' -NoBinaries -NoCargo -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though an abort was expected' }
    if ($ctx.Out -notmatch 'Rust is not installed either') { $p += 'no hint that Rust is missing too' }
    return $p
}

Invoke-Case -Name 'build-cargo-fails' -NoBinaries -CargoFails -Answers @('y') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though the build failed' }
    if ($ctx.Out -notmatch 'cargo build failed') { $p += 'no hint about the failed build' }
    return $p
}

# --- Group: PATH ------------------------------------------------------------------------

Invoke-Case -Name 'path-missing-accepted' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if (-not (Test-Path $ctx.PathFile)) { $p += 'PATH was not written' }
    return $p
}

Invoke-Case -Name 'path-missing-declined' -Answers @('', 'n', 'n') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'Skipped\. The window works') { $p += 'no hint about skipping' }
    return $p
}

Invoke-Case -Name 'path-already-in-detected' -Answers @('', '') -PrePath '{TARGET}' -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'That folder is already on your PATH') { $p += 'existing PATH entry was not detected' }
    return $p
}

Invoke-Case -Name 'path-other-mirrik-already-present' -Answers @('', '', 'y') `
    -StrayMirrikDir 'other-mirrik' -Check {
        param($ctx)
        $p = Test-InstalledOk $ctx
        if ($ctx.Out -notmatch 'another mirrik\.exe already on your PATH') { $p += 'no hint about the unrelated mirrik.exe found' }
        return $p
    }

# --- Group: prechecks (only what is actually reachable without Windows) -----

# Since [Environment]::OSVersion itself reports a version below 10 under Linux/pwsh,
# this branch is ALWAYS active here (see -RawAnswers above) and doesn't need a stub at
# all. The PowerShell minimum-version check (~line 269) is a different story though - we
# can't reach it, since it runs directly against $PSVersionTable before any function is
# even defined. See the .md for more on that one.
Invoke-Case -Name 'precheck-old-windows-declined' -RawAnswers -Answers @('n') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though an abort was expected' }
    if ($ctx.Out -notmatch 'has not') { $p += 'no warning about the old Windows version' }
    return $p
}

Invoke-Case -Name 'precheck-old-windows-accepted' -RawAnswers -Answers @('y', '', '', 'y') -Check {
    param($ctx) Test-InstalledOk $ctx
}

Invoke-Case -Name 'precheck-administrator-warning' -Admin -Answers @('n') -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -eq 0) { $p += 'exit code 0, even though an abort was expected' }
    if ($ctx.Out -notmatch 'running this as administrator') { $p += 'no administrator warning' }
    return $p
}

Invoke-Case -Name 'precheck-no-administrator-no-warning' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -match 'running this as administrator') { $p += 'warning appeared despite not being administrator' }
    return $p
}

Invoke-Case -Name 'precheck-basic-adapter-warning' -Adapters 'Microsoft Basic Display Adapter' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'OpenGL 2\.0 or better') { $p += 'no warning about the basic adapter' }
    return $p
}

Invoke-Case -Name 'precheck-real-adapter-no-warning' -Adapters 'NVIDIA GeForce RTX 4070' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -match 'OpenGL 2\.0 or better') { $p += 'warning appeared despite a real adapter' }
    return $p
}

Invoke-Case -Name 'precheck-rdp-hint' -SessionName 'RDP-Tcp#1' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'Remote Desktop session') { $p += 'no RDP hint' }
    return $p
}

# --- Group: second run, uninstall, uninstall without an installation ------

Invoke-Case -Name 'second-run-replaces-running-version' -Preinstalled '0.0.5' -Answers @('', '', 'y') -Check {
    param($ctx)
    $p = Test-InstalledOk $ctx
    if ($ctx.Out -notmatch 'mirrik 0\.0\.5') { $p += 'the replaced version is not named' }
    return $p
}

Invoke-Case -Name 'uninstall-clears-everything' -Uninstall -RawAnswers -Preinstalled '0.1.0' `
    -PreShortcuts @{ 'Mirrik.lnk' = 'CTRL+ALT+J' } -Answers @('y') -Check {
        param($ctx)
        $p = @()
        if ($ctx.ExitCode -ne 0) { $p += "exit code $($ctx.ExitCode) instead of 0" }
        $dir = Join-Path $ctx.LocalAppData 'Programs\Mirrik'
        if (Test-Path $dir) { $p += 'program folder is still there after uninstalling' }
        if ($ctx.Out -notmatch 'Nothing of Mirrik is left') { $p += 'no closing message' }
        return $p
    }

Invoke-Case -Name 'uninstall-declined-changes-nothing' -Uninstall -RawAnswers -Preinstalled '0.1.0' `
    -PreShortcuts @{ 'Mirrik.lnk' = 'CTRL+ALT+J' } -Answers @('n') -Check {
        param($ctx)
        $p = @()
        $dir = Join-Path $ctx.LocalAppData 'Programs\Mirrik'
        if (-not (Test-Path $dir)) { $p += 'program folder was removed despite declining' }
        if ($ctx.Out -notmatch 'Nothing was changed') { $p += 'no confirmation that nothing was changed' }
        return $p
    }

# The settings file is the user's, never the installer's. So it is asked about on its
# own, after everything else, and "no" is what happens if you just press enter.
Invoke-Case -Name 'uninstall-keeps-own-config-by-default' -Uninstall -RawAnswers -Preinstalled '0.1.0' `
    -PreConfig -Answers @('y', '') -Check {
        param($ctx)
        $p = @()
        $cfg = Join-Path (Join-Path $ctx.AppData 'mirrik') 'config.toml'
        if (-not (Test-Path $cfg)) { $p += 'the config was removed even though the answer was empty (default is no)' }
        if ($ctx.Out -notmatch 'Mirrik never wrote that file') { $p += 'the config is not marked as the user own' }
        $dir = Join-Path $ctx.LocalAppData 'Programs\Mirrik'
        if (Test-Path $dir) { $p += 'program folder is still there after uninstalling' }
        return $p
    }

Invoke-Case -Name 'uninstall-removes-own-config-when-asked' -Uninstall -RawAnswers -Preinstalled '0.1.0' `
    -PreConfig -Answers @('y', 'y') -Check {
        param($ctx)
        $p = @()
        $cfg = Join-Path (Join-Path $ctx.AppData 'mirrik') 'config.toml'
        if (Test-Path $cfg) { $p += 'the config is still there despite answering yes' }
        return $p
    }

# Nothing installed, but a settings file left over: the program is gone, so there is
# nothing to remove - saying so and still naming the file is the point.
Invoke-Case -Name 'uninstall-without-installation-still-names-config' -Uninstall -RawAnswers `
    -PreConfig -Answers @() -Check {
        param($ctx)
        $p = @()
        if ($ctx.ExitCode -ne 0) { $p += "exit code $($ctx.ExitCode) instead of 0" }
        if ($ctx.Out -notmatch 'there is nothing to remove') { $p += 'no message that nothing is installed' }
        if ($ctx.Out -notmatch 'Your own settings are still there') { $p += 'the leftover config is not mentioned' }
        $cfg = Join-Path (Join-Path $ctx.AppData 'mirrik') 'config.toml'
        if (-not (Test-Path $cfg)) { $p += 'the config was removed on a run that removes nothing' }
        return $p
    }

Invoke-Case -Name 'uninstall-without-installation' -Uninstall -RawAnswers -Answers @() -Check {
    param($ctx)
    $p = @()
    if ($ctx.ExitCode -ne 0) { $p += "exit code $($ctx.ExitCode) instead of 0" }
    if ($ctx.Out -notmatch 'there is nothing to remove') { $p += 'no message that nothing is installed' }
    return $p
}

# ==================================================================

Write-Host ''
Write-Host "  $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) {
    Write-Host "  Failed: $($script:failedNames -join ', ')" -ForegroundColor Red
    exit 1
}
exit 0
