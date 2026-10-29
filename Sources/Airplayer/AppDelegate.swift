// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let receiver = ReceiverController()
    private(set) var window: NSWindow!
    private(set) var mirrorView: MirrorView!
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        mirrorView = MirrorView(deviceName: receiver.deviceName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        self.window = window
        window.title = "Airplayer"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor.black
        window.minSize = NSSize(width: 520, height: 380)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = mirrorView
        window.center()
        mirrorView.toggleFullscreen = { [weak window] in window?.toggleFullScreen(nil) }
        receiver.onFrame = { [weak self] frame in self?.mirrorView.display(frame) }
        receiver.onState = { [weak self] state in self?.mirrorView.setState(state) }
        mirrorView.onStats = { [weak self] text in self?.receiver.writeDiagnostic(text) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(mirrorView)
        NSApp.activate(ignoringOtherApps: true)
        if let error = mirrorView.renderingError { mirrorView.setState(.failed(error)) }
        else { receiver.start() }
        #if AIRPLAYER_DIAGNOSTICS
        if CommandLine.arguments.contains("--smoke-test") { runSmokeTest() }
        #endif
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏 Airplayer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Airplayer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let fullScreen = NSMenuItem(title: "切换全屏", action: #selector(toggleFullscreen), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        fullScreen.target = self
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    @objc func toggleFullscreen() { window.toggleFullScreen(nil) }


    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        receiver.stop { DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}
