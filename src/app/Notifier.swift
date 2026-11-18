// Notifier.swift — Battery Commander (BC) standalone app.
//
// App-native notifications (final cleanup 2026-11-18, owner order:
// notifications are the app's OWN — no external notifier tool is a
// product dependency anywhere). The app posts via
// UNUserNotificationCenter under its own bundle identity, so every
// notification carries the Battery Commander name and icon
// automatically.
//
// Transport: scripts/helpers never post directly. They append one
// request line per notification to ~/.battery-commander/.notify_queue:
//
//     title <TAB> body [<TAB> sound]
//
// (sound is optional: "Basso" for the critical ladder, "default",
// or absent for silent). The app drains the queue on its existing
// 10 s refresh cadence: it atomically renames the queue to a drain
// file, posts each line natively, logs the outcome to
// .notify_posted.log, and removes the drain file. Lines appended
// while a drain is in flight land in a fresh queue and are posted
// on the next refresh.

import Foundation
import UserNotifications

enum Notifier {

    private static var authRequested = false

    /// Ask once per process launch (the system shows the prompt only
    /// the first time for this bundle; later calls just report the
    /// current status). Called from applicationDidFinishLaunching.
    static func requestAuthorization(log: @escaping (String) -> Void) {
        if authRequested { return }
        authRequested = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                log("notify: authorization request error: \(error.localizedDescription)")
            } else {
                log("notify: authorization granted=\(granted)")
            }
        }
    }

    /// Post every queued request. Runs on the app's collect queue
    /// (background) — file IO and the settings lookup stay off the
    /// main thread.
    static func drain(dash: String, log: @escaping (String) -> Void) {
        let fm = FileManager.default
        let queuePath = (dash as NSString).appendingPathComponent(".notify_queue")
        let drainPath = queuePath + ".drain"

        // A leftover drain file is a drain that was interrupted
        // (app quit mid-drain): post it first, then the live queue.
        var files: [String] = []
        if fm.fileExists(atPath: drainPath) { files.append(drainPath) }
        if fm.fileExists(atPath: queuePath) {
            do {
                try fm.moveItem(atPath: queuePath, toPath: drainPath)
                if !files.contains(drainPath) { files.append(drainPath) }
            } catch {
                log("notify: queue rename failed: \(error.localizedDescription)")
                return
            }
        }
        if files.isEmpty { return }

        // Authorization gate: if the user has DENIED notifications
        // for the app, posting is impossible — record the drop in
        // the posted log (evidence, not silence) and clear.
        let status = authorizationStatus()
        for path in files {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            for line in lines {
                post(line: line, dash: dash, denied: status == .denied, log: log)
            }
            try? fm.removeItem(atPath: path)
        }
    }

    private static func authorizationStatus() -> UNAuthorizationStatus {
        var result: UNAuthorizationStatus = .notDetermined
        let sem = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            result = settings.authorizationStatus
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3.0)
        return result
    }

    private static func post(line: String, dash: String, denied: Bool, log: @escaping (String) -> Void) {
        let fields = line.components(separatedBy: "\t")
        let title = fields.count > 0 && !fields[0].isEmpty ? fields[0] : "Battery Commander"
        let body = fields.count > 1 ? fields[1] : ""
        let soundName = fields.count > 2 ? fields[2] : ""

        if denied {
            appendPostedLog(dash: dash, line: "DENIED (System Preferences) title=\(title) body=\(body)")
            log("notify: DENIED by system settings — dropped: \(title)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        switch soundName {
        case "Basso": content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "Basso.aiff"))
        case "default": content.sound = .default
        default: break
        }
        let request = UNNotificationRequest(identifier: "bc-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                appendPostedLog(dash: dash, line: "ERROR title=\(title) \(error.localizedDescription)")
                log("notify: post FAILED '\(title)': \(error.localizedDescription)")
            } else {
                appendPostedLog(dash: dash, line: "POSTED title=\(title) body=\(body)")
                log("notify: posted '\(title)'")
            }
        }
    }

    private static func appendPostedLog(dash: String, line: String) {
        let path = (dash as NSString).appendingPathComponent(".notify_posted.log")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = "[\(df.string(from: Date()))] \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
