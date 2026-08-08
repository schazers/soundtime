import Foundation

struct AudioFileEditTimeline: Sendable {
    typealias ClipRange = AudioTimelineClipRange
    typealias ClipEdge = AudioTimelineClipEdge

    struct PersistentSegment: Codable, Sendable {
        var sourceStartFrame: Int
        var frameCount: Int
        var gainStart: Float
        var gainEnd: Float
        var startsNewClip: Bool?
        var clipID: UUID?

        init(
            sourceStartFrame: Int,
            frameCount: Int,
            gainStart: Float,
            gainEnd: Float,
            startsNewClip: Bool? = nil,
            clipID: UUID? = nil
        ) {
            self.sourceStartFrame = sourceStartFrame
            self.frameCount = frameCount
            self.gainStart = gainStart
            self.gainEnd = gainEnd
            self.startsNewClip = startsNewClip
            self.clipID = clipID
        }
    }

    struct PersistentState: Codable, Sendable {
        var sourceFrameCount: Int
        var sourceSampleRate: Double
        var timelineSampleRate: Double?
        var segments: [PersistentSegment]

        init(
            sourceFrameCount: Int,
            sourceSampleRate: Double,
            timelineSampleRate: Double? = nil,
            segments: [PersistentSegment]
        ) {
            self.sourceFrameCount = sourceFrameCount
            self.sourceSampleRate = sourceSampleRate
            self.timelineSampleRate = timelineSampleRate
            self.segments = segments
        }
    }

    struct Clip: Sendable {
        var sourceFrameCount: Int
        var sourceSampleRate: Double
        var segments: [PersistentSegment]

        var frameCount: Int {
            segments.reduce(0) { $0 + $1.frameCount }
        }

        var duration: TimeInterval {
            guard sourceSampleRate > 0 else {
                return 0
            }
            return Double(frameCount) / sourceSampleRate
        }
    }

    let sourceFrameCount: Int
    let sourceSampleRate: Double
    let timelineSampleRate: Double
    private var arrangement: AudioSegmentArrangement

    init(fileInfo: WAVFileInfo) {
        self.init(
            sourceFrameCount: fileInfo.frameCount,
            sourceSampleRate: fileInfo.sampleRate
        )
    }

    init(sourceFrameCount: Int, sourceSampleRate: Double) {
        self.sourceFrameCount = max(sourceFrameCount, 0)
        self.sourceSampleRate = sourceSampleRate
        timelineSampleRate = sourceSampleRate
        if sourceFrameCount > 0, sourceSampleRate.isFinite, sourceSampleRate > 0 {
            arrangement = AudioSegmentArrangement(sourceFrameCount: sourceFrameCount)
        } else {
            arrangement = AudioSegmentArrangement(
                sourceFrameCount: max(sourceFrameCount, 0),
                segments: []
            )
        }
    }

    init?(persistentState: PersistentState) {
        guard
            persistentState.sourceFrameCount >= 0,
            persistentState.sourceSampleRate > 0,
            persistentState.sourceSampleRate.isFinite,
            (persistentState.timelineSampleRate ?? persistentState.sourceSampleRate) > 0,
            (persistentState.timelineSampleRate ?? persistentState.sourceSampleRate).isFinite
        else {
            return nil
        }

        sourceFrameCount = persistentState.sourceFrameCount
        sourceSampleRate = persistentState.sourceSampleRate
        timelineSampleRate = persistentState.timelineSampleRate ?? persistentState.sourceSampleRate
        arrangement = AudioSegmentArrangement(
            sourceFrameCount: sourceFrameCount,
            segments: Self.segments(from: persistentState)
        )
        guard sourceFrameCount == 0 || !arrangement.segments.isEmpty else {
            return nil
        }
    }

    init?(
        sourceFrameCount: Int,
        sourceSampleRate: Double,
        timelineSampleRate: Double? = nil,
        playbackSegments: [AudioEditTimeline.PlaybackSegment]
    ) {
        guard
            sourceFrameCount >= 0,
            sourceSampleRate > 0,
            sourceSampleRate.isFinite,
            (timelineSampleRate ?? sourceSampleRate) > 0,
            (timelineSampleRate ?? sourceSampleRate).isFinite
        else {
            return nil
        }

        self.sourceFrameCount = sourceFrameCount
        self.sourceSampleRate = sourceSampleRate
        self.timelineSampleRate = timelineSampleRate ?? sourceSampleRate
        arrangement = AudioSegmentArrangement(
            sourceFrameCount: sourceFrameCount,
            segments: playbackSegments.map { segment in
                AudioTimelineSegment(
                    sourceStartFrame: segment.sourceStartFrame,
                    frameCount: segment.frameCount,
                    gainStart: segment.gainStart,
                    gainEnd: segment.gainEnd,
                    startsNewClip: segment.startsNewClip,
                    clipID: segment.clipID
                )
            }
        )
        guard sourceFrameCount == 0 || !arrangement.segments.isEmpty else {
            return nil
        }
    }

