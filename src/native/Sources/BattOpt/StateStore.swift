import Foundation

enum StateStore {
    static var dashPath: String {
        return (NSHomeDirectory() as NSString).appendingPathComponent(".battopt-swiftbar")
    }

    static func readActiveMode() -> String {
        let p = (dashPath as NSString).appendingPathComponent(".active_mode")
        guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { return "idle" }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "idle" : t
    }

    static func readConfig() -> (upper: Int, lower: Int, sailing: Bool, gap: Int) {
        let p = (dashPath as NSString).appendingPathComponent("config")
        guard let s = try? String(contentsOfFile: p, encoding: .utf8) else {
            return (85, 80, true, 10)
        }
        var upper = 85, lower = 80, gap = 10
        var sailing = true
        for line in s.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            switch k {
            case "LAST_UPPER": upper = Int(v) ?? 85
            case "LAST_LOWER": lower = Int(v) ?? 80
            case "SAILING":    sailing = (v == "true")
            case "SAIL_GAP":   gap = Int(v) ?? 10
            default: break
            }
        }
        return (upper, lower, sailing, gap)
    }
}
