// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

guard CommandLine.arguments.count == 2 else { exit(2) }
let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "local.airplayer.mac").filter {
    $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target
}
for application in applications { _ = application.terminate() }
let deadline = Date().addingTimeInterval(5)
while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
for application in applications where !application.isTerminated { _ = application.forceTerminate() }
if !applications.isEmpty { print("Stopped previous Airplayer instance.") }
