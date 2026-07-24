import Foundation

enum TranscriptValidityPolicy {
    static func reconciledTranscript(
        _ transcript: TranscriptDocument,
        currentSourceRevision: Int,
        currentSourceFingerprint: String?,
        timeMap: TranscriptSourceTimeMap?
    ) -> TranscriptDocument {
        if transcript.sourceRevision == currentSourceRevision {
            var current = transcript
            current.sourceFingerprint = current.sourceFingerprint ?? currentSourceFingerprint
            current.validity = current.validity ?? .valid
            if current.sourceTimeMap == nil {
                current.sourceTimeMap = timeMap
            }
            return current
        }

        guard let timeMap else {
            var stale = transcript
            stale.validity = .stale
            return stale
        }

        var remapped = timeMap.remappedDocument(transcript, sourceRevision: currentSourceRevision)
        remapped.sourceFingerprint = currentSourceFingerprint ?? transcript.sourceFingerprint
        remapped.storageReference = transcript.storageReference
        return remapped
    }
}
