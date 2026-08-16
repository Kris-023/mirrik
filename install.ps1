<#
.SYNOPSIS
    Guided setup for Mirrik on Windows.

.DESCRIPTION
    Copies the two binaries somewhere permanent, optionally puts them on your PATH and
    optionally creates a Start menu shortcut with a global hotkey. Every step asks first,
    and -Uninstall undoes all of it.

    Nothing here needs administrator rights, and nothing is installed as a service or a
    driver.

.PARAMETER Uninstall
    Removes what a previous run installed, asking before each part.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- small helpers

function Say([string]$text, [string]$colour = 'Gray') {
    Write-Host $text -ForegroundColor $colour
}

function Heading([string]$text) {
    Write-Host ''
    Write-Host $text -ForegroundColor Cyan
    Write-Host ('-' * $text.Length) -ForegroundColor DarkCyan
}

function Ask([string]$question, [string]$fallback) {
    $answer = Read-Host "$question [$fallback]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $fallback }
    return $answer.Trim()
}

function Confirm([string]$question, [bool]$defaultYes = $true) {
    $hint = if ($defaultYes) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$question [$hint]").Trim().ToLower()
        if ($answer -eq '') { return $defaultYes }
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
        Say '  Please answer y or n.' DarkGray
    }
}

# The user PATH lives in the registry, and .NET's SetEnvironmentVariable is the wrong tool
# for it twice over: reading through it expands %USERPROFILE% and friends, and writing
# through it stores the result as a plain string. Do both and every variable someone had in
# their PATH is silently baked into a literal path that stops following them around.
# So: read raw, write back with the type it already had.
function Get-UserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if (-not $key) { return '' }
    try {
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [string]$value
    } finally { $key.Close() }
}

# Windows delivers AltGr as Ctrl+Alt, and a shortcut hotkey can only be Ctrl+Alt+<key>. On a
# German, French, Polish ... layout that means the hotkey quietly eats a character the user
# types: Ctrl+Alt+Q is @, Ctrl+Alt+E is EUR. Ask the layout which keys those are.
Add-Type -Namespace Mirrik -Name Keyboard -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint idThread);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern short VkKeyScanEx(char ch, IntPtr dwhkl);
'@

# Returns @{ 'Q' = '@'; 'E' = "€"; ... } for the active layout, empty on US-style ones.
function Get-AltGrKeys {
    $hkl = [Mirrik.Keyboard]::GetKeyboardLayout(0)
    $found = @{}
    # Walking the characters rather than the keys: every AltGr character a Windows layout
    # produces lives in Latin-1/Extended-A/B, plus the euro sign. ToUnicodeEx would answer
    # the other direction but can leave a dead key half-pressed behind - this cannot.
    foreach ($code in @(0x20..0x24F) + @(0x20AC)) {
        $scan = [Mirrik.Keyboard]::VkKeyScanEx([char]$code, $hkl)
        if ($scan -eq -1) { continue }
        if (((($scan -shr 8) -band 0xFF) -band 6) -ne 6) { continue }   # 2|4 = Ctrl+Alt = AltGr
        $vk = $scan -band 0xFF
        # Only the keys a hotkey may use: 0-9 and A-Z, whose virtual key codes are their ASCII.
        if ($vk -lt 0x30 -or $vk -gt 0x5A -or ($vk -gt 0x39 -and $vk -lt 0x41)) { continue }
        $key = [string][char]$vk
        if (-not $found.ContainsKey($key)) { $found[$key] = [string][char]$code }
    }
    return $found
}

function Set-UserPathRaw([string]$value) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        # Keep it expandable if it holds any variables, so they stay variables.
        $kind = if ($value -match '%') {
            [Microsoft.Win32.RegistryValueKind]::ExpandString
        } else {
            [Microsoft.Win32.RegistryValueKind]::String
        }
        $key.SetValue('Path', $value, $kind)
    } finally { $key.Close() }
    Publish-EnvironmentChange
}

# Without this, only programs started after the next sign-out see the new PATH. Explorer
# rebroadcasts it to everything it launches once it has been told.
function Publish-EnvironmentChange {
    if (-not ('MirrikEnv' -as [type])) {
        Add-Type -Namespace '' -Name 'MirrikEnv' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 2 second timeout
    [void][MirrikEnv]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero,
        'Environment', 2, 2000, [ref]$result)
}

