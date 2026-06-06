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

enum AgentResolvedCommand: Sendable, Equatable {
    case play
    case pause
    case togglePlayback
    case deleteSelection
    case cutSelection
    case copySelection
    case pasteAudio
    case showGain
    case normalizeSelection
    case fadeInSelection
    case fadeOutSelection
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
                summary: "Open or apply gain to the active selection without blocking playback or rendering."
            )
        )
        register(
            AgentCommandCapability(
                identifier: "timeline.fadeIn",
                title: "Fade In Selection",
                summary: "Apply a fade-in to the active audio selection."
            )
        )
        register(
            AgentCommandCapability(
                identifier: "timeline.fadeOut",
                title: "Fade Out Selection",
                summary: "Apply a fade-out to the active audio selection."
            )
        )
        register(
            AgentCommandCapability(
                identifier: "timeline.copyPaste",
                title: "Copy, Cut, Paste",
                summary: "Use the current selection and edit insertion point for clipboard edits."
            )
        )
        register(
            AgentCommandCapability(
                identifier: "timeline.normalize",
                title: "Normalize Selection",
                summary: "Normalize the active selection through the edit graph without blocking playback or rendering."
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
    var onCommandRequested: ((AgentResolvedCommand) -> AgentCommandResult)?
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
        let resolvedCommand = Self.resolveCommand(prompt)

        activeTask = Task { [weak self] in
            guard let self else {
                return
            }

            state = .thinking
            try? await Task.sleep(nanoseconds: resolvedCommand == nil ? 220_000_000 : 90_000_000)
            guard Task.isCancelled == false else {
                return
            }

            state = .acting
            if let resolvedCommand {
                let result = onCommandRequested?(resolvedCommand) ??
                    AgentCommandResult(
                        status: .failed,
                        message: "Agent command unavailable"
                    )
                onResult?(result)
                state = .idle
                return
            }

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

    private static func resolveCommand(_ prompt: String) -> AgentResolvedCommand? {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized == "play" || normalized == "start playback" {
            return .play
        }
        if normalized == "pause" || normalized == "stop playback" {
            return .pause
        }
        if normalized == "toggle playback" || normalized == "play pause" {
            return .togglePlayback
        }
        if normalized.contains("delete") || normalized == "remove selection" {
            return .deleteSelection
        }
        if normalized == "cut" || normalized.contains("cut selection") {
            return .cutSelection
        }
        if normalized == "copy" || normalized.contains("copy selection") {
            return .copySelection
        }
        if normalized == "paste" || normalized.contains("paste audio") {
            return .pasteAudio
        }
        if normalized.contains("normalize") {
            return .normalizeSelection
        }
        if normalized.contains("fade in") {
            return .fadeInSelection
        }
        if normalized.contains("fade out") {
            return .fadeOutSelection
        }
        if normalized == "gain" ||
            normalized == "open gain" ||
            normalized.contains("show gain") ||
            normalized.contains("adjust gain")
        {
            return .showGain
        }

        return nil
    }
}
