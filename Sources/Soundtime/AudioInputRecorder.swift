import AudioToolbox
import CoreAudio
import Foundation
import SoundtimeAudioCore

struct AudioRecordingChunk: Sendable {
    let samplesByChannel: [[Float]]
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let hostTimestamp: TimeInterval
}

final class AudioInputRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case audioUnitUnavailable
        case audioUnitFailed(OSStatus)
        case recordingRingUnavailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "No audio input device is available."
            case .audioUnitUnavailable:
                "Soundtime could not create an audio input unit."
            case let .audioUnitFailed(status):
                "The audio input unit failed with status \(status)."
            case .recordingRingUnavailable:
                "Soundtime could not create the realtime recording ring."
            }
        }
    }

    private static let chunkQueueKey = DispatchSpecificKey<Bool>()

    var onChunk: (@Sendable (AudioRecordingChunk) -> Void)?

    private var audioUnit: AudioUnit?
    private var recordingRing: OpaquePointer?
    private var renderAudioBufferList: UnsafeMutableAudioBufferListPointer?
    private var renderChannelPointers: [UnsafeMutablePointer<Float>] = []
    private var renderConstChannelPointers: [UnsafePointer<Float>?] = []
    private var renderFrameCapacity = 0
    private var drainChannelPointers: [UnsafeMutablePointer<Float>] = []
    private var drainOutputChannelPointers: [UnsafeMutablePointer<Float>?] = []
    private var drainFrameCapacity = 0
    private var ringDrainTimer: DispatchSourceTimer?
    private var sampleRate: Double = 44_100
    private var channelCount = 1
    private var isRunning = false
    private let chunkQueue = DispatchQueue(label: "Soundtime.audio.input.chunks", qos: .userInteractive)
    private let drainChunkFrameCapacity = 4_096
    private let maximumDrainChunksPerTick = 6

    init() {
        chunkQueue.setSpecific(key: Self.chunkQueueKey, value: true)
    }

    deinit {
        stop()
    }

    func start(deviceID requestedDeviceID: AudioDeviceID? = nil) throws {
        stop()

        guard let deviceID = requestedDeviceID ?? AudioDevicePreferences.shared.selectedInputDeviceID() else {
            throw RecorderError.noInputDevice
        }

        sampleRate = AudioDeviceRegistry.nominalSampleRate(for: deviceID) ?? 44_100
        let inputChannelCount = AudioDeviceRegistry.inputDevices()
            .first { $0.id == deviceID }?
            .inputChannelCount ?? 1
        channelCount = min(max(inputChannelCount, 1), 2)

        let audioUnit = try makeInputAudioUnit(deviceID: deviceID)
        self.audioUnit = audioUnit

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat |
                kAudioFormatFlagIsPacked |
                kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try withUnsafePointer(to: &streamFormat) { streamFormatPointer in
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                streamFormatPointer,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ))
        }

        var callback = AURenderCallbackStruct(
            inputProc: audioInputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try withUnsafePointer(to: &callback) { callbackPointer in
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                callbackPointer,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))
        }

        prepareRenderBuffers(
            frameCapacity: max(Int(maximumFramesPerSlice(for: audioUnit)), 16_384)
        )
        try prepareRecordingRing()

        do {
            try check(AudioUnitInitialize(audioUnit))
            try check(AudioOutputUnitStart(audioUnit))
            isRunning = true
            startRingDrainTimer()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let audioUnit, isRunning {
            _ = AudioOutputUnitStop(audioUnit)
            isRunning = false
        }

        if let audioUnit {
            _ = AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }

        ringDrainTimer?.cancel()
        ringDrainTimer = nil
        let drainAndReleaseRing = {
            self.drainRecordingRing()
            if let recordingRing = self.recordingRing {
                soundtime_audio_core_recording_ring_destroy(recordingRing)
                self.recordingRing = nil
            }
            self.releaseDrainBuffers()
        }
        if DispatchQueue.getSpecific(key: Self.chunkQueueKey) == true {
            drainAndReleaseRing()
        } else {
            chunkQueue.sync(execute: drainAndReleaseRing)
        }
        releaseRenderBuffers()
    }

    fileprivate func renderInput(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let audioUnit, frameCount > 0 else {
            return noErr
        }

        let frameCount = Int(frameCount)
        let currentChannelCount = max(channelCount, 1)
        guard
            frameCount <= renderFrameCapacity,
            currentChannelCount <= renderChannelPointers.count,
            let audioBufferList = renderAudioBufferList
        else {
            return kAudioUnitErr_TooManyFramesToProcess
        }

        for channelIndex in 0..<currentChannelCount {
            audioBufferList[channelIndex] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                mData: renderChannelPointers[channelIndex]
            )
        }

        let status = AudioUnitRender(
            audioUnit,
            actionFlags,
            timestamp,
            1,
            UInt32(frameCount),
            audioBufferList.unsafeMutablePointer
        )
        guard status == noErr else {
            return status
        }

        let hostTime = timestamp.pointee.mHostTime
        let hostTimestamp = hostTime > 0 ?
            Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000 :
            0
        guard let recordingRing else {
            return noErr
        }

        renderConstChannelPointers.withUnsafeBufferPointer { pointerBuffer in
            _ = soundtime_audio_core_recording_ring_push_planar(
                recordingRing,
                pointerBuffer.baseAddress,
                UInt32(currentChannelCount),
                UInt32(frameCount),
                hostTimestamp
            )
        }

        return noErr
    }

    private func makeInputAudioUnit(deviceID: AudioDeviceID) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecorderError.audioUnitUnavailable
        }

        var audioUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &audioUnit))
        guard let audioUnit else {
            throw RecorderError.audioUnitUnavailable
        }

        var enableInput: UInt32 = 1
        try withUnsafePointer(to: &enableInput) { enablePointer in
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                enablePointer,
                UInt32(MemoryLayout<UInt32>.size)
            ))
        }

        var disableOutput: UInt32 = 0
        try withUnsafePointer(to: &disableOutput) { disablePointer in
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                disablePointer,
                UInt32(MemoryLayout<UInt32>.size)
            ))
        }

        var inputDeviceID = deviceID
        try withUnsafePointer(to: &inputDeviceID) { devicePointer in
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                devicePointer,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ))
        }

        return audioUnit
    }

    private func maximumFramesPerSlice(for audioUnit: AudioUnit) -> UInt32 {
        var maximumFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            &size
        )

        guard status == noErr, maximumFrames > 0 else {
            return 4_096
        }
        return maximumFrames
    }

    private func prepareRenderBuffers(frameCapacity: Int) {
        releaseRenderBuffers()

        renderFrameCapacity = max(frameCapacity, 1)
        renderChannelPointers = (0..<max(channelCount, 1)).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: renderFrameCapacity)
        }
        renderConstChannelPointers = renderChannelPointers.map { UnsafePointer($0) }
        renderAudioBufferList = AudioBufferList.allocate(maximumBuffers: renderChannelPointers.count)
    }

    private func releaseRenderBuffers() {
        for pointer in renderChannelPointers {
            pointer.deallocate()
        }
        renderChannelPointers = []
        renderConstChannelPointers = []
        renderAudioBufferList?.unsafeMutablePointer.deallocate()
        renderAudioBufferList = nil
        renderFrameCapacity = 0
    }

    private func prepareRecordingRing() throws {
        if let recordingRing {
            soundtime_audio_core_recording_ring_destroy(recordingRing)
            self.recordingRing = nil
        }

        let secondsOfRingCapacity = 15
        let frameCapacity = max(
            Int(max(sampleRate, 1).rounded()) * secondsOfRingCapacity,
            renderFrameCapacity * 16
        )
        guard let ring = soundtime_audio_core_recording_ring_create(
            UInt32(max(channelCount, 1)),
            UInt64(max(frameCapacity, 1)),
            sampleRate
        ) else {
            throw RecorderError.recordingRingUnavailable
        }

        recordingRing = ring
    }

    private func startRingDrainTimer() {
        ringDrainTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: chunkQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(8),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.drainRecordingRing()
        }
        ringDrainTimer = timer
        timer.resume()
    }

    private func drainRecordingRing() {
        guard let recordingRing else {
            return
        }

        let ringChannelCount = Int(soundtime_audio_core_recording_ring_channel_count(recordingRing))
        let ringSampleRate = soundtime_audio_core_recording_ring_sample_rate(recordingRing)
        guard ringChannelCount > 0, ringSampleRate > 0 else {
            return
        }

        prepareDrainBuffers(
            channelCount: ringChannelCount,
            frameCapacity: drainChunkFrameCapacity
        )

        var drainedChunkCount = 0
        while
            drainedChunkCount < maximumDrainChunksPerTick,
            soundtime_audio_core_recording_ring_available_frame_count(recordingRing) > 0
        {
            var hostTimestamp: Double = 0
            let framesRead = drainOutputChannelPointers.withUnsafeBufferPointer { pointerBuffer in
                soundtime_audio_core_recording_ring_pop_planar(
                    recordingRing,
                    pointerBuffer.baseAddress,
                    UInt32(ringChannelCount),
                    UInt32(drainFrameCapacity),
                    &hostTimestamp
                )
            }
            guard framesRead > 0 else {
                return
            }

            let frameCount = Int(framesRead)
            let samplesByChannel = drainChannelPointers.prefix(ringChannelCount).map { pointer in
                Array(UnsafeBufferPointer(start: pointer, count: frameCount))
            }
            onChunk?(AudioRecordingChunk(
                samplesByChannel: samplesByChannel,
                sampleRate: ringSampleRate,
                channelCount: ringChannelCount,
                frameCount: frameCount,
                hostTimestamp: hostTimestamp
            ))
            drainedChunkCount += 1
        }
    }

    private func prepareDrainBuffers(channelCount: Int, frameCapacity: Int) {
        let clampedChannelCount = max(channelCount, 1)
        let clampedFrameCapacity = max(frameCapacity, 1)
        guard
            drainChannelPointers.count != clampedChannelCount ||
            drainFrameCapacity != clampedFrameCapacity
        else {
            return
        }

        releaseDrainBuffers()
        drainFrameCapacity = clampedFrameCapacity
        drainChannelPointers = (0..<clampedChannelCount).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: clampedFrameCapacity)
        }
        drainOutputChannelPointers = drainChannelPointers.map { $0 }
    }

    private func releaseDrainBuffers() {
        for pointer in drainChannelPointers {
            pointer.deallocate()
        }
        drainChannelPointers = []
        drainOutputChannelPointers = []
        drainFrameCapacity = 0
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw RecorderError.audioUnitFailed(status)
        }
    }
}

private let audioInputRenderCallback: AURenderCallback = {
    refCon,
    actionFlags,
    timestamp,
    _,
    frameCount,
    _
    in
    let recorder = Unmanaged<AudioInputRecorder>.fromOpaque(refCon).takeUnretainedValue()
    return recorder.renderInput(
        actionFlags: actionFlags,
        timestamp: timestamp,
        frameCount: frameCount
    )
}
