public enum DeferredEditStatePublicationPolicy {
    public static func mayReplaceCurrentState<Revision: Equatable>(
        capturedRevision: Revision,
        currentRevision: Revision
    ) -> Bool {
        capturedRevision == currentRevision
    }
}
