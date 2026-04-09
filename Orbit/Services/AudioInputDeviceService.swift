import CoreAudio
import Foundation

/// Stateless CoreAudio wrapper for input device enumeration.
///
/// Used by `SettingsView` to populate the microphone picker and by
/// `SpeechRecognitionService.beginCapture` to resolve the user's stored
/// device UID back to an `AudioDeviceID` that can be assigned to the
/// engine's input audio unit before starting capture.
///
/// Why CoreAudio rather than `AVCaptureDevice`: setting a specific input
/// device on `AVAudioEngine.inputNode` requires `AudioDeviceID` (CoreAudio's
/// runtime handle), and the cleanest way to get one for a given persistent
/// UID is to walk `kAudioHardwarePropertyDevices` ourselves. Going through
/// `AVCaptureDevice` adds an indirection without saving any code.
enum AudioInputDeviceService {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Enumerate every CoreAudio device that has at least one input stream.
    /// Output-only devices (speakers, HDMI displays) are filtered out.
    /// Sorted alphabetically by name. Synchronous, takes <1ms.
    static func listInputDevices() -> [Device] {
        let deviceIDs = allAudioDeviceIDs()
        var result: [Device] = []
        for deviceID in deviceIDs {
            guard hasInputStreams(deviceID) else { continue }
            guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else { continue }
            let name = stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? uid
            result.append(Device(id: deviceID, uid: uid, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a persistent UID back to its current AudioDeviceID.
    /// Returns nil if no connected device has that UID (e.g. unplugged).
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        return listInputDevices().first(where: { $0.uid == uid })?.id
    }

    // MARK: - CoreAudio plumbing

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }
        return deviceIDs
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let cf = cfString else { return nil }
        return cf as String
    }
}