    var frameCount: Int {
        arrangement.frameCount
    }

    var duration: TimeInterval {
        guard timelineSampleRate > 0 else {
            return 0
        }
        return Double(frameCount) / timelineSampleRate
    }

    var hasEdits: Bool {
        arrangement.hasEdits
    }

    var persistentState: PersistentState? {
        guard sourceFrameCount >= 0, sourceSampleRate > 0, sourceSampleRate.isFinite else {
            return nil
        }
        return PersistentState(
            sourceFrameCount: sourceFrameCount,
            sourceSampleRate: sourceSampleRate,
            timelineSampleRate: timelineSampleRate == sourceSampleRate ? nil : timelineSampleRate,
            segments: arrangement.segments.map(Self.persistentSegment)
        )
    }

    var playbackSegments: [AudioEditTimeline.PlaybackSegment] {
        arrangement.playbackSegments
    }

    func remapped(
        toSourceFrameCount destinationSourceFrameCount: Int,
        sampleRate destinationSampleRate: Double
    ) -> AudioFileEditTimeline? {
        guard
            sourceSampleRate.isFinite,
            sourceSampleRate > 0,
            destinationSampleRate.isFinite,
            destinationSampleRate > 0,
            destinationSourceFrameCount >= 0
        else {
            return nil
        }

        let rateScale = destinationSampleRate / sourceSampleRate
        let remappedSegments = playbackSegments.map { segment in
            let sourceStartFrame = min(
                max(Int((Double(segment.sourceStartFrame) * rateScale).rounded()), 0),
                destinationSourceFrameCount
            )
            let sourceEndFrame = min(
                max(
                    Int((Double(segment.sourceStartFrame + segment.frameCount) * rateScale).rounded()),
                    sourceStartFrame
                ),
                destinationSourceFrameCount
            )
            return AudioTimelinePlaybackSegment(
                outputStartFrame: 0,
                sourceStartFrame: sourceStartFrame,
                frameCount: max(sourceEndFrame - sourceStartFrame, 0),
                sourceFrameScale: 0,
                gainStart: segment.gainStart,
                gainEnd: segment.gainEnd,
                startsNewClip: segment.startsNewClip,
                clipID: segment.clipID
            )
        }
        .filter { $0.frameCount > 0 }

        return AudioFileEditTimeline(
            sourceFrameCount: destinationSourceFrameCount,
            sourceSampleRate: destinationSampleRate,
            timelineSampleRate: destinationSampleRate,
            playbackSegments: remappedSegments
        )
    }

    /// Promotes an original compressed-file timeline onto its editable proxy.
    /// Untouched imports must adopt the proxy's complete authoritative range;
    /// only real edits should preserve the provisional arrangement by remapping.
    func promotedToEditableProxy(fileInfo: WAVFileInfo) -> AudioFileEditTimeline {
        guard hasEdits else {
            return AudioFileEditTimeline(fileInfo: fileInfo)
        }
        return remapped(
            toSourceFrameCount: fileInfo.frameCount,
            sampleRate: fileInfo.sampleRate
        ) ?? AudioFileEditTimeline(fileInfo: fileInfo)
    }

    var clipRanges: [ClipRange] {
        arrangement.clipRanges
    }

    func clipRange(id: AudioTimelineClipID) -> ClipRange? {
        arrangement.clipRange(id: id)
    }

    func frameRange(forClipID id: AudioTimelineClipID) -> Range<Int>? {
        arrangement.frameRange(forClipID: id)
    }

    func audioTimeline(sourceBuffer: DecodedAudioBuffer) -> AudioEditTimeline {
        AudioEditTimeline(
            sourceBuffer: sourceBuffer,
            playbackSegments: playbackSegments
        )
    }

    func isCompatible(with fileInfo: WAVFileInfo) -> Bool {
        sourceFrameCount == fileInfo.frameCount &&
            abs(sourceSampleRate - fileInfo.sampleRate) < 0.001
    }

