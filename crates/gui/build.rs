// Bettet icon.ico als Win32-Resource in mirrik-gui.exe ein. Das ist die Quelle,
// aus der Explorer, das Startmenue und eine angepinnte Taskleisten-Verknuepfung
// ihr Bild ziehen - das laufende Fenster setzt sein Icon separat, siehe
// `icon_rgba` in main.rs.
//
// Braucht rc.exe aus dem Windows SDK, das die MSVC-Toolchain ohnehin mitbringt.
// Auf allen anderen Zielen tut diese Datei nichts.
fn main() {
    println!("cargo:rerun-if-changed=assets/icon.ico");

    #[cfg(windows)]
    {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("assets/icon.ico");
        if let Err(e) = res.compile() {
            // Kein Abbruch: ohne Resource laeuft das Programm normal weiter,
            // es zeigt dann nur im Explorer das Standard-Icon.
            println!("cargo:warning=icon resource not embedded: {e}");
        }
    }
}
