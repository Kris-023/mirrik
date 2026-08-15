<#
.SYNOPSIS
    Guided setup for Mirrik on Windows.

.DESCRIPTION
    Copies the two binaries somewhere permanent, optionally puts them on your PATH and
    optionally creates a Start menu shortcut with a global hotkey. Every step asks first
    and every step is reversible by hand - see the summary it prints at the end.

    Nothing here needs administrator rights, and nothing is installed as a service or a
    driver.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
#>

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
        Say "  Please answer y or n." DarkGray
    }
}

# ---------------------------------------------------------------- 0. what this is

Say ''
Say '  M I R R I K' Cyan
Say '  Play the same sound on two or more output devices at once.' DarkGray
Say ''
Say '  This script will, asking before each step:' DarkGray
Say '    1. put mirrik.exe and mirrik-gui.exe somewhere permanent' DarkGray
Say '    2. add that folder to your PATH, so `mirrik` works in any terminal' DarkGray
Say '    3. create a Start menu shortcut with a keyboard shortcut of your choice' DarkGray
Say ''
Say '  No administrator rights, no driver, no background service.' DarkGray

# ---------------------------------------------------------------- 1. find the binaries

Heading '1. The program itself'

$root = $PSScriptRoot
$candidates = @(
    (Join-Path $root 'code\mirrik\target\release'),   # built from this repository
    (Join-Path $root 'code\mirrik\target\debug'),
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
        exit 1
    }
}

Say "  Found them in: $source" Green

# ---------------------------------------------------------------- 2. copy them

Heading '2. Where they should live'

Say '  They need a permanent home. Running them out of a Downloads folder works' DarkGray
Say '  until you clear it out, and the shortcut breaks with it.' DarkGray
Say ''

$default = Join-Path $env:LOCALAPPDATA 'Programs\Mirrik'
$target = Ask '  Install to' $default

New-Item -ItemType Directory -Force -Path $target | Out-Null
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

# ---------------------------------------------------------------- 3. PATH

Heading '3. The command line'

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -split ';' -contains $target) {
    Say '  That folder is already on your PATH. Nothing to do.' Green
} else {
    Say '  Adding the folder to your PATH lets you type `mirrik devices` in any' DarkGray
    Say '  terminal instead of the full path. It only changes your own account.' DarkGray
    if (Confirm '  Add it?') {
        $updated = if ([string]::IsNullOrEmpty($userPath)) { $target } else { "$userPath;$target" }
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        Say '  Added. Open a new terminal for it to take effect.' Green
    } else {
        Say '  Skipped. The window works regardless; only the typed commands need this.' DarkGray
    }
}

# ---------------------------------------------------------------- 4. hotkey

Heading '4. Opening the window with a key'

Say '  Windows has no global hotkey setting of its own, but a shortcut in the Start' DarkGray
Say '  menu can carry one. That is the whole trick, and it needs nothing extra.' DarkGray
Say ''
Say '  Windows only allows Ctrl+Alt+<key> here, and it starts the program fresh' DarkGray
Say '  each time rather than raising a window that is already open.' DarkGray
Say ''

if (Confirm '  Create the shortcut?') {
    $key = $null
    while (-not $key) {
        $typed = (Ask '  Ctrl+Alt+  which key? (a single letter or digit)' 'M').ToUpper()
        if ($typed -match '^[A-Z0-9]$') {
            $key = $typed
        } else {
            Say '  One letter or digit, nothing else - that is all Windows accepts.' Yellow
        }
    }

    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $link = Join-Path $startMenu 'Mirrik.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
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

# ---------------------------------------------------------------- 5. SmartScreen

Heading '5. What Windows will say the first time'

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

# ---------------------------------------------------------------- 6. does it work

Heading '6. Checking it actually works'

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
Say "    1. delete $target" Gray
Say "    2. remove that folder from your PATH (search Windows for 'environment variables')" Gray
Say '    3. delete the Start menu entry "Mirrik"' Gray
Say ''