# 0x8664 = x64, 0xAA64 = ARM64, 0x14C = x86. Read straight out of the PE header, so the
# answer is a fact rather than a guess about where the file came from.
function Get-ExeArchitecture([string]$path) {
    try {
        $stream = [IO.File]::OpenRead($path)
        try {
            $reader = New-Object IO.BinaryReader($stream)
            $stream.Position = 0x3C
            $stream.Position = $reader.ReadInt32() + 4
            switch ($reader.ReadUInt16()) {
                0x8664  { 'x64' }
                0xAA64  { 'ARM64' }
                0x014C  { 'x86' }
                default { 'unknown' }
            }
        } finally { $stream.Close() }
    } catch { 'unknown' }
}

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shortcutPath = Join-Path $startMenu 'Mirrik.lnk'

# ---------------------------------------------------------------- uninstall

if ($Uninstall) {
    Heading 'Removing Mirrik'

    $shell = New-Object -ComObject WScript.Shell
    $entries = (Get-UserPathRaw) -split ';' | Where-Object { $_ -ne '' }
    $state = Join-Path $env:LOCALAPPDATA 'mirrik'

    # Where it went is worked out, not asked. The shortcut points straight at it; failing
    # that, the PATH entry *is* it; failing both, there is the default. Asking would be a
    # keypress for an answer the machine already has - and the folder is named in the plan
    # below before anything is deleted, which is the check that matters.
    $installed = $null
    if (Test-Path $shortcutPath) {
        $target = $shell.CreateShortcut($shortcutPath).TargetPath
        if ($target) { $installed = Split-Path $target -Parent }
    }
    if (-not $installed) {
        $hit = $entries | Where-Object {
            Test-Path (Join-Path ([Environment]::ExpandEnvironmentVariables($_)) 'mirrik.exe')
        } | Select-Object -First 1
        if ($hit) { $installed = [Environment]::ExpandEnvironmentVariables($hit) }
    }
    if (-not $installed) { $installed = Join-Path $env:LOCALAPPDATA 'Programs\Mirrik' }

    # Compared expanded: a PATH written by hand may hold %LOCALAPPDATA% where this holds the
    # real path, and the two are the same folder. The raw entries are what gets written back.
    $onPath = @($entries | Where-Object {
        [Environment]::ExpandEnvironmentVariables($_) -eq $installed
    })

    # What is actually there is worked out first and shown in one go: uninstalling is a
    # single decision, not four. Each piece is looked for independently - a folder someone
    # deleted by hand must not leave the PATH entry and the shortcut behind for good.
    $plan = @()
    if (Test-Path $installed)    { $plan += "the programs in $installed" }
    if ($onPath.Count -gt 0)     { $plan += "the PATH entry for that folder" }
    if (Test-Path $shortcutPath) { $plan += 'the Start menu shortcut, and its hotkey with it' }
    if (Test-Path $state)        { $plan += "the leftover state folder $state" }

    if ($plan.Count -eq 0) {
        Say '  Nothing of Mirrik is installed here - there is nothing to remove.' Green
        Say ''
        exit 0
    }

    Say '  This removes:' DarkGray
    $plan | ForEach-Object { Say "    - $_" Gray }
    Say ''
    if (-not (Confirm '  Remove all of it?')) {
        Say '  Nothing was changed.' DarkGray
        Say ''
        exit 0
    }
    Say ''

    # Only now, so answering "no" above leaves a running mirror alone.
    $cli = Join-Path $installed 'mirrik.exe'
    if (Test-Path $cli) {
        Say '  Stopping any running mirror - Windows will not delete a running .exe.' DarkGray
        & $cli off 2>&1 | Out-Null
        Start-Sleep -Milliseconds 400
    }

    if (Test-Path $installed) {
        Say "  Deleting $installed" DarkGray
        try {
            Remove-Item $installed -Recurse -Force
            Say '    gone.' Green
        } catch {
            Say "    could not delete it: $($_.Exception.Message)" Red
            Say '    something in there is probably still running - close the Mirrik window and run this again.' DarkGray
        }
    }

    if ($onPath.Count -gt 0) {
        Say '  Removing the PATH entry' DarkGray
        Set-UserPathRaw (($entries | Where-Object { $onPath -notcontains $_ }) -join ';')
        Say '    gone. Open a new terminal for it to take effect.' Green
    }

    if (Test-Path $shortcutPath) {
        Say "  Deleting $shortcutPath" DarkGray
        Remove-Item $shortcutPath -Force
        Say '    gone.' Green
    }

    if (Test-Path $state) {
        Say "  Deleting $state" DarkGray
        Remove-Item $state -Recurse -Force
        Say '    gone.' Green
    }

    Say ''
    Say '  Done. Nothing of Mirrik is left except this repository.' Green
    Say ''
    exit 0
}