    func isCompatible(with clip: Clip) -> Bool {
        sourceFrameCount == clip.sourceFrameCount &&
            abs(sourceSampleRate - clip.sourceSampleRate) < 0.001
    }

    func clip(for selection: TimelineSelection) -> Clip? {
        clip(for: frameRange(for: selection))
    }

    func clip(for frameRange: Range<Int>) -> Clip? {
        let selectedSegments = arrangement.segments(in: frameRange)
        guard !selectedSegments.isEmpty else {
            return nil
        }
        let copiedClipID = AudioTimelineClipID()
        return Clip(
            sourceFrameCount: sourceFrameCount,
            sourceSampleRate: sourceSampleRate,
            segments: selectedSegments.enumerated().map { index, segment in
                Self.persistentSegment(segment.withClipID(
                    copiedClipID,
                    startsNewClip: index == 0
                ))
            }
        )
    }

    mutating func replace(_ selection: TimelineSelection, with clip: Clip) -> Int? {
        replace(frameRange: frameRange(for: selection), with: clip)
    }

    mutating func replace(frameRange: Range<Int>, with clip: Clip) -> Int? {
        guard isCompatible(with: clip) else {
            return nil
        }
        return arrangement.replace(
            frameRange: frameRange,
            with: Self.segmentsForInsertion(clip.segments)
        )
    }

    mutating func insert(_ clip: Clip, atFrame frame: Int) -> Int? {
        guard isCompatible(with: clip) else {
            return nil
        }
        return arrangement.insert(
            Self.segmentsForInsertion(clip.segments),
            atFrame: frame
        )
    }

    mutating func insertWithinClip(
        id: AudioTimelineClipID,
        localFrame: Int,
        clip: Clip
    ) -> Int? {
        guard isCompatible(with: clip) else {
            return nil
        }
        return arrangement.insertWithinClip(
            id: id,
            localFrame: localFrame,
            segments: Self.segmentsForInsertion(clip.segments)
        )
    }

    func waveformOverview(from sourceOverview: WaveformOverview) -> WaveformOverview {
        guard sourceFrameCount > 0, frameCount > 0, !sourceOverview.bins.isEmpty else {
            return WaveformOverview(duration: duration, bins: [])
        }
        if frameCount == sourceFrameCount, arrangement.hasSourceFrameAlignment {
            return equalDurationWaveformOverview(from: sourceOverview)
        }

        let sourceBinCount = sourceOverview.bins.count
        let sourceFramesPerBin = Double(sourceFrameCount) / Double(sourceBinCount)
        var editedBins: [WaveformOverview.Bin] = []
        editedBins.reserveCapacity(sourceBinCount)
        for segment in arrangement.segments {
            let startBin = min(
                max(Int((Double(segment.sourceStartFrame) / sourceFramesPerBin).rounded(.down)), 0),
                sourceBinCount
            )
            let endBin = min(
                max(Int((Double(segment.sourceEndFrame) / sourceFramesPerBin).rounded(.up)), startBin),
                sourceBinCount
            )
            guard startBin < endBin else {
                continue
            }
            if segment.hasConstantGain {
                if abs(segment.gainStart - 1) <= AudioSegmentArrangement.gainEpsilon {
                    editedBins.append(contentsOf: sourceOverview.bins[startBin..<endBin])
                } else {
                    for binIndex in startBin..<endBin {
                        editedBins.append(
                            sourceOverview.bins[binIndex].scaled(by: segment.gainStart)
                        )
                    }
                }
                continue
            }
            for binIndex in startBin..<endBin {
                let centerFrame = min(
                    max(Int((Double(binIndex) + 0.5) * sourceFramesPerBin), segment.sourceStartFrame),
                    max(segment.sourceEndFrame - 1, segment.sourceStartFrame)
                )
                editedBins.append(sourceOverview.bins[binIndex].scaled(
                    by: segment.gain(at: centerFrame - segment.sourceStartFrame)
                ))
            }
        }
        return WaveformOverview(duration: duration, bins: editedBins)
    }

