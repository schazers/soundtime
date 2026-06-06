import Foundation

struct AgentCommandCapability: Sendable {
    let identifier: String
    let title: String
    let summary: String
}

struct AgentCommandRequest: Sendable, Identifiable {
    let id: UUID
    let prompt: String
    let submittedAt: Date
    let availableCapabilities: [AgentCommandCapability]
}

struct AgentCommandResult: Sendable {
    enum Status: Sendable {
        case accepted
        case failed
    }

    let status: Status
    let message: String
}

@MainActor
final class AgentCommandRegistry {
    private(set) var capabilities: [AgentCommandCapability] = []

    init() {
        registerDefaultCapabilities()
    }

    func register(_ capability: AgentCommandCapability) {
        guard capabilities.contains(where: { $0.identifier == capability.identifier }) == false else {
            return
        }

        capabilities.append(capability)
    }

    private func registerDefaultCapabilities() {
        register(
            AgentCommandCapability(
                identifier: "timeline.selectRegion",
                title: "Select Region",
                summary: "Select a precise time range on a specific track."
            )
        )
        register(
            AgentCommandCapability(
                identifier: "timeline.deleteSelection",
                title: "Delete Selection",
                summary: "Delete the currently selected audio region using the app's edit graph."
            )
        )
        register(
            AgentCommandCapability(
                identifier: "timeline.applyGain",
                title: "Apply Gain",
                summary: "Apply gain to the active selection without blocking playback or rendering."
            )
        )
        register(
            AgentCommandCapability(
                identifier: "timeline.zoomToRegion",
                title: "Zoom To Region",
                summary: "Move the viewport to a track/time range so the user can inspect it."
            )
        )
        register(
            AgentCommandCapability(
                identifier: "transport.playback",
                title: "Control Playback",
                summary: "Play, pause, or seek through typed transport commands."
            )
        )
    }
}

@MainActor
final class AgentCommandController {
    enum PresentationState: Equatable {
        case idle
        case thinking
        case acting
    }

    let registry = AgentCommandRegistry()

    var onStateChanged: ((PresentationState) -> Void)?
    var onRequestSubmitted: ((AgentCommandRequest) -> Void)?
    var onResult: ((AgentCommandResult) -> Void)?

    private var state: PresentationState = .idle {
        didSet {
            guard oldValue != state else {
                return
            }

            onStateChanged?(state)
        }
    }

    private var activeTask: Task<Void, Never>?

    deinit {
        activeTask?.cancel()
    }

    func submit(prompt rawPrompt: String) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false else {
            return
        }

        activeTask?.cancel()
        let request = AgentCommandRequest(
            id: UUID(),
            prompt: prompt,
            submittedAt: Date(),
            availableCapabilities: registry.capabilities
        )
        onRequestSubmitted?(request)

        activeTask = Task { [weak self] in
            guard let self else {
                return
            }

            state = .thinking
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard Task.isCancelled == false else {
                return
            }

            state = .acting
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard Task.isCancelled == false else {
                return
            }

            onResult?(
                AgentCommandResult(
                    status: .accepted,
                    message: "Agent request queued"
                )
            )
            state = .idle
        }
    }
}