# ---------------------------------------------------------------- 0. what this is

Say ''
Say '  M I R R I K' Cyan
Say '  Play the same sound on two or more output devices at once.' DarkGray
Say ''
Say '  This script will, asking before each step:' DarkGray
Say '    1. check this machine can actually run it' DarkGray
Say '    2. put mirrik.exe and mirrik-gui.exe somewhere permanent' DarkGray
Say '    3. add that folder to your PATH, so `mirrik` works in any terminal' DarkGray
Say '    4. create a Start menu shortcut with a keyboard shortcut of your choice' DarkGray
Say ''
Say '  No administrator rights, no driver, no background service.' DarkGray
Say '  Run it again with -Uninstall to undo all of it.' DarkGray

# ---------------------------------------------------------------- 1. this machine

Heading '1. This machine'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Say "  This needs PowerShell 5.1 or newer; you have $($PSVersionTable.PSVersion)." Red
    Say '  Windows 10 and 11 both ship 5.1, so this is an unusually old system.' DarkGray
    exit 1
}

$os = [Environment]::OSVersion.Version
$build = $os.Build
# Windows 11 kept the major version at 10; the build number is what separates them.
$windows = if ($build -ge 22000) { "Windows 11 (build $build)" }
           elseif ($os.Major -ge 10) { "Windows 10 (build $build)" }
           else { "Windows $($os.Major).$($os.Minor)" }
Say "  $windows" Green

if ($os.Major -lt 10) {
    Say '  Mirrik uses WASAPI loopback the way Windows 10 and 11 expose it, and has not' Yellow
    Say '  been tried on anything older. It may well work; nobody has checked.' Yellow
    if (-not (Confirm '  Continue anyway?' $false)) { exit 1 }
}

$machineArch = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { 'unknown' }
Say "  Processor architecture: $machineArch" DarkGray

# Running the installer elevated is a trap rather than a help: the per-user folder, the
# per-user PATH and the Start menu it writes to all belong to the administrator account,
# not to the person who will be pressing the hotkey.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say ''
    Say '  You are running this as administrator. Nothing here needs that, and it' Yellow
    Say "  changes where things land: everything goes to $($identity.Name), not to" Yellow
    Say '  the account you normally use. If those are the same, carry on.' Yellow
    if (-not (Confirm '  Continue?' $false)) { exit 1 }
}

# The window is drawn with OpenGL. A machine with no real display driver - a fresh
# install, a VM, a Remote Desktop session - reports a basic adapter that stops at
# OpenGL 1.1, and the window then refuses to open with a message about needing 2.0+.
# The command line is unaffected, which is worth knowing before blaming the install.
$adapters = @()
try {
    $adapters = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
                  Select-Object -ExpandProperty Name)
} catch { }
$realGpu = $adapters | Where-Object { $_ -notmatch 'Basic (Display|Render)|Remote Display' }
if ($adapters.Count -gt 0 -and -not $realGpu) {
    Say ''
    Say "  Only a basic display adapter found: $($adapters -join ', ')" Yellow
    Say '  The window needs OpenGL 2.0 or better and will not open on this. Install the' Yellow
    Say '  graphics driver for your card. The command line works either way.' Yellow
} elseif ($env:SESSIONNAME -like 'RDP-*') {
    Say ''
    Say '  This is a Remote Desktop session. The window may fail to open here even' Yellow
    Say '  though it works fine at the physical machine - Remote Desktop hands programs' Yellow
    Say '  a display adapter without real OpenGL. Mirroring itself is unaffected.' Yellow
}

# ---------------------------------------------------------------- 2. the program

Heading '2. The program itself'

