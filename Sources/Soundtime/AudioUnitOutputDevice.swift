import AudioToolbox
import CoreAudio
import Foundation
import SoundtimeAudioCore

final class AudioUnitOutputDevice: RealtimeAudioOutputDevice {
    private var audioUnit: AudioUnit?
    private var configuredSampleRate: Double?
    private var callbackCorePointer: OpaquePointer?
    private var isInitialized = false
    private var isRunning = false

    func configure(corePointer: OpaquePointer, sampleRate: Double) throws {
        guard sampleRate > 0 else {
            throw PlaybackError.invalidFormat
        }

        let audioUnit = try configuredAudioUnit()
        if callbackCorePointer != corePointer || configuredSampleRate != sampleRate {
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
            callbackCorePointer = corePointer
        }
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
            componentSubType: kAudioUnitSubType_DefaultOutput,
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

        self.audioUnit = audioUnit
        return audioUnit
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
