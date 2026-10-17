import Foundation
import IOKit.pwr_mgt

/// "Keep this Mac awake": a power assertion that stops idle sleep while
/// OntuTunnel runs. The display may still turn off; that doesn't matter.
enum KeepAwake {
    private static var assertion: IOPMAssertionID = 0

    static func set(_ on: Bool) {
        if on, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "OntuTunnel is serving your sites" as CFString, &assertion)
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

extension AppModel {
    func applyKeepAwake() {
        KeepAwake.set(config.keepAwake)
        if config.keepAwake { log("Settings", "This Mac will stay awake while OntuTunnel runs") }
    }
}
