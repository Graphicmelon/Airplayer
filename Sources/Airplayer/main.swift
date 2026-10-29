// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
