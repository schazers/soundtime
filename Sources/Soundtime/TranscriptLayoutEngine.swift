import AppKit

enum TranscriptTimelineDisplayMode: String, Codable, CaseIterable, Sendable {
    case hidden
    case waveformOverlay
    case transcriptLane
    case transcriptOnly
    case review
}

struct TranscriptTimelineLayoutInput: Sendable {
    var tracks: [TimelineRenderState.Track]
    var viewport: TimelineViewport
    var densityViewport: TimelineViewport
    var trackLayout: TimelineTrackLayout
    var timelineDuration: TimeInterval
    var bounds: CGSize
    var displayMode: TranscriptTimelineDisplayMode

    init(
        tracks: [TimelineRenderState.Track],
        viewport: TimelineViewport,
        densityViewport: TimelineViewport? = nil,
        trackLayout: TimelineTrackLayout,
        timelineDuration: TimeInterval,
        bounds: CGSize,
        displayMode: TranscriptTimelineDisplayMode = .waveformOverlay
    ) {
        self.tracks = tracks
        self.viewport = viewport
        self.densityViewport = densityViewport ?? viewport
        self.trackLayout = trackLayout
        self.timelineDuration = timelineDuration
        self.bounds = bounds
        self.displayMode = displayMode
    }
}

struct TranscriptTimelineLayout: Sendable {
    struct Background: Sendable {
        var trackID: UUID
        var rect: CGRect
    }

    struct Run: Sendable {
        var trackID: UUID
        var wordID: UUID?
        var segmentID: UUID
        var sourceRange: TranscriptionTimeRange
        var projectRange: TranscriptionTimeRange
        var rect: CGRect
        var text: String
        var isWord: Bool
        var confidence: Float?
        var speakerID: String?
    }

    var backgrounds: [Background]
    var runs: [Run]
}

struct TranscriptTrackVerticalGeometry: Sendable {
    let bandRect: CGRect
    let wordRunHeight: CGFloat
    let segmentRunHeight: CGFloat

    func runRect(
        x: CGFloat,
        width: CGFloat,
        isWord: Bool
    ) -> CGRect {
        let height = isWord ? wordRunHeight : segmentRunHeight
        return CGRect(
            x: x,
            y: bandRect.midY - height * 0.5,
            width: width,
            height: height
        )
    }
}

enum TranscriptLayoutEngine {
    private static let minimumRetainedWordCoverage = 0.5

    // These limits bound the prefetched cache, not just the pixels currently
    // visible. They are intentionally large enough for several screens of
    // spoken audio so a normal pan does not synchronously rebuild text.
    static let maximumVisibleWordRuns = 512
    static let maximumVisibleSegmentRuns = 160

    static func usesWordRuns(
        viewport: TimelineViewport,
        timelineDuration: TimeInterval,
        boundsWidth: CGFloat
    ) -> Bool {
        let visibleRange = visibleProjectRange(
            viewport: viewport,
            timelineDuration: timelineDuration
        )
        let secondsPerPixel = visibleRange.duration / max(TimeInterval(boundsWidth), 1)
        return secondsPerPixel < 0.035
    }

