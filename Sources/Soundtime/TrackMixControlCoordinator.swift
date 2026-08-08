import Foundation

@MainActor
final class TrackMixControlCoordinator {
    struct Handlers {
        var setMute: (UUID, Bool) -> Void
        var setSolo: (UUID, Bool) -> Void
        var beginVolume: (UUID, Float) -> Void
        var changeVolume: (UUID, Float) -> Void
        var endVolume: (UUID) -> Void
        var beginPan: (UUID, Float) -> Void
        var changePan: (UUID, Float) -> Void
        var endPan: (UUID) -> Void
    }

    private let handlers: Handlers

    init(handlers: Handlers) {
        self.handlers = handlers
    }

    func setMute(trackID: UUID, value: Bool) { handlers.setMute(trackID, value) }
    func setSolo(trackID: UUID, value: Bool) { handlers.setSolo(trackID, value) }
    func beginVolume(trackID: UUID, value: Float) { handlers.beginVolume(trackID, value) }
    func changeVolume(trackID: UUID, value: Float) { handlers.changeVolume(trackID, value) }
    func endVolume(trackID: UUID) { handlers.endVolume(trackID) }
    func beginPan(trackID: UUID, value: Float) { handlers.beginPan(trackID, value) }
    func changePan(trackID: UUID, value: Float) { handlers.changePan(trackID, value) }
    func endPan(trackID: UUID) { handlers.endPan(trackID) }
}
