import AudioToolbox
import CoreAudio
import Foundation

/// A persisted input-source identifier. Microphones are the first source type;
/// keeping the type in the identifier leaves room for iPhone, glasses, or network
/// inputs without changing the preference or menu contract later.
enum AudioInputSourceID {
    static let systemDefault = "system-default"
    private static let microphonePrefix = "microphone:"

    static func microphone(uid: String) -> String {
        microphonePrefix + uid
    }

    static func microphoneUID(from sourceID: String) -> String? {
        guard sourceID.hasPrefix(microphonePrefix) else { return nil }
        let uid = String(sourceID.dropFirst(microphonePrefix.count))
        return uid.isEmpty ? nil : uid
    }
}

struct AudioInputDevice: Identifiable, Equatable {
    let objectID: AudioDeviceID
    let uid: String
    let name: String
    let isSystemDefault: Bool

    var id: String { uid }
    var sourceID: String { AudioInputSourceID.microphone(uid: uid) }
}

/// Core Audio discovery and app-local input routing for ordinary BtrVoice dictation.
/// It never changes the macOS system default device.
enum AudioInputSourceCatalog {
    static func microphones() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()
        return deviceIDs()
            .filter { inputChannelCount($0) > 0 }
            .compactMap { id in
                guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                      let name = stringProperty(id, selector: kAudioObjectPropertyName)
                else { return nil }
                return AudioInputDevice(
                    objectID: id,
                    uid: uid,
                    name: name,
                    isSystemDefault: id == defaultID
                )
            }
            .sorted { left, right in
                if left.isSystemDefault != right.isSystemDefault {
                    return left.isSystemDefault
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    static func selectionLabel(sourceID: String, savedName: String) -> String {
        if sourceID == AudioInputSourceID.systemDefault {
            let current = microphones().first(where: \.isSystemDefault)?.name
            return current.map { "System Default (\($0))" } ?? "System Default"
        }
        if let selected = microphones().first(where: { $0.sourceID == sourceID }) {
            return selected.name
        }
        return savedName.isEmpty ? "Selected microphone (unavailable)" : "\(savedName) (unavailable)"
    }

    /// Resolves the selection each time capture starts. Therefore System Default
    /// follows changes made in Sound Settings, while a microphone UID remains pinned.
    static func resolveDevice(
        sourceID: String,
        savedName: String
    ) throws -> AudioInputDevice {
        let devices = microphones()
        if sourceID == AudioInputSourceID.systemDefault {
            guard let device = devices.first(where: \.isSystemDefault) else {
                throw AudioInputSourceError.noSystemDefault
            }
            return device
        }
        guard let uid = AudioInputSourceID.microphoneUID(from: sourceID) else {
            throw AudioInputSourceError.unsupportedSource
        }
        guard let device = devices.first(where: { $0.uid == uid }) else {
            throw AudioInputSourceError.selectedMicrophoneUnavailable(savedName)
        }
        return device
    }

    static func systemDefaultDevice() throws -> AudioInputDevice {
        guard let device = microphones().first(where: \.isSystemDefault) else {
            throw AudioInputSourceError.noSystemDefault
        }
        return device
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var values = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &values) == noErr else {
            return []
        }
        return values
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &value) == noErr else {
            return kAudioObjectUnknown
        }
        return value
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        ).reduce(0) { $0 + $1.mNumberChannels }
    }
}

enum AudioInputSourceError: LocalizedError {
    case noSystemDefault
    case unsupportedSource
    case selectedMicrophoneUnavailable(String)
    case couldNotBind(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noSystemDefault:
            return "No usable system-default microphone was found."
        case .unsupportedSource:
            return "This input source is not supported by this version of BtrVoice."
        case .selectedMicrophoneUnavailable(let name):
            let label = name.isEmpty ? "The selected microphone" : name
            return "\(label) is not connected. Choose another source from Inputs."
        case .couldNotBind(let name, let status):
            let detail = NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
            return "BtrVoice could not use \(name): \(detail)"
        }
    }
}