    static func makeLayout(_ input: TranscriptTimelineLayoutInput) -> TranscriptTimelineLayout {
        guard
            input.displayMode != .hidden,
            input.timelineDuration > 0,
            input.bounds.width > 1,
            input.bounds.height > 1
        else {
            return TranscriptTimelineLayout(backgrounds: [], runs: [])
        }

        let resolvedLayout = input.trackLayout.resolved(
            totalTrackCount: input.tracks.count,
            viewportHeight: Float(max(input.bounds.height, 1))
        )
        let visibleTrackRange = resolvedLayout.visibleRange(overscan: 0)
        guard !visibleTrackRange.isEmpty else {
            return TranscriptTimelineLayout(backgrounds: [], runs: [])
        }

        var backgrounds: [TranscriptTimelineLayout.Background] = []
        var runs: [TranscriptTimelineLayout.Run] = []
        backgrounds.reserveCapacity(visibleTrackRange.count)
        runs.reserveCapacity(64)

        let visibleOutputRange = visibleProjectRange(
            viewport: input.viewport,
            timelineDuration: input.timelineDuration
        )
        let useWordRuns = usesWordRuns(
            viewport: input.densityViewport,
            timelineDuration: input.timelineDuration,
            boundsWidth: input.bounds.width
        )

        for trackIndex in visibleTrackRange where input.tracks.indices.contains(trackIndex) {
            let track = input.tracks[trackIndex]
            guard let transcript = track.transcript, !transcript.isEmpty else {
                continue
            }
            guard let laneFrame = resolvedLayout.laneFrame(forTrackIndex: trackIndex) else {
                continue
            }

            guard let verticalGeometry = verticalGeometry(
                for: laneFrame,
                bounds: input.bounds
            ) else {
                continue
            }
            backgrounds.append(TranscriptTimelineLayout.Background(
                trackID: track.id,
                rect: verticalGeometry.bandRect
            ))

            let timeMap = transcript.sourceTimeMap ?? TranscriptSourceTimeMap.fromRenderTrack(track)
            if useWordRuns {
                let wordRuns = makeWordRuns(
                    transcript: transcript,
                    track: track,
                    timeMap: timeMap,
                    visibleOutputRange: visibleOutputRange,
                    verticalGeometry: verticalGeometry,
                    bounds: input.bounds,
                    viewport: input.viewport,
                    timelineDuration: input.timelineDuration
                )
                if !wordRuns.isEmpty, wordRuns.count <= maximumVisibleWordRuns {
                    runs.append(contentsOf: wordRuns)
                    continue
                }
            }

            runs.append(contentsOf: makeSegmentRuns(
                transcript: transcript,
                track: track,
                timeMap: timeMap,
                visibleOutputRange: visibleOutputRange,
                verticalGeometry: verticalGeometry,
                bounds: input.bounds,
                viewport: input.viewport,
                timelineDuration: input.timelineDuration
            ))
        }

        return TranscriptTimelineLayout(backgrounds: backgrounds, runs: runs)
    }

    static func visibleProjectRange(
        viewport: TimelineViewport,
        timelineDuration: TimeInterval
    ) -> TranscriptionTimeRange {
        TranscriptionTimeRange(
            startTime: TimeInterval(viewport.startProgress) * timelineDuration,
            endTime: TimeInterval(viewport.endProgress) * timelineDuration
        )
    }

    private static func makeWordRuns(
        transcript: TranscriptDocument,
        track: TimelineRenderState.Track,
        timeMap: TranscriptSourceTimeMap,
        visibleOutputRange: TranscriptionTimeRange,
        verticalGeometry: TranscriptTrackVerticalGeometry,
        bounds: CGSize,
        viewport: TimelineViewport,
        timelineDuration: TimeInterval
    ) -> [TranscriptTimelineLayout.Run] {
        let candidateSourceRange = timeMap.sourceRangeCoveringProjectRange(
            visibleOutputRange.startTime..<visibleOutputRange.endTime
        ) ?? visibleOutputRange.startTime..<visibleOutputRange.endTime
        var output: [TranscriptTimelineLayout.Run] = []
        output.reserveCapacity(min(maximumVisibleWordRuns, 48))

        var segmentIndex = firstSegmentIndex(overlapping: candidateSourceRange, in: transcript)
        while segmentIndex < transcript.segments.count {
            let segment = transcript.segments[segmentIndex]
            segmentIndex += 1
            if segment.endTime < candidateSourceRange.lowerBound {
                continue
            }
            if segment.startTime > candidateSourceRange.upperBound {
                break
            }

            for word in segment.words {
                guard word.endTime >= candidateSourceRange.lowerBound,
                      word.startTime <= candidateSourceRange.upperBound
                else {
                    continue
                }

                let wordSourceRange = word.startTime..<max(
                    word.endTime,
                    word.startTime + 0.05
                )
                for projection in timeMap.projections(forSourceRange: wordSourceRange) {
                    guard retainedCoverage(
                        of: wordSourceRange,
                        in: projection.sourceRange
                    ) >= minimumRetainedWordCoverage else {
                        continue
                    }
                    let outputRange = projection.outputRange
                    guard outputRange.upperBound >= visibleOutputRange.startTime,
                          outputRange.lowerBound <= visibleOutputRange.endTime
                    else {
                        continue
                    }

                    let x0 = xPosition(
                        forProjectTime: outputRange.lowerBound,
                        viewport: viewport,
                        timelineDuration: timelineDuration,
                        boundsWidth: bounds.width
                    )
                    let x1 = xPosition(
                        forProjectTime: max(outputRange.upperBound, outputRange.lowerBound + 0.05),
                        viewport: viewport,
                        timelineDuration: timelineDuration,
                        boundsWidth: bounds.width
                    )
                    let rect = verticalGeometry.runRect(
                        x: x0,
                        width: max(x1 - x0, 18),
                        isWord: true
                    )
                    guard rect.maxX >= 0, rect.minX <= bounds.width else {
                        continue
                    }
                    output.append(TranscriptTimelineLayout.Run(
                        trackID: track.id,
                        wordID: word.id,
                        segmentID: segment.id,
                        sourceRange: TranscriptionTimeRange(startTime: word.startTime, endTime: word.endTime),
                        projectRange: TranscriptionTimeRange(startTime: outputRange.lowerBound, endTime: outputRange.upperBound),
                        rect: rect,
                        text: word.text,
                        isWord: true,
                        confidence: word.confidence,
                        speakerID: word.speakerID
                    ))
                    if output.count > maximumVisibleWordRuns {
                        return output
                    }
                }
            }
        }

        return output
    }