    private func equalDurationWaveformOverview(
        from sourceOverview: WaveformOverview
    ) -> WaveformOverview {
        let sourceBinCount = sourceOverview.bins.count
        let sourceFramesPerBin = Double(sourceFrameCount) / Double(sourceBinCount)
        var editedBins = sourceOverview.bins
        var timelineFrame = 0
        for segment in arrangement.segments {
            let segmentStartFrame = timelineFrame
            let segmentEndFrame = timelineFrame + segment.frameCount
            timelineFrame = segmentEndFrame
            let startBin = min(
                max(Int((Double(segmentStartFrame) / sourceFramesPerBin).rounded(.down)), 0),
                sourceBinCount
            )
            let endBin = min(
                max(Int((Double(segmentEndFrame) / sourceFramesPerBin).rounded(.up)), startBin),
                sourceBinCount
            )
            guard startBin < endBin else {
                continue
            }
            if segment.hasConstantGain {
                guard abs(segment.gainStart - 1) > AudioSegmentArrangement.gainEpsilon else {
                    continue
                }
                for binIndex in startBin..<endBin {
                    editedBins[binIndex] = sourceOverview.bins[binIndex].scaled(
                        by: segment.gainStart
                    )
                }
                continue
            }
            for binIndex in startBin..<endBin {
                let centerFrame = min(
                    max(Int((Double(binIndex) + 0.5) * sourceFramesPerBin), segmentStartFrame),
                    max(segmentEndFrame - 1, segmentStartFrame)
                )
                editedBins[binIndex] = sourceOverview.bins[binIndex].scaled(
                    by: segment.gain(at: centerFrame - segmentStartFrame)
                )
            }
        }
        return WaveformOverview(duration: duration, bins: editedBins)
    }

    mutating func delete(_ selection: TimelineSelection) -> Int {
        arrangement.delete(frameRange: frameRange(for: selection))
    }

    mutating func delete(frameRange: Range<Int>) -> Int {
        arrangement.delete(frameRange: frameRange)
    }

    mutating func deleteClip(id: AudioTimelineClipID) -> Int {
        arrangement.deleteClip(id: id)
    }

    mutating func deleteClips(ids: Set<AudioTimelineClipID>) -> Int {
        arrangement.deleteClips(ids: ids)
    }

    mutating func deleteWithinClip(
        id: AudioTimelineClipID,
        localFrameRange: Range<Int>,
        followingClipPolicy: AudioTimelineFollowingClipPolicy
    ) -> Int {
        arrangement.deleteWithinClip(
            id: id,
            localFrameRange: localFrameRange,
            followingClipPolicy: followingClipPolicy
        )
    }

    mutating func clearWithinClip(
        id: AudioTimelineClipID,
        localFrameRange: Range<Int>
    ) -> Int {
        arrangement.clearWithinClip(id: id, localFrameRange: localFrameRange)
    }

    mutating func duplicateClip(id: AudioTimelineClipID, atFrame frame: Int) -> AudioTimelineClipID? {
        arrangement.duplicateClip(id: id, atFrame: frame)
    }

    mutating func moveClip(id: AudioTimelineClipID, toFrame frame: Int) -> Range<Int>? {
        arrangement.moveClip(id: id, toFrame: frame)
    }

    mutating func relocateClip(id: AudioTimelineClipID, toFrame frame: Int) -> Range<Int>? {
        arrangement.relocateClip(id: id, toFrame: frame)
    }

    mutating func relocateClips(
        ids: Set<AudioTimelineClipID>,
        byFrames delta: Int
    ) -> [AudioTimelineClipID: Range<Int>]? {
        arrangement.relocateClips(ids: ids, byFrames: delta)
    }

    mutating func splitClip(id: AudioTimelineClipID, atLocalFrame frame: Int) -> AudioTimelineClipID? {
        arrangement.splitClip(id: id, atLocalFrame: frame)
    }

    mutating func trimClipStart(id: AudioTimelineClipID, toLocalFrame frame: Int) -> Int {
        arrangement.trimClipStart(id: id, toLocalFrame: frame)
    }

    mutating func trimClipEnd(id: AudioTimelineClipID, toLocalFrame frame: Int) -> Int {
        arrangement.trimClipEnd(id: id, toLocalFrame: frame)
    }

    mutating func clear(_ selection: TimelineSelection) -> Int {
        arrangement.clear(frameRange: frameRange(for: selection))
    }

    mutating func clear(frameRange: Range<Int>) -> Int {
        arrangement.clear(frameRange: frameRange)
    }

    mutating func insertSilence(frameCount: Int, atProgress progress: Double) -> Int {
        arrangement.insertSilence(frameCount: frameCount, atProgress: progress)
    }

    mutating func applyGain(_ gain: Float, to selection: TimelineSelection) -> Int {
        arrangement.applyGain(gain, frameRange: frameRange(for: selection))
    }

    mutating func applyFade(
        _ direction: AudioEditTimeline.FadeDirection,
        to selection: TimelineSelection
    ) -> Int {
        arrangement.applyFade(direction, frameRange: frameRange(for: selection))
    }