$root = $PSScriptRoot
# Deliberately not `target\debug`: it looks like a find, but installs whatever a developer
# last compiled - unoptimised, and carrying any debug output that was never meant to ship.
# If only a debug build exists, saying so and offering to build properly is the better answer.
$candidates = @(
    (Join-Path $root 'code\mirrik\target\release'),   # built from this repository
    $root                                            # unpacked release archive
)

$source = $null
foreach ($dir in $candidates) {
    if ((Test-Path (Join-Path $dir 'mirrik.exe')) -and (Test-Path (Join-Path $dir 'mirrik-gui.exe'))) {
        $source = $dir
        break
    }
}

if (-not $source) {
    Say '  Could not find mirrik.exe and mirrik-gui.exe next to this script.' Yellow
    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        Say '  Rust is installed, so they can be built now. This takes a few minutes' DarkGray
        Say '  the first time and needs an internet connection for the dependencies.' DarkGray
        if (-not (Confirm '  Build them now?')) {
            Say '  Nothing was changed. Build them yourself with:' DarkGray
            Say '    cargo build --release --manifest-path code\mirrik\Cargo.toml' Gray
            exit 1
        }
        Push-Location $root
        try {
            cargo build --release --manifest-path 'code\mirrik\Cargo.toml'
            if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
        } finally {
            Pop-Location
        }
        $source = Join-Path $root 'code\mirrik\target\release'
    } else {
        Say '  Rust is not installed either, so there is nothing to install.' Yellow
        Say '  Either download a release archive and run this script from inside it,' DarkGray
        Say '  or install Rust from https://rustup.rs and run this script again.' DarkGray
        Say '  Building also needs the Visual Studio build tools for the linker.' DarkGray
        exit 1
    }
}

Say "  Found them in: $source" Green

$exeArch = Get-ExeArchitecture (Join-Path $source 'mirrik-gui.exe')
Say "  Built for: $exeArch" DarkGray
if ($machineArch -eq 'ARM64' -and $exeArch -eq 'x64') {
    Say '  That is an x64 build on an ARM64 machine. Windows will run it under' Yellow
    Say '  emulation, which works but costs a little performance. Building from source' Yellow
    Say '  on this machine produces a native ARM64 binary.' Yellow
} elseif ($machineArch -eq 'AMD64' -and $exeArch -eq 'ARM64') {
    Say '  That is an ARM64 build on an x64 machine. It will not run here.' Red
    exit 1
}

# ---------------------------------------------------------------- 3. copy

Heading '3. Where they should live'

Say '  They need a permanent home. Running them out of a Downloads folder works' DarkGray
Say '  until you clear it out, and the shortcut breaks with it.' DarkGray
Say ''

$default = Join-Path $env:LOCALAPPDATA 'Programs\Mirrik'
$target = Ask '  Install to' $default

New-Item -ItemType Directory -Force -Path $target | Out-Null

# A running holder process would hold its own .exe open and the copy would fail halfway.
$existingCli = Join-Path $target 'mirrik.exe'
if (Test-Path $existingCli) {
    & $existingCli off 2>&1 | Out-Null
    Get-Process -Name 'mirrik', 'mirrik-gui' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and (Split-Path $_.Path -Parent) -eq $target } |
        ForEach-Object { $_.Kill() }
    Start-Sleep -Milliseconds 300
}

Copy-Item (Join-Path $source 'mirrik.exe') $target -Force
Copy-Item (Join-Path $source 'mirrik-gui.exe') $target -Force

# Strips the "downloaded from the internet" marker. Without this Windows shows the
# SmartScreen warning on every single launch, not just the first one.
Get-ChildItem $target -Filter *.exe | Unblock-File

$cli = Join-Path $target 'mirrik.exe'
$gui = Join-Path $target 'mirrik-gui.exe'
Say "  Copied to $target" Green
Say ''
Say '  If you ever want to check these are the files you think they are:' DarkGray
Get-FileHash $cli, $gui -Algorithm SHA256 | ForEach-Object {
    Say ("    {0}  {1}" -f $_.Hash.Substring(0, 16).ToLower(), (Split-Path $_.Path -Leaf)) DarkGray
}

# ---------------------------------------------------------------- 4. PATH

Heading '4. The command line'