    private static func makeSegmentRuns(
        transcript: TranscriptDocument,
        track: TimelineRenderState.Track,
        timeMap: TranscriptSourceTimeMap,
        visibleOutputRange: TranscriptionTimeRange,
        verticalGeometry: TranscriptTrackVerticalGeometry,
        bounds: CGSize,
        viewport: TimelineViewport,
        timelineDuration: TimeInterval
    ) -> [TranscriptTimelineLayout.Run] {
        let candidateSourceRange = timeMap.sourceRangeCoveringProjectRange(
            visibleOutputRange.startTime..<visibleOutputRange.endTime
        ) ?? visibleOutputRange.startTime..<visibleOutputRange.endTime
        var output: [TranscriptTimelineLayout.Run] = []
        output.reserveCapacity(min(maximumVisibleSegmentRuns, 32))

        var segmentIndex = firstSegmentIndex(overlapping: candidateSourceRange, in: transcript)
        while segmentIndex < transcript.segments.count {
            let segment = transcript.segments[segmentIndex]
            segmentIndex += 1
            if segment.endTime < candidateSourceRange.lowerBound {
                continue
            }
            if segment.startTime > candidateSourceRange.upperBound {
                break
            }

            let segmentSourceRange = segment.startTime..<max(
                segment.endTime,
                segment.startTime + 0.2
            )
            for projection in timeMap.projections(forSourceRange: segmentSourceRange) {
                let outputRange = projection.outputRange
                guard outputRange.upperBound >= visibleOutputRange.startTime,
                      outputRange.lowerBound <= visibleOutputRange.endTime
                else {
                    continue
                }
                let projectedText = segmentText(
                    segment,
                    retainedIn: projection.sourceRange
                )
                guard !projectedText.isEmpty else {
                    continue
                }

                let x0 = xPosition(
                    forProjectTime: outputRange.lowerBound,
                    viewport: viewport,
                    timelineDuration: timelineDuration,
                    boundsWidth: bounds.width
                )
                let x1 = xPosition(
                    forProjectTime: max(outputRange.upperBound, outputRange.lowerBound + 0.2),
                    viewport: viewport,
                    timelineDuration: timelineDuration,
                    boundsWidth: bounds.width
                )
                let rect = verticalGeometry.runRect(
                    x: x0,
                    width: max(x1 - x0, 36),
                    isWord: false
                )
                guard rect.maxX >= 0, rect.minX <= bounds.width else {
                    continue
                }
                output.append(TranscriptTimelineLayout.Run(
                    trackID: track.id,
                    wordID: nil,
                    segmentID: segment.id,
                    sourceRange: TranscriptionTimeRange(startTime: segment.startTime, endTime: segment.endTime),
                    projectRange: TranscriptionTimeRange(startTime: outputRange.lowerBound, endTime: outputRange.upperBound),
                    rect: rect,
                    text: projectedText,
                    isWord: false,
                    confidence: segment.confidence,
                    speakerID: segment.speakerID
                ))
                if output.count >= maximumVisibleSegmentRuns {
                    return output
                }
            }
        }

        return output
    }

