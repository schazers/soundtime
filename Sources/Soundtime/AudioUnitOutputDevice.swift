import AudioToolbox
import CoreAudio
import Foundation
import SoundtimeAudioCore

final class AudioUnitOutputDevice: RealtimeAudioOutputDevice {
    private var audioUnit: AudioUnit?
    private var configuredSampleRate: Double?
    private var configuredOutputDeviceID: AudioDeviceID?
    private var callbackCorePointer: OpaquePointer?
    private var isInitialized = false
    private var isRunning = false

    func configure(corePointer: OpaquePointer, sampleRate: Double) throws {
        guard sampleRate > 0 else {
            throw PlaybackError.invalidFormat
        }

        let selectedOutputDeviceID = AudioDevicePreferences.shared.selectedOutputDeviceID()
        if callbackCorePointer != corePointer ||
            configuredSampleRate != sampleRate ||
            configuredOutputDeviceID != selectedOutputDeviceID
        {
            SoundtimeDiagnostics.shared.record(
                category: .device,
                severity: .info,
                name: "configure-output-device",
                message: "Configuring realtime output device.",
                fields: [
                    "sampleRate": String(format: "%.1f", sampleRate),
                    "deviceID": selectedOutputDeviceID.map(String.init) ?? "system-default",
                    "wasRunning": "\(isRunning)",
                ]
            )
            resetAudioUnit()
            let audioUnit = try configuredAudioUnit()
            if let selectedOutputDeviceID {
                var outputDeviceID = selectedOutputDeviceID
                try withUnsafePointer(to: &outputDeviceID) { devicePointer in
                    try check(AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        devicePointer,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    ))
                }
            }

            if isRunning {
                try check(AudioOutputUnitStop(audioUnit))
                isRunning = false
            }
            if isInitialized {
                try check(AudioUnitUninitialize(audioUnit))
                isInitialized = false
            }

            var streamFormat = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat |
                    kAudioFormatFlagIsPacked |
                    kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try withUnsafePointer(to: &streamFormat) { streamFormatPointer in
                try check(AudioUnitSetProperty(
                    audioUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    streamFormatPointer,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ))
            }

            var callback = AURenderCallbackStruct(
                inputProc: audioUnitOutputRenderCallback,
                inputProcRefCon: UnsafeMutableRawPointer(corePointer)
            )
            try withUnsafePointer(to: &callback) { callbackPointer in
                try check(AudioUnitSetProperty(
                    audioUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    callbackPointer,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ))
            }

            try check(AudioUnitInitialize(audioUnit))
            isInitialized = true
            configuredSampleRate = sampleRate
            configuredOutputDeviceID = selectedOutputDeviceID
            callbackCorePointer = corePointer
        }
    }

    func invalidateConfiguration() {
        SoundtimeDiagnostics.shared.record(
            category: .device,
            severity: .info,
            name: "invalidate-output-device",
            message: "Invalidating realtime output device configuration."
        )
        resetAudioUnit()
    }

    func start() throws {
        let audioUnit = try configuredAudioUnit()
        if !isInitialized {
            try check(AudioUnitInitialize(audioUnit))
            isInitialized = true
        }
        if !isRunning {
            try check(AudioOutputUnitStart(audioUnit))
            isRunning = true
        }
    }

    func stop() {
        guard let audioUnit else {
            return
        }

        if isRunning {
            _ = AudioOutputUnitStop(audioUnit)
            isRunning = false
        }
    }

    private func configuredAudioUnit() throws -> AudioUnit {
        if let audioUnit {
            return audioUnit
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw PlaybackError.outputDeviceFailed(kAudio_ParamError)
        }

        var audioUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &audioUnit))
        guard let audioUnit else {
            throw PlaybackError.outputDeviceFailed(kAudio_ParamError)
        }

        var enableOutput: UInt32 = 1
        try withUnsafePointer(to: &enableOutput) { enablePointer in
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                enablePointer,
                UInt32(MemoryLayout<UInt32>.size)
            ))
        }

        var disableInput: UInt32 = 0
        try withUnsafePointer(to: &disableInput) { disablePointer in
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                disablePointer,
                UInt32(MemoryLayout<UInt32>.size)
            ))
        }

        self.audioUnit = audioUnit
        return audioUnit
    }

    private func resetAudioUnit() {
        if let audioUnit {
            if isRunning {
                _ = AudioOutputUnitStop(audioUnit)
            }
            if isInitialized {
                _ = AudioUnitUninitialize(audioUnit)
            }
            AudioComponentInstanceDispose(audioUnit)
        }

        audioUnit = nil
        configuredSampleRate = nil
        configuredOutputDeviceID = nil
        callbackCorePointer = nil
        isInitialized = false
        isRunning = false
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw PlaybackError.outputDeviceFailed(status)
        }
    }
}

private let audioUnitOutputRenderCallback: AURenderCallback = {
    refCon,
    _,
    timestamp,
    _,
    frameCount,
    audioBufferList
    in
    guard let audioBufferList else {
        return noErr
    }

    let corePointer = OpaquePointer(refCon)
    let hostTime = timestamp.pointee.mHostTime
    let hostTimestamp = hostTime > 0 ?
        Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000 :
        0
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let leftOutput = buffers.count > 0 ?
        buffers[0].mData?.assumingMemoryBound(to: Float.self) :
        nil
    let rightOutput = buffers.count > 1 ?
        buffers[1].mData?.assumingMemoryBound(to: Float.self) :
        nil
    var outputPointers = (leftOutput, rightOutput)

    withUnsafeMutablePointer(to: &outputPointers) { pointer in
        pointer.withMemoryRebound(
            to: Optional<UnsafeMutablePointer<Float>>.self,
            capacity: 2
        ) { outputs in
            soundtime_audio_core_render_at_host_time(
                corePointer,
                outputs,
                2,
                frameCount,
                hostTimestamp
            )
        }
    }

    return noErr
}
