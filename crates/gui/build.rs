// Embeds icon.ico into mirrik-gui.exe as a Win32 resource. That is where Explorer,
// the Start menu and a pinned taskbar shortcut get their picture from - the running
// window sets its own icon separately, see `icon_rgba` in main.rs.
//
// Needs rc.exe from the Windows SDK, which the MSVC toolchain brings along anyway.
// On every other target this file does nothing.
fn main() {
    println!("cargo:rerun-if-changed=assets/icon.ico");

    #[cfg(windows)]
    {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("assets/icon.ico");
        if let Err(e) = res.compile() {
            // We warn rather than fail. Without the resource the program still runs
            // fine, it just shows the default icon in Explorer.
            println!("cargo:warning=icon resource not embedded: {e}");
        }
    }
}
