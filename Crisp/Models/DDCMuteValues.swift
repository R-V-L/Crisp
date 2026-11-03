import Foundation

/// The value pair a monitor uses for VCP 0x8D (Audio Mute). The standard reply
/// is max 1 with 0 = unmute and 1 = mute; some panels report max 2 instead,
/// where 2 is the unmuted state and 0 is ignored (Acer G257HU, Samsung
/// LS27A800U, measured 2026-11-03). nil means the range is not one Crisp knows,
/// so callers fall back to muting with VCP 0x62.
struct DDCMuteValues: Equatable {
    let mute: UInt16
    let unmute: UInt16

    static func from(max: UInt16) -> DDCMuteValues? {
        switch max {
        case 1: return DDCMuteValues(mute: 1, unmute: 0)
        case 2: return DDCMuteValues(mute: 1, unmute: 2)
        default: return nil
        }
    }
}
