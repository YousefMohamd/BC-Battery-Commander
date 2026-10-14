import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.yousef.battopt.native"
        }
        if running.count > 1 {
            NSLog("BattOpt: another instance running — exiting")
            NSApp.terminate(nil)
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let lock = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".battopt-swiftbar/.native.lock")
        try? "\(pid)".write(toFile: lock, atomically: true, encoding: .utf8)

        statusController = StatusItemController()
        NSLog("BattOpt native launched (PID \(pid))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.cleanup()
        let lock = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".battopt-swiftbar/.native.lock")
        try? FileManager.default.removeItem(atPath: lock)
    }
}
