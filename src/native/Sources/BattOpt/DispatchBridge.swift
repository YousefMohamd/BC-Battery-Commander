import Foundation

enum DispatchBridge {
    static func runDispatch(_ action: String, args: [String] = []) {
        let script = (StateStore.dashPath as NSString).appendingPathComponent("dispatch.sh")
        guard FileManager.default.fileExists(atPath: script) else {
            NSLog("BattOpt: dispatch.sh not found at \(script)")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script, action] + args
            do {
                try p.run()
                p.waitUntilExit()
                NSLog("BattOpt: dispatch \(action) exit \(p.terminationStatus)")
            } catch {
                NSLog("BattOpt: dispatch \(action) error \(error)")
            }
        }
    }
}
