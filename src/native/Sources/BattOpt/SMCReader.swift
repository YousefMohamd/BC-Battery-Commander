import Foundation
import IOKit

struct BatterySnapshot {
    let pct: Int
    let isCharging: Bool
    let ext: Bool
    let ncr: Int
    let temp: Double
    let curCap: Int
    let maxCap: Int
    let chCur: Int
}

enum SMCReader {
    static func readBattery() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(
            kIOMasterPortDefault,
            IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props,
                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let curCap = dict["CurrentCapacity"] as? Int ?? 0
        let maxCap = dict["MaxCapacity"] as? Int ?? 1
        let isChg  = dict["IsCharging"] as? Bool ?? false
        let ext    = dict["ExternalConnected"] as? Bool ?? false
        let chCur  = dict["ChargingCurrent"] as? Int ?? 0

        var ncr = 0
        if let cd = dict["ChargerData"] as? [String: Any],
           let n = cd["NotChargingReason"] as? Int { ncr = n }
        if let n = dict["NotChargingReason"] as? Int { ncr = n }

        var temp = 0.0
        if let t = dict["Temperature"] as? Int { temp = Double(t) / 100.0 }
        else if let t = dict["Temperature"] as? Double { temp = t / 100.0 }

        let pct = maxCap > 0 ? (curCap * 100 + maxCap / 2) / maxCap : 0

        return BatterySnapshot(pct: pct, isCharging: isChg, ext: ext,
                               ncr: ncr, temp: temp,
                               curCap: curCap, maxCap: maxCap, chCur: chCur)
    }
}
