import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar / accessory app: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
