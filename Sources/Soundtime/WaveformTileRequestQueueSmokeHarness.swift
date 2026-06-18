import Foundation

enum WaveformTileRequestQueueSmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds

        try verifyVisibleRequestsWinDequeuePriority()
        try verifyPendingPriorityUpgrade()
        try verifyInFlightDuplicateSuppression()
        try verifySourceCancellationInvalidatesWork()
        try verifyFailureAndRequeueState()
        try verifySchedulerRequestsDequeueInBoundedBatches()

        let checks = [
            "visible request dequeue priority",
            "pending priority upgrade",
            "in-flight duplicate suppression",
            "source cancellation invalidates stale work",
            "failure and requeue state",
            "scheduler request bounded batches",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-tile-request-queue-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform tile request queue smoke passed")
    }

    private static func verifyVisibleRequestsWinDequeuePriority() throws {
        let queue = WaveformTileRequestQueue()
        let background = request(tileIndex: 20, purpose: .background)
        let visible = request(tileIndex: 10, purpose: .visible)

        queue.enqueue(background)
        queue.enqueue(visible)

        let batch = queue.dequeue(maxCount: 1)
        try require(batch.count == 1, "expected one dequeued work item")
        try require(batch[0].request == visible, "visible request did not dequeue before background request")
        try require(queue.snapshot().pendingCount == 1, "batch limit did not leave one request pending")
    }

    private static func verifyPendingPriorityUpgrade() throws {
        let queue = WaveformTileRequestQueue()
        let background = request(tileIndex: 5, purpose: .background)
        let visible = request(tileIndex: 5, purpose: .visible)

        queue.enqueue(background)
        queue.enqueue(visible)

        try require(queue.snapshot().pendingCount == 1, "priority upgrade should dedupe by tile address")
        let batch = queue.dequeue(maxCount: 1)
        try require(batch.first?.request.purpose == .visible, "higher-priority request did not replace pending lower-priority request")
    }

    private static func verifyInFlightDuplicateSuppression() throws {
        let queue = WaveformTileRequestQueue()
        let visible = request(tileIndex: 7, purpose: .visible)

        queue.enqueue(visible)
        let workItem = try requireFirst(queue.dequeue(maxCount: 1), "expected work item")
        queue.enqueue(request(tileIndex: 7, purpose: .background))

        try require(queue.snapshot().pendingCount == 0, "duplicate in-flight tile should not be requeued")
        try require(queue.isInFlight(visible.descriptor.address), "tile should still be marked in-flight")
        try require(queue.complete(workItem), "current in-flight work did not complete")
        try require(queue.snapshot().isEmpty, "completed queue should be empty")
    }

    private static func verifySourceCancellationInvalidatesWork() throws {
        let queue = WaveformTileRequestQueue()
        let sourceA = WaveformSourceID(rawValue: "queue-source-a")
        let sourceB = WaveformSourceID(rawValue: "queue-source-b")
        let sourceARequest = request(sourceID: sourceA, tileIndex: 1, purpose: .visible)
        let sourceBRequest = request(sourceID: sourceB, tileIndex: 1, purpose: .visible)

        queue.enqueue([sourceARequest, sourceBRequest])
        let firstBatch = queue.dequeue(maxCount: 1)
        let sourceAWork = try requireFirst(firstBatch, "expected source A work item")
        try require(sourceAWork.request.descriptor.address.sourceID == sourceA, "expected source A to dequeue first")

        queue.removeAll(for: sourceA)
        try require(!queue.complete(sourceAWork), "stale work should not be accepted after source cancellation")
        try require(!queue.isInFlight(sourceARequest.descriptor.address), "cancelled source should not remain in-flight")

        let secondBatch = queue.dequeue(maxCount: 1)
        try require(secondBatch.first?.request.descriptor.address.sourceID == sourceB, "other sources should remain queued")
    }

    private static func verifyFailureAndRequeueState() throws {
        let queue = WaveformTileRequestQueue()
        let visible = request(tileIndex: 12, purpose: .visible)

        queue.enqueue(visible)
        let failedWork = try requireFirst(queue.dequeue(maxCount: 1), "expected work item")
        try require(queue.fail(failedWork, message: "synthetic failure"), "current work failure was not accepted")
        try require(
            queue.failureMessage(for: visible.descriptor.address) == "synthetic failure",
            "failure message was not stored"
        )

        queue.enqueue(visible)
        try require(queue.failureMessage(for: visible.descriptor.address) == nil, "new enqueue should clear stale failure")
        let requeuedWork = try requireFirst(queue.dequeue(maxCount: 1), "expected requeued work item")
        queue.requeue(requeuedWork)
        try require(queue.snapshot().pendingCount == 1, "requeued current work should return to pending")
    }

    private static func verifySchedulerRequestsDequeueInBoundedBatches() throws {
        let queue = WaveformTileRequestQueue()
        let source = WaveformTileSourceMetadata(
            sourceID: WaveformSourceID(rawValue: "scheduler-queue-source"),
            duration: 120,
            frameCount: 5_760_000,
            sampleRate: 48_000,
            channelMode: .monoMix
        )
        let requests = WaveformTileScheduler.requests(
            for: source,
            viewport: WaveformTileSchedulerViewport(startTime: 10, endTime: 10.5, widthPixels: 1_000),
            predictedViewport: WaveformTileSchedulerViewport(startTime: 15, endTime: 15.5, widthPixels: 1_000),
            config: WaveformTileSchedulerConfig(
                peakFramesPerTile: 4_800,
                backgroundTileStride: 100,
                maximumBackgroundRequests: 8
            )
        )

        queue.enqueue(requests)
        let firstBatch = queue.dequeue(maxCount: 3)
        try require(firstBatch.count == 3, "bounded dequeue did not return requested batch size")
        try require(
            firstBatch.allSatisfy { $0.request.purpose == .visible },
            "scheduler-fed queue should emit visible work before prefetch/background work"
        )
        try require(queue.snapshot().pendingCount == requests.count - 3, "bounded dequeue removed unexpected request count")
    }

    private static func request(
        sourceID: WaveformSourceID = WaveformSourceID(rawValue: "queue-source"),
        tileIndex: Int,
        purpose: WaveformTileRequestPurpose
    ) -> WaveformTileRequest {
        let descriptor = WaveformTileDescriptor(
            address: WaveformTileAddress(
                sourceID: sourceID,
                kind: .peak,
                channelMode: .monoMix,
                level: 5,
                tileIndex: tileIndex
            ),
            frameRange: WaveformFrameRange(
                startFrame: Int64(tileIndex) * 4_800,
                endFrame: Int64(tileIndex + 1) * 4_800
            ),
            framesPerBin: 32,
            expectedBinCount: 150
        )
        return WaveformTileRequest(
            descriptor: descriptor,
            purpose: purpose,
            distanceFromVisibleTiles: purpose == .visible ? 0 : 10,
            samplesPerPixel: 24
        )
    }

    private static func requireFirst(
        _ items: [WaveformTileWorkItem],
        _ message: String
    ) throws -> WaveformTileWorkItem {
        guard let first = items.first else {
            throw SmokeError.failed(message)
        }
        return first
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SmokeError.failed(message)
        }
    }
}
