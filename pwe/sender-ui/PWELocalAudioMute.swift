import CoreAudio
import Foundation

/// Silences this Mac's own speakers while its sound plays on the iMac.
///
/// Audio Relay copies the system mix with ScreenCaptureKit and leaves the Mac's
/// output alone, so both machines played, the iMac slightly behind (iMac18,3
/// baseline, 2026-10-19). Upstream's answer is to mute the Mac by hand: the
/// capture is taken before the hardware volume and mute (docs/audio.md).
/// This does it for them, and only to a device it found unmuted:
///
/// - It mutes the default output device and unmutes the same device afterwards,
///   only if it is still muted. Anything the person changes in between wins.
/// - If the default output changes (headphones in), the old device is restored
///   and the new one muted.
/// - The muted device's UID is written down first, so a crash cannot leave the
///   Mac silent: the next launch unmutes it.
@MainActor
final class PWELocalAudioMute {
    static let markerKey = "pwe.mutedOutputDeviceUID"

    private let defaults: UserDefaults
    private var held: (device: AudioObjectID, didMute: Bool)?
    private var wanted = false
    private var listener: AudioObjectPropertyListenerBlock?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        restoreAfterCrash()
    }

    /// Called whenever the engine's state may have changed.
    func update(mute: Bool) {
        wanted = mute
        if mute { holdDefaultOutput() } else { release() }
    }

    func release() {
        stopListening()
        guard let held else { return }
        self.held = nil
        if held.didMute, Self.isMuted(held.device) == true {
            Self.setMuted(held.device, false)
            PWELog.note("[pwe] the Mac's speakers are back on")
        }
        defaults.removeObject(forKey: Self.markerKey)
    }

    private func holdDefaultOutput() {
        guard let device = Self.defaultOutputDevice() else { return }
        if held?.device == device { return }
        release()
        startListening()
        guard Self.canMute(device), Self.isMuted(device) == false else {
            // Already silent, or a device without a mute switch: leave it as it is.
            held = (device, false)
            return
        }
        if let uid = Self.uid(of: device) { defaults.set(uid, forKey: Self.markerKey) }
        Self.setMuted(device, true)
        held = (device, true)
        PWELog.note("[pwe] muted the Mac's speakers while sound plays on the iMac")
    }

    private func restoreAfterCrash() {
        guard let uid = defaults.string(forKey: Self.markerKey) else { return }
        defaults.removeObject(forKey: Self.markerKey)
        guard let device = Self.device(uid: uid), Self.isMuted(device) == true else { return }
        Self.setMuted(device, false)
        PWELog.note("[pwe] unmuted the Mac's speakers left muted by an earlier run")
    }

    // MARK: - Default output changes

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func startListening() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                self.holdDefaultOutput()
            }
        }
        var address = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
    }

    private func stopListening() {
        guard let listener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        self.listener = nil
    }

    // MARK: - Core Audio

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = defaultOutputAddress
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func canMute(_ device: AudioObjectID) -> Bool {
        var address = muteAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var address = muteAddress()
        var value = UInt32(muted ? 1 : 0)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr { PWELog.note("[pwe] could not \(muted ? "mute" : "unmute") output device \(device): \(status)") }
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}