$rawPath = Get-UserPathRaw
$entries = @($rawPath -split ';' | Where-Object { $_ -ne '' })

# An older copy somewhere else on the PATH wins or loses depending on the order, and
# then `mirrik` is not the mirrik you just installed.
$strays = @()
foreach ($entry in $entries) {
    if ($entry -eq $target) { continue }
    $expanded = [Environment]::ExpandEnvironmentVariables($entry)
    if ($expanded -and (Test-Path (Join-Path $expanded 'mirrik.exe') -ErrorAction SilentlyContinue)) {
        $strays += $expanded
    }
}
if ($strays.Count -gt 0) {
    Say '  There is another mirrik.exe already on your PATH:' Yellow
    $strays | ForEach-Object { Say "    $_" Yellow }
    Say '  Whichever comes first wins. Consider deleting the old one.' DarkGray
    Say ''
}

if ($entries -contains $target) {
    Say '  That folder is already on your PATH. Nothing to do.' Green
} else {
    Say '  Adding the folder to your PATH lets you type `mirrik devices` in any' DarkGray
    Say '  terminal instead of the full path. It only changes your own account.' DarkGray
    if (Confirm '  Add it?') {
        $updated = if ($entries.Count -eq 0) { $target } else { ($entries + $target) -join ';' }
        Set-UserPathRaw $updated
        Say '  Added. Open a new terminal for it to take effect.' Green
    } else {
        Say '  Skipped. The window works regardless; only the typed commands need this.' DarkGray
    }
}

# ---------------------------------------------------------------- 5. hotkey

Heading '5. Opening the window with a key'

Say '  Windows has no global hotkey setting of its own, but a shortcut in the Start' DarkGray
Say '  menu can carry one. That is the whole trick, and it needs nothing extra.' DarkGray
Say ''
Say '  Windows only allows Ctrl+Alt+<key> here, and it starts the program fresh' DarkGray
Say '  each time rather than raising a window that is already open.' DarkGray
Say ''

