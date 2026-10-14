import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
        NSLog("BattOpt native launched (PID %d)", ProcessInfo.processInfo.processIdentifier)
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.cleanup()
        NSLog("BattOpt native terminated")
    }
}
