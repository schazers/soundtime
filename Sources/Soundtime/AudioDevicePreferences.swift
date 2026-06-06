import CoreAudio
import Foundation

struct AudioDeviceInfo: Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int

    var hasInput: Bool {
        inputChannelCount > 0
    }

    var hasOutput: Bool {
        outputChannelCount > 0
    }
}

enum AudioDeviceRegistry {
    static func inputDevices() -> [AudioDeviceInfo] {
        allDevices().filter(\.hasInput)
    }

    static func outputDevices() -> [AudioDeviceInfo] {
        allDevices().filter(\.hasOutput)
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &sampleRate
        )
        guard status == noErr, sampleRate.isFinite, sampleRate > 0 else {
            return nil
        }

        return sampleRate
    }

    private static func allDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else {
            return []
        }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kAudio_ParamError
            }

            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        guard status == noErr else {
            return []
        }

        return deviceIDs.map { deviceID in
            AudioDeviceInfo(
                id: deviceID,
                name: deviceName(for: deviceID) ?? "Audio Device \(deviceID)",
                inputChannelCount: channelCount(for: deviceID, scope: kAudioDevicePropertyScopeInput),
                outputChannelCount: channelCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStorage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<CFString?>.alignment
        )
        defer {
            nameStorage.deallocate()
        }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            nameStorage
        )
        let name = nameStorage.load(as: CFString?.self)
        guard status == noErr, let name else {
            return nil
        }

        return name as String
    }

    private static func channelCount(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawBuffer.deallocate()
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawBuffer)
        guard status == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { count, buffer in
            count + Int(buffer.mNumberChannels)
        }
    }
}

final class AudioDevicePreferences: @unchecked Sendable {
    static let shared = AudioDevicePreferences()
    static let didChangeNotification = Notification.Name("SoundtimeAudioDevicePreferencesDidChange")

    private let selectedInputDeviceIDKey = "Soundtime.selectedInputDeviceID"
    private let selectedOutputDeviceIDKey = "Soundtime.selectedOutputDeviceID"
    private let userDefaults = UserDefaults.standard

    func selectedInputDeviceID() -> AudioDeviceID? {
        selectedDeviceID(
            key: selectedInputDeviceIDKey,
            availableDevices: AudioDeviceRegistry.inputDevices(),
            defaultDeviceID: AudioDeviceRegistry.defaultInputDeviceID()
        )
    }

    func selectedOutputDeviceID() -> AudioDeviceID? {
        selectedDeviceID(
            key: selectedOutputDeviceIDKey,
            availableDevices: AudioDeviceRegistry.outputDevices(),
            defaultDeviceID: AudioDeviceRegistry.defaultOutputDeviceID()
        )
    }

    func setSelectedInputDeviceID(_ deviceID: AudioDeviceID?) {
        setSelectedDeviceID(deviceID, key: selectedInputDeviceIDKey)
    }

    func setSelectedOutputDeviceID(_ deviceID: AudioDeviceID?) {
        setSelectedDeviceID(deviceID, key: selectedOutputDeviceIDKey)
    }

    func explicitlySelectedInputDeviceID() -> AudioDeviceID? {
        explicitlySelectedDeviceID(key: selectedInputDeviceIDKey)
    }

    func explicitlySelectedOutputDeviceID() -> AudioDeviceID? {
        explicitlySelectedDeviceID(key: selectedOutputDeviceIDKey)
    }

    private func selectedDeviceID(
        key: String,
        availableDevices: [AudioDeviceInfo],
        defaultDeviceID: AudioDeviceID?
    ) -> AudioDeviceID? {
        if
            let explicitDeviceID = explicitlySelectedDeviceID(key: key),
            availableDevices.contains(where: { $0.id == explicitDeviceID })
        {
            return explicitDeviceID
        }

        return defaultDeviceID
    }

    private func explicitlySelectedDeviceID(key: String) -> AudioDeviceID? {
        guard userDefaults.object(forKey: key) != nil else {
            return nil
        }

        let value = userDefaults.integer(forKey: key)
        guard value > 0 else {
            return nil
        }

        return AudioDeviceID(value)
    }

    private func setSelectedDeviceID(_ deviceID: AudioDeviceID?, key: String) {
        if let deviceID {
            userDefaults.set(Int(deviceID), forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }

        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
