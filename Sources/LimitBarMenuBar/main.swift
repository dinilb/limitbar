import AppKit

// A menu-bar-only app: LSUIElement in the bundle Info.plist keeps it out of the
// Dock, and .accessory keeps it out of the Dock when run straight from the
// command line during development.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