if (Confirm '  Create the shortcut?') {
    # Every shortcut with a hotkey is in one of these four places; a duplicate combination
    # goes to whichever Windows finds first, silently.
    $searchRoots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'),
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $shell = New-Object -ComObject WScript.Shell
    $taken = @{}
    foreach ($searchRoot in $searchRoots) {
        Get-ChildItem $searchRoot -Recurse -Filter *.lnk -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $link = $shell.CreateShortcut($_.FullName)
                    if ($link.HotKey -and $_.FullName -ne $shortcutPath) {
                        $taken[$link.HotKey.ToUpper()] = $_.BaseName
                    }
                } catch { }
            }
    }
    if ($taken.Count -gt 0) {
        Say "  ($($taken.Count) other shortcut(s) already carry a hotkey; conflicts will be flagged.)" DarkGray
    }

    $altgr = Get-AltGrKeys
    if ($altgr.Count -gt 0) {
        $examples = ($altgr.GetEnumerator() | Sort-Object Name | Select-Object -First 3 |
            ForEach-Object { "Ctrl+Alt+$($_.Name) types $($_.Value)" }) -join ', '
        Say '  Your keyboard layout uses AltGr, and Windows delivers AltGr as Ctrl+Alt.' Yellow
        Say "  A hotkey on one of those keys takes that character away: $examples." DarkGray
        Say ''
    }

    # Letters and digits that carry nothing on a European layout, so the suggestion is safe.
    $suggestion = @('J', 'K', 'L', 'T', 'U', 'V', 'W', 'Z', '1', '4', '5', '6') |
        Where-Object { -not $altgr.ContainsKey($_) -and -not $taken["CTRL+ALT+$_"] -and -not $taken["ALT+CTRL+$_"] } |
        Select-Object -First 1
    if (-not $suggestion) { $suggestion = 'M' }

    $key = $null
    while (-not $key) {
        $typed = (Ask '  Ctrl+Alt+  which key? (a single letter or digit)' $suggestion).ToUpper()
        if ($typed -notmatch '^[A-Z0-9]$') {
            Say '  One letter or digit, nothing else - that is all Windows accepts.' Yellow
            continue
        }
        if ($altgr.ContainsKey($typed)) {
            Say "  You type $($altgr[$typed]) with AltGr+$typed, and Windows cannot tell the two apart." Yellow
            Say "  Taking this key means losing $($altgr[$typed]) everywhere." DarkGray
            if (Confirm '  Pick a different key?') { continue }
        }
        # Windows stores it in this order; check both spellings rather than trust one.
        $clash = $taken["CTRL+ALT+$typed"]
        if (-not $clash) { $clash = $taken["ALT+CTRL+$typed"] }
        if ($clash) {
            Say "  Ctrl+Alt+$typed is already used by the shortcut `"$clash`"." Yellow
            Say '  Windows gives the combination to one of them and does not say which.' DarkGray
            if (Confirm '  Pick a different key?') { continue }
        }
        $key = $typed
    }

    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $gui
    $shortcut.WorkingDirectory = $target
    $shortcut.Description = 'Play the same sound on two or more output devices'
    $shortcut.HotKey = "CTRL+ALT+$key"
    $shortcut.Save()

    Say "  Done. Ctrl+Alt+$key opens the window from anywhere." Green
    Say '  It is also in the Start menu under "Mirrik".' DarkGray
    Say ''
    Say '  The hotkey only works while the shortcut stays in the Start menu - moving' DarkGray
    Say '  it to the Desktop is fine, deleting it turns the hotkey off.' DarkGray
} else {
    Say '  Skipped. You can always start it from:' DarkGray
    Say "    $gui" Gray
}

# ---------------------------------------------------------------- 6. warnings

Heading '6. What Windows will say the first time'

Say '  Mirrik is not signed with a code signing certificate, because those cost money' DarkGray
Say '  every year and this is a free tool. Windows treats every unsigned program the' DarkGray
Say '  same way, whatever it does:' DarkGray
Say ''
Say '    "Windows protected your PC - Microsoft Defender SmartScreen prevented an' Yellow
Say '     unrecognised app from starting."' Yellow
Say ''
Say '  There is no "run" button on that dialog. The way through is:' DarkGray
Say '    click "More info", then "Run anyway".' Gray
Say ''
Say '  This script has already stripped the download marker from the copied files,' DarkGray
Say '  so in most cases you will not see it at all. If you do, it appears once and' DarkGray
Say '  then Windows remembers.' DarkGray
Say ''
Say '  Two honest notes:' DarkGray
Say '    * That warning means "Microsoft has not seen this program often", not' DarkGray
Say '      "this program is dangerous". It says the same thing about every new' DarkGray
Say '      build of every unsigned tool.' DarkGray
Say '    * It is also exactly what actual malware wants you to click through. The' DarkGray
Say '      reason to trust this one is that you can read every line of it and build' DarkGray
Say '      it yourself - not that a dialog was dismissed.' DarkGray
Say ''
Say '  If a third-party antivirus quarantines it instead, this script deliberately' DarkGray
Say '  does not offer to add an exclusion for itself. Talking you into excluding an' DarkGray
Say '  unsigned binary from scanning is the single most useful thing a malicious' DarkGray
Say '  installer could do, so that decision stays yours, made in your own antivirus.' DarkGray

# ---------------------------------------------------------------- 7. verify

Heading '7. Checking it actually works'

$devices = & $cli devices 2>&1
if ($LASTEXITCODE -ne 0) {
    Say '  Mirrik could not list your output devices:' Red
    $devices | ForEach-Object { Say "    $_" Red }
    exit 1
}

# Names are the lines starting with "* " or two spaces; the ids under them start with four.
$count = ($devices | Where-Object { $_ -match '^(\* |  )\S' }).Count
Say "  Mirrik sees $count output device(s):" Green
$devices | ForEach-Object { Say "    $_" DarkGray }

if ($count -lt 2) {
    Say ''
    Say '  Only one output device. Mirroring needs at least two, so plug in a second' Yellow
    Say '  one (headphones, HDMI, Bluetooth) and it will show up here.' Yellow
}

# ---------------------------------------------------------------- done

Heading 'Done'

Say '  Open the window        the hotkey, or the Start menu entry' DarkGray
Say '  From a terminal        mirrik devices / mirrik on <name> / mirrik off' DarkGray
Say '  Closing the window     leaves the mirror running. `x` stops it.' DarkGray
Say ''
Say '  To undo all of this:' DarkGray
Say '    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall' Gray
Say ''