    mutating func split(atProgress progress: Double) -> Bool {
        arrangement.split(atProgress: progress)
    }

    mutating func healNearestClipBoundary(atProgress progress: Double) -> Bool {
        arrangement.healNearestClipBoundary(atProgress: progress)
    }

    mutating func slipClip(
        _ clipRange: ClipRange,
        byFrameCount frameDelta: Int
    ) -> Int {
        arrangement.slipClip(clipRange, byFrameCount: frameDelta)
    }

    mutating func trim(to trimRange: TimelineTrimRange) -> Int {
        arrangement.trim(to: trimRange)
    }

    mutating func trimClip(
        _ clipRange: ClipRange,
        edge: ClipEdge,
        toProgress targetProgress: Double
    ) -> Int {
        arrangement.trimClip(
            clipRange,
            edge: edge,
            toProgress: targetProgress
        )
    }

    func frameRange(for selection: TimelineSelection) -> Range<Int> {
        arrangement.frameRange(for: selection)
    }

    private static func segment(
        _ persistent: PersistentSegment,
        clipID: AudioTimelineClipID
    ) -> AudioTimelineSegment {
        AudioTimelineSegment(
            sourceStartFrame: persistent.sourceStartFrame,
            frameCount: persistent.frameCount,
            gainStart: persistent.gainStart,
            gainEnd: persistent.gainEnd,
            startsNewClip: persistent.startsNewClip == true,
            clipID: clipID
        )
    }

    private static func segmentsForInsertion(
        _ persistentSegments: [PersistentSegment]
    ) -> [AudioTimelineSegment] {
        let insertedClipID = AudioTimelineClipID()
        return persistentSegments.enumerated().map { index, persistent in
            AudioTimelineSegment(
                sourceStartFrame: persistent.sourceStartFrame,
                frameCount: persistent.frameCount,
                gainStart: persistent.gainStart,
                gainEnd: persistent.gainEnd,
                startsNewClip: index == 0,
                clipID: insertedClipID
            )
        }
    }

    private static func segments(
        from state: PersistentState
    ) -> [AudioTimelineSegment] {
        var clipOrdinal = 0
        var activeClipID = stableLegacyClipID(state: state, clipOrdinal: clipOrdinal)
        return state.segments.enumerated().map { index, persistent in
            if index > 0, persistent.startsNewClip == true {
                clipOrdinal += 1
                activeClipID = stableLegacyClipID(state: state, clipOrdinal: clipOrdinal)
            }
            if let persistedClipID = persistent.clipID {
                activeClipID = AudioTimelineClipID(rawValue: persistedClipID)
            }
            let clipID = activeClipID
            return segment(persistent, clipID: clipID)
        }
    }

    private static func stableLegacyClipID(
        state: PersistentState,
        clipOrdinal: Int
    ) -> AudioTimelineClipID {
        let seed = "\(state.sourceFrameCount)|\(state.sourceSampleRate.bitPattern)|\(clipOrdinal)"
        let first = stableHash(seed.utf8, offset: 0xcbf29ce484222325)
        let second = stableHash(seed.utf8, offset: 0x84222325cbf29ce4)
        let value = String(format: "%016llx%016llx", first, second)
        let firstPart = String(value.prefix(8))
        let secondPart = String(value.dropFirst(8).prefix(4))
        let thirdPart = String(value.dropFirst(12).prefix(4))
        let fourthPart = String(value.dropFirst(16).prefix(4))
        let fifthPart = String(value.dropFirst(20).prefix(12))
        let uuidString = "\(firstPart)-\(secondPart)-\(thirdPart)-\(fourthPart)-\(fifthPart)"
        return AudioTimelineClipID(rawValue: UUID(uuidString: uuidString) ?? UUID())
    }

    private static func stableHash<C: Collection>(
        _ bytes: C,
        offset: UInt64
    ) -> UInt64 where C.Element == UInt8 {
        bytes.reduce(offset) { value, byte in
            (value ^ UInt64(byte)) &* 0x100000001b3
        }
    }

    private static func persistentSegment(
        _ segment: AudioTimelineSegment
    ) -> PersistentSegment {
        PersistentSegment(
            sourceStartFrame: segment.sourceStartFrame,
            frameCount: segment.frameCount,
            gainStart: segment.gainStart,
            gainEnd: segment.gainEnd,
            startsNewClip: segment.startsNewClip ? true : nil,
            clipID: segment.clipID.rawValue
        )
    }
}