    private static func segmentText(
        _ segment: TranscriptSegment,
        retainedIn sourceRange: Range<TimeInterval>
    ) -> String {
        guard !segment.words.isEmpty else {
            let segmentRange = segment.startTime..<max(
                segment.endTime,
                segment.startTime + 0.2
            )
            return retainedCoverage(of: segmentRange, in: sourceRange) >=
                minimumRetainedWordCoverage ? segment.text : ""
        }

        return segment.words.compactMap { word in
            let wordRange = word.startTime..<max(
                word.endTime,
                word.startTime + 0.05
            )
            return retainedCoverage(of: wordRange, in: sourceRange) >=
                minimumRetainedWordCoverage ? word.text : nil
        }
        .joined(separator: " ")
    }

    private static func retainedCoverage(
        of range: Range<TimeInterval>,
        in retainedRange: Range<TimeInterval>
    ) -> Double {
        let overlap = max(
            min(range.upperBound, retainedRange.upperBound) -
                max(range.lowerBound, retainedRange.lowerBound),
            0
        )
        return overlap / max(range.upperBound - range.lowerBound, 0.000_001)
    }

    static func verticalGeometry(
        for laneFrame: TimelineTrackLaneFrame,
        bounds: CGSize
    ) -> TranscriptTrackVerticalGeometry? {
        let laneRect = rect(for: laneFrame, bounds: bounds)
        guard laneRect.height > 20 else {
            return nil
        }

        let bandRect = transcriptBandRect(in: laneRect)
        return TranscriptTrackVerticalGeometry(
            bandRect: bandRect,
            wordRunHeight: transcriptRunHeight(
                preferredHeight: min(max(laneRect.height * 0.20, 22), 28),
                bandRect: bandRect
            ),
            segmentRunHeight: transcriptRunHeight(
                preferredHeight: min(max(laneRect.height * 0.22, 24), 30),
                bandRect: bandRect
            )
        )
    }

    private static func transcriptBandRect(in laneRect: CGRect) -> CGRect {
        let availableHeight = max(laneRect.height - 16, 1)
        let textBandHeight = min(min(max(laneRect.height * 0.32, 34), 54), availableHeight)
        return CGRect(
            x: laneRect.minX + 8,
            y: laneRect.minY + 8,
            width: max(laneRect.width - 16, 1),
            height: textBandHeight
        )
    }

    private static func transcriptRunHeight(
        preferredHeight: CGFloat,
        bandRect: CGRect
    ) -> CGFloat {
        min(preferredHeight, max(bandRect.height - 12, 1))
    }

    private static func rect(for laneFrame: TimelineTrackLaneFrame, bounds: CGSize) -> CGRect {
        let top = CGFloat(laneFrame.clampedTop) * bounds.height
        let bottom = CGFloat(laneFrame.clampedBottom) * bounds.height
        return CGRect(
            x: 0,
            y: top,
            width: bounds.width,
            height: max(bottom - top, 0)
        )
    }

    private static func xPosition(
        forProjectTime time: TimeInterval,
        viewport: TimelineViewport,
        timelineDuration: TimeInterval,
        boundsWidth: CGFloat
    ) -> CGFloat {
        guard timelineDuration > 0 else {
            return 0
        }

        let timelineProgress = Float(min(max(time / timelineDuration, 0), 1))
        let viewportProgress = viewport.viewportProgress(forTimelineProgress: timelineProgress)
        return CGFloat(viewportProgress) * boundsWidth
    }

    private static func firstSegmentIndex(
        overlapping range: Range<TimeInterval>,
        in transcript: TranscriptDocument
    ) -> Int {
        guard !range.isEmpty else {
            return transcript.segments.count
        }

        var low = 0
        var high = transcript.segments.count
        while low < high {
            let middle = (low + high) / 2
            if transcript.segments[middle].endTime < range.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
