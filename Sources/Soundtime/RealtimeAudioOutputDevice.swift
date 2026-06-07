import AVFoundation
import Foundation
import SoundtimeAudioCore

protocol RealtimeAudioOutputDevice: AnyObject {
    func configure(corePointer: OpaquePointer, sampleRate: Double) throws
    func invalidateConfiguration()
    func start() throws
    func stop()
}

final class AVAudioSourceNodeOutputDevice: RealtimeAudioOutputDevice {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configuredSampleRate: Double?

    func configure(corePointer: OpaquePointer, sampleRate: Double) throws {
        guard sampleRate > 0 else {
            throw PlaybackError.invalidFormat
        }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: false
            )
        else {
            throw PlaybackError.invalidFormat
        }

        if sourceNode == nil {
            let sourceNode = AVAudioSourceNode { _, timestamp, frameCount, audioBufferList in
                let hostTimestamp = AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
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

            engine.attach(sourceNode)
            self.sourceNode = sourceNode
        }

        if configuredSampleRate != sampleRate {
            engine.stop()
            if let sourceNode {
                engine.disconnectNodeOutput(sourceNode)
                engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
            }
            configuredSampleRate = sampleRate
        }

        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
    }

    func start() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    func stop() {
        engine.stop()
    }

    func invalidateConfiguration() {
        engine.stop()
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
        }
        configuredSampleRate = nil
    }
}
