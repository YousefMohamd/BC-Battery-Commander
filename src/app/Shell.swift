// Shell.swift — Battery Commander (BC) standalone app, Stage A (bench).
//
// Minimal process runner: the app only ever runs the user's own tools
// (bc-status, display_state.sh, dispatch.sh, ioreg, pmset, ...) exactly
// as the SwiftBar plugin does today. No network, no writes.

import Foundation

enum Shell {
    struct Result {
        var status: Int32
        var stdout: String
    }

    /// Run a process to completion, capturing stdout. Output is drained
    /// concurrently so large outputs (pmset -g log) cannot deadlock on
    /// a full pipe. stderr is discarded (the plugin does the same).
    static func run(_ path: String, _ args: [String] = [],
                    env extraEnv: [String: String] = [:]) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            proc.environment = env
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        var data = Data()
        let lock = NSLock()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
            } else {
                lock.lock(); data.append(chunk); lock.unlock()
            }
        }
        do {
            try proc.run()
        } catch {
            handle.readabilityHandler = nil
            return Result(status: -1, stdout: "")
        }
        proc.waitUntilExit()
        // Drain anything left after exit.
        let rest = handle.readDataToEndOfFile()
        lock.lock(); data.append(rest); lock.unlock()
        handle.readabilityHandler = nil
        let text = String(data: data, encoding: .utf8) ?? ""
        return Result(status: proc.terminationStatus, stdout: text)
    }

    /// Fire-and-forget launch used for dispatch.sh actions (dispatch may
    /// open dialogs that wait for minutes — the UI must never block).
    /// Returns the Process so the caller can observe termination.
    @discardableResult
    static func launch(_ path: String, _ args: [String] = [],
                       onExit: @escaping (Int32) -> Void) -> Process? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in onExit(p.terminationStatus) }
        do {
            try proc.run()
            return proc
        } catch {
            return nil
        }
    }
}

// MARK: - Small parsing helpers mirroring the plugin's shell idioms

/// First regex capture group match in `text`, or nil.
func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let m = re.firstMatch(in: text, range: range),
          m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

/// True when the string is non-empty and all ASCII digits (the plugin's
/// `case "$x" in ''|*[!0-9]*)` guard).
func isAllDigits(_ s: String) -> Bool {
    if s.isEmpty { return false }
    return s.allSatisfy { $0 >= "0" && $0 <= "9" }
}

/// Integer value of an all-digits string, else nil.
func digitsToInt(_ s: String) -> Int? {
    guard isAllDigits(s) else { return nil }
    return Int(s)
}

/// Read a whole file as UTF-8, or nil when unreadable.
func readFile(_ path: String) -> String? {
    return try? String(contentsOfFile: path, encoding: .utf8)
}

/// Read at most the LAST `maxBytes` bytes of a file as UTF-8
/// (perf fix, 2026-11-26). Used for the ever-growing daemon log:
/// the app only ever needs the newest state lines and today's
/// WRITE count, so parsing the whole multi-MB file on every
/// refresh was pure waste. The first partial line of the window
/// is dropped so callers never see a truncated record.
func readFileTail(_ path: String, maxBytes: Int) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }
    let end = handle.seekToEndOfFile()
    if end <= UInt64(maxBytes) {
        handle.seek(toFileOffset: 0)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
    handle.seek(toFileOffset: end - UInt64(maxBytes))
    let data = handle.readDataToEndOfFile()
    guard var text = String(data: data, encoding: .utf8) else { return nil }
    if let nl = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: nl)...])
    }
    return text
}

/// `$(cat file)` semantics: contents with trailing newlines stripped,
/// nil when the file cannot be read.
func readFileStripped(_ path: String) -> String? {
    guard var s = readFile(path) else { return nil }
    while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
    return s
}

/// File modification age in seconds (the plugin's stat -f %m checks),
/// nil when the file is missing.
func fileAgeSeconds(_ path: String) -> Int? {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let mtime = attrs[.modificationDate] as? Date else { return nil }
    return Int(Date().timeIntervalSince(mtime))
}

/// Split on the FIRST occurrence of `sep` (shell ${var%%sep*} /
/// ${var#*sep} semantics pair).
func splitFirst(_ s: String, _ sep: String) -> (head: String, tail: String)? {
    guard let r = s.range(of: sep) else { return nil }
    return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
}

