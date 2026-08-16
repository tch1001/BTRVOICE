import AudioToolbox
import CoreAudio
import Foundation

/// Discovers macOS audio hardware and identifies device pairs that are likely to
/// support Apple's full-duplex VoiceProcessingIO echo canceller.
struct JarvisAudioDevice: Identifiable, Hashable {
    let objectID: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let inputChannels: UInt32
    let outputChannels: UInt32
    let relatedDeviceIDs: Set<AudioDeviceID>
    let isDefaultInput: Bool
    let isDefaultOutput: Bool

    var id: String { uid }
    var hasInput: Bool { inputChannels > 0 }
    var hasOutput: Bool { outputChannels > 0 }

    func pickerLabel(forInput: Bool) -> String {
        let isDefault = forInput ? isDefaultInput : isDefaultOutput
        return isDefault ? "\(name) — System default" : name
    }
}

struct JarvisAudioDeviceSnapshot {
    let inputs: [JarvisAudioDevice]
    let outputs: [JarvisAudioDevice]
    let defaultInputUID: String
    let defaultOutputUID: String
}

/// Watches Core Audio's device list and system-route markers so the Jarvis picker
/// stays current when hardware is connected, removed, or changed in Sound Settings.
/// The selected Jarvis route remains app-specific; these notifications only refresh
/// discovery and never mutate the Mac's global audio settings.
final class JarvisAudioDeviceMonitor {
    var onChange: (() -> Void)?

    private typealias Listener = AudioObjectPropertyListenerBlock
    private struct Registration {
        var address: AudioObjectPropertyAddress
        let listener: Listener
    }

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var registrations: [Registration] = []
    private var pendingRefresh: DispatchWorkItem?

    func start() {
        guard registrations.isEmpty else { return }
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: Listener = { [weak self] _, _ in
                self?.scheduleRefresh()
            }
            guard AudioObjectAddPropertyListenerBlock(
                system,
                &address,
                .main,
                listener
            ) == noErr else { continue }
            registrations.append(Registration(address: address, listener: listener))
        }
    }

    func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                system,
                &address,
                .main,
                registration.listener
            )
        }
        registrations.removeAll()
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRefresh = nil
            self?.onChange?()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    deinit {
        stop()
    }
}

enum JarvisAudioDeviceCatalog {
    static func snapshot() -> JarvisAudioDeviceSnapshot {
        let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let devices = deviceIDs().compactMap { device(
            $0,
            defaultInput: defaultInput,
            defaultOutput: defaultOutput
        ) }
        let inputs = devices.filter(\.hasInput).sorted(by: deviceOrder)
        let outputs = devices.filter(\.hasOutput).sorted(by: deviceOrder)
        return JarvisAudioDeviceSnapshot(
            inputs: inputs,
            outputs: outputs,
            defaultInputUID: inputs.first(where: \.isDefaultInput)?.uid ?? inputs.first?.uid ?? "",
            defaultOutputUID: outputs.first(where: \.isDefaultOutput)?.uid ?? outputs.first?.uid ?? ""
        )
    }

    /// VoiceProcessingIO works reliably with a duplex device, Core Audio related
    /// devices, or the Mac's built-in microphone/speaker pair. Arbitrary input and
    /// output devices make macOS synthesize an aggregate device and may fail when
    /// their channel layouts differ.
    static func likelySupportsEchoCancellation(
        input: JarvisAudioDevice?,
        output: JarvisAudioDevice?
    ) -> Bool {
        guard let input, let output else { return false }
        if input.objectID == output.objectID { return true }
        if input.relatedDeviceIDs.contains(output.objectID)
            || output.relatedDeviceIDs.contains(input.objectID) { return true }
        return input.transportType == kAudioDeviceTransportTypeBuiltIn
            && output.transportType == kAudioDeviceTransportTypeBuiltIn
    }

    /// AVAudioIONode uses the macOS default input and output for voice processing.
    /// A compatible pair selected only inside Jarvis is still safe for ordinary
    /// capture, but must not be handed to VoiceProcessingIO as a custom aggregate.
    static func supportsSystemVoiceProcessing(
        input: JarvisAudioDevice?,
        output: JarvisAudioDevice?
    ) -> Bool {
        guard let input, let output else { return false }
        return input.isDefaultInput
            && output.isDefaultOutput
            && likelySupportsEchoCancellation(input: input, output: output)
    }

    static func recommendedInput(
        for output: JarvisAudioDevice?,
        among inputs: [JarvisAudioDevice]
    ) -> JarvisAudioDevice? {
        guard let output else { return nil }
        return inputs
            .filter { likelySupportsEchoCancellation(input: $0, output: output) }
            .sorted { left, right in
                recommendationRank(left, output: output) < recommendationRank(right, output: output)
            }
            .first
    }

    private static func recommendationRank(
        _ input: JarvisAudioDevice,
        output: JarvisAudioDevice
    ) -> Int {
        if input.objectID == output.objectID { return 0 }
        if input.relatedDeviceIDs.contains(output.objectID)
            || output.relatedDeviceIDs.contains(input.objectID) { return 1 }
        if input.transportType == kAudioDeviceTransportTypeBuiltIn
            && output.transportType == kAudioDeviceTransportTypeBuiltIn { return 2 }
        if input.isDefaultInput { return 3 }
        return 4
    }

    private static func deviceOrder(_ left: JarvisAudioDevice, _ right: JarvisAudioDevice) -> Bool {
        let leftDefault = left.isDefaultInput || left.isDefaultOutput
        let rightDefault = right.isDefaultInput || right.isDefaultOutput
        if leftDefault != rightDefault { return leftDefault }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    private static func device(
        _ id: AudioDeviceID,
        defaultInput: AudioDeviceID,
        defaultOutput: AudioDeviceID
    ) -> JarvisAudioDevice? {
        guard let name = stringProperty(id, selector: kAudioObjectPropertyName),
              let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        return JarvisAudioDevice(
            objectID: id,
            uid: uid,
            name: name,
            transportType: uint32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0,
            inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            relatedDeviceIDs: Set(objectIDArrayProperty(id, selector: kAudioDevicePropertyRelatedDevices)),
            isDefaultInput: id == defaultInput,
            isDefaultOutput: id == defaultOutput
        )
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        objectIDArrayProperty(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        uint32Property(AudioObjectID(kAudioObjectSystemObject), selector: selector)
            ?? kAudioObjectUnknown
    }

    private static func uint32Property(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
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

    private static func objectIDArrayProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var values = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values) == noErr else {
            return []
        }
        return values
    }

    private static func channelCount(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return 0 }
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
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }
}
