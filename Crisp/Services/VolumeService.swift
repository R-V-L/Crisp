import Foundation
import CoreGraphics
import CoreAudio
import AppKit
import os.log

/// DDC/CI speaker volume (VCP 0x62) for external monitors (issue #23):
/// support probing, a coalesced writer, mute, and default-audio-output
/// matching for the volume keys. Mute uses the monitor's own VCP 0x8D when it
/// reports a known range, keeping 0x62 at the pre-mute level; panels that treat
/// 0x62 = 0 as a jump to loud (Acer G257HU, Samsung LS27A800U) therefore never
/// see a zero volume. Monitors without 0x8D fall back to 0x62 = 1, the quiet
/// floor measured on those panels.
@MainActor
final class VolumeService: ObservableObject {
    static let shared = VolumeService()
    private init() {}

    private static let log = Logger(subsystem: "com.crisp.app", category: "volume")

    /// DDC max volume per display (usually 100), from the probe read through
    /// DDCVolumeMax.
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]
    /// Volume to restore on unmute, captured when mute drops to zero.
    private var preMuteVolume: [CGDirectDisplayID: Double] = [:]
    /// VCP 0x8D mute values per display, nil until a probe confirms the shape.
    private var muteValues: [CGDirectDisplayID: DDCMuteValues] = [:]
    /// Displays muted through 0x8D, or through the 0x62 = 1 fallback.
    private var muted: Set<CGDirectDisplayID> = []
    /// Monotonic token per display, bumped by every user volume action. A probe
    /// that started before the action must not overwrite the UI when it lands.
    private var userGeneration: [CGDirectDisplayID: UInt64] = [:]
    private var nextGeneration: UInt64 = 0

    /// UUIDs of displays that have ever answered a 0x62 read. VCP support is a
    /// hardware fact, so remember it: a flaky launch-time probe (the
    /// wedged-read AOC) can miss, and without the memory the feature vanishes.
    private let capableKey = "crisp.volumeCapableDisplays"
    private lazy var rememberedCapable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: capableKey) ?? [])

    private func rememberCapable(_ uuid: String) {
        guard rememberedCapable.insert(uuid).inserted else { return }
        UserDefaults.standard.set(Array(rememberedCapable), forKey: capableKey)
    }

    /// UUIDs the user forced volume-capable (issue #57): some monitors accept
    /// 0x62 writes but never answer a 0x62 read, so the probe can't prove
    /// support. Forced displays run write-only at the assumed max of 100.
    private let forcedKey = "crisp.volumeForcedDisplays"
    /// Published so the Settings block's Show Volume Sliders row re-checks on
    /// toggle; DisplayInfo.volumeSupported alone only re-renders one card.
    @Published private var forcedCapable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "crisp.volumeForcedDisplays") ?? [])

    func isForced(_ display: DisplayInfo) -> Bool {
        forcedCapable.contains(display.displayUUID)
    }

    func setForced(_ on: Bool, for display: DisplayInfo) {
        if on {
            forcedCapable.insert(display.displayUUID)
        } else {
            forcedCapable.remove(display.displayUUID)
        }
        UserDefaults.standard.set(Array(forcedCapable), forKey: forcedKey)
        // Un-forcing keeps the feature only if a real probe ever succeeded.
        display.volumeSupported = on || rememberedCapable.contains(display.displayUUID)
    }

    /// Drop per-display state for a disconnected display so a reused
    /// displayID cannot inherit it. rememberedCapable stays: it is UUID-keyed
    /// and deliberately permanent.
    func invalidate(for displayID: CGDirectDisplayID) {
        ddcMax.removeValue(forKey: displayID)
        preMuteVolume.removeValue(forKey: displayID)
        muteValues.removeValue(forKey: displayID)
        muted.remove(displayID)
        userGeneration.removeValue(forKey: displayID)
    }

    private func markUserAction(_ displayID: CGDirectDisplayID) {
        nextGeneration &+= 1
        userGeneration[displayID] = nextGeneration
    }

    // MARK: - Probe

    /// Reads VCP 0x62 once: success marks the display volume-capable and
    /// adopts the monitor's level, failure leaves the feature hidden. Safe to
    /// re-run on every refresh; a monitor answering late heals next pass.
    func refreshVolume(for display: DisplayInfo) {
        guard !display.isBuiltin else { return }
        // Seed from memory (or the user's force override) so a failed probe
        // can't hide the feature; the read below still adopts the monitor's
        // current level whenever it works.
        if rememberedCapable.contains(display.displayUUID) || forcedCapable.contains(display.displayUUID) {
            display.volumeSupported = true
        }
        let id = display.displayID
        let uuid = display.displayUUID
        let generation = userGeneration[id] ?? 0
        DDCService.shared.readAsync(displayID: id, command: DDCService.volumeVCP) { result in
            Task { @MainActor in
                guard (self.userGeneration[id] ?? 0) == generation else { return }
                guard let result else {
                    // Only while the feature is hidden: a remembered or forced
                    // display failing a probe is the DDC layer's line to log.
                    if !display.volumeSupported {
                        Self.log.notice("\(display.name, privacy: .public): volume probe (VCP 0x62) got no valid reply, slider hidden; the Volume Control toggle forces write-only")
                    }
                    return
                }
                let volumeMax = DDCVolumeMax.from(result.max)
                if !self.rememberedCapable.contains(uuid) {
                    Self.log.notice("\(display.name, privacy: .public): volume probe ok \(result.current, privacy: .public)/\(volumeMax, privacy: .public), slider shown")
                }
                self.ddcMax[id] = volumeMax
                display.volumeSupported = true
                self.rememberCapable(uuid)
                let hardwarePercent = Double(result.current) / Double(volumeMax) * 100.0
                self.readMute(for: display, hardwarePercent: hardwarePercent, generation: generation)
            }
        }
    }

    /// Follows the volume probe with a VCP 0x8D read: it tells whether the
    /// speakers are muted and whether this panel supports the real mute. A
    /// missing or unknown reply leaves the volume path on the 0x62 fallback.
    private func readMute(for display: DisplayInfo, hardwarePercent: Double, generation: UInt64) {
        let id = display.displayID
        DDCService.shared.readAsync(displayID: id, command: DDCService.muteVCP) { result in
            Task { @MainActor in
                guard (self.userGeneration[id] ?? 0) == generation else { return }
                guard let result, let values = DDCMuteValues.from(max: result.max) else {
                    // A failed or unknown 0x8D reply says nothing about mute;
                    // keep the last known state and just adopt the level.
                    if !self.muted.contains(id) {
                        self.adoptHardwareVolume(display, percent: hardwarePercent)
                    }
                    return
                }
                self.muteValues[id] = values
                if result.current == values.mute {
                    self.muted.insert(id)
                    // Keep 0x62 as the restore target; the slider shows mute.
                    if self.pending[id] == nil, !self.pumpActive.contains(id) {
                        if hardwarePercent > 0 {
                            self.preMuteVolume[id] = hardwarePercent
                        }
                        display.volume = 0
                    }
                } else {
                    self.muted.remove(id)
                    self.adoptHardwareVolume(display, percent: hardwarePercent)
                }
            }
        }
    }

    /// Adopts the hardware 0x62 level only while our writer is idle, so a stale
    /// cached read never fights an in-flight drag.
    private func adoptHardwareVolume(_ display: DisplayInfo, percent: Double) {
        let id = display.displayID
        guard pending[id] == nil, !pumpActive.contains(id) else { return }
        display.volume = percent
    }

    // MARK: - Set (coalesced)

    /// Latest pending percent per display; only one DDC write in flight each.
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var pumpActive: Set<CGDirectDisplayID> = []

    /// Sets speaker volume (0–100). Coalesced like the brightness writer:
    /// latest value wins, writes paced to the MCCS ~50ms spacing so slider
    /// drags don't flood the I2C bus that brightness shares. Zero means mute;
    /// it never writes 0x62 = 0, which some panels turn into full volume.
    func setVolume(_ percent: Double, for display: DisplayInfo) {
        markUserAction(display.displayID)
        let clamped = max(0.0, min(100.0, percent))
        if clamped == 0 {
            mute(display)
            return
        }
        if muted.contains(display.displayID) {
            unmute(display)
        }
        display.volume = clamped
        pending[display.displayID] = clamped
        pump(for: display.displayID)
    }

    /// Mute key behavior: at zero, restore the remembered pre-mute level (or
    /// 25 if there is none); otherwise remember the level and mute.
    func toggleMute(for display: DisplayInfo) {
        if muted.contains(display.displayID) || display.volume <= 0 {
            setVolume(preMuteVolume[display.displayID] ?? 25, for: display)
        } else {
            setVolume(0, for: display)
        }
    }

    /// Mutes without writing 0x62 = 0. With 0x8D support the hardware stays at
    /// the pre-mute level and only the mute register changes; otherwise 0x62
    /// goes to 1, the quiet floor.
    private func mute(_ display: DisplayInfo) {
        let id = display.displayID
        if display.volume > 0 {
            preMuteVolume[id] = display.volume
        }
        display.volume = 0
        muted.insert(id)
        pending.removeValue(forKey: id)
        if let values = muteValues[id] {
            DDCService.shared.writeAsync(displayID: id, command: DDCService.muteVCP, value: values.mute)
        } else {
            DDCService.shared.writeAsync(displayID: id, command: DDCService.volumeVCP, value: 1)
        }
    }

    /// Clears the mute flag. The caller follows with the volume write, which
    /// restores the level on the 0x62 fallback and sets the new level otherwise.
    private func unmute(_ display: DisplayInfo) {
        let id = display.displayID
        guard muted.remove(id) != nil else { return }
        if let values = muteValues[id] {
            DDCService.shared.writeAsync(displayID: id, command: DDCService.muteVCP, value: values.unmute)
        }
    }

    private func pump(for id: CGDirectDisplayID) {
        guard !pumpActive.contains(id), let percent = pending.removeValue(forKey: id) else { return }
        pumpActive.insert(id)
        let raw = UInt16((percent / 100.0 * Double(ddcMax[id] ?? 100)).rounded())
        DDCService.shared.writeAsync(displayID: id, command: DDCService.volumeVCP, value: raw) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)  // MCCS write spacing
                self.pumpActive.remove(id)
                self.pump(for: id)
            }
        }
    }

    // MARK: - Volume-key routing

    /// The external display whose speakers own the default audio output, or
    /// nil to pass the keys through untouched. Matches by device name, with a
    /// single-candidate HDMI/DisplayPort fallback when names differ.
    /// ponytail: name + transport matching; per-display audio binding UI if
    /// same-model multi-monitor setups misroute.
    func displayForDefaultAudioOutput(in displays: [DisplayInfo]) -> DisplayInfo? {
        let candidates = displays.filter { !$0.isBuiltin && $0.volumeSupported }
        guard !candidates.isEmpty else { return nil }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        if let name = audioDeviceName(deviceID),
           let byName = candidates.first(where: { $0.name == name }) {
            return byName
        }
        if candidates.count == 1, let transport = audioTransportType(deviceID),
           transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort {
            return candidates[0]
        }
        return nil
    }

    private func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func audioTransportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }
}
