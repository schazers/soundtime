import Foundation

public enum TimelineClipUserCommand: String, CaseIterable, Sendable {
    case openInspector
    case rename
    case duplicate
    case delete
    case nudge
    case slip
    case mute
    case lock
    case group
    case ungroup
    case repeatClips
    case crossfade
    case selectPreviousOrNext
    case selectAllOnTrack
    case selectFollowing
    case selectInTimeRange
    case moveToTrackAbove
    case moveToTrackBelow
    case relinkMissingMedia
    case cancelMediaRelink
}

/// A value-only snapshot used by menus, keyboard commands, and accessibility
/// actions. It deliberately contains no view state, so command availability can
/// be tested without constructing AppKit or the Metal renderer.
public struct TimelineClipCommandContext: Equatable, Sendable {
    public var selectedClipCount: Int
    public var totalClipCount: Int
    public var hasTimeSelection: Bool
    public var hasActiveTrack: Bool
    public var hasFocusedInspector: Bool
    public var hasMissingMedia: Bool
    public var isRelinkingMedia: Bool
    public var canMoveSelectionToTrackAbove: Bool
    public var canMoveSelectionToTrackBelow: Bool

    public init(
        selectedClipCount: Int = 0,
        totalClipCount: Int = 0,
        hasTimeSelection: Bool = false,
        hasActiveTrack: Bool = false,
        hasFocusedInspector: Bool = false,
        hasMissingMedia: Bool = false,
        isRelinkingMedia: Bool = false,
        canMoveSelectionToTrackAbove: Bool = false,
        canMoveSelectionToTrackBelow: Bool = false
    ) {
        self.selectedClipCount = max(selectedClipCount, 0)
        self.totalClipCount = max(totalClipCount, 0)
        self.hasTimeSelection = hasTimeSelection
        self.hasActiveTrack = hasActiveTrack
        self.hasFocusedInspector = hasFocusedInspector
        self.hasMissingMedia = hasMissingMedia
        self.isRelinkingMedia = isRelinkingMedia
        self.canMoveSelectionToTrackAbove = canMoveSelectionToTrackAbove
        self.canMoveSelectionToTrackBelow = canMoveSelectionToTrackBelow
    }

    public func isEnabled(_ command: TimelineClipUserCommand) -> Bool {
        let hasSelection = selectedClipCount > 0
        switch command {
        case .openInspector, .rename:
            return selectedClipCount == 1
        case .duplicate, .delete, .nudge, .slip, .mute, .lock,
             .group, .ungroup, .repeatClips, .selectFollowing:
            return hasSelection
        case .crossfade:
            return selectedClipCount == 2
        case .selectPreviousOrNext:
            return totalClipCount > 0
        case .selectAllOnTrack:
            return hasActiveTrack && totalClipCount > 0
        case .selectInTimeRange:
            return hasTimeSelection && totalClipCount > 0
        case .moveToTrackAbove:
            return hasSelection && canMoveSelectionToTrackAbove
        case .moveToTrackBelow:
            return hasSelection && canMoveSelectionToTrackBelow
        case .relinkMissingMedia:
            return hasMissingMedia && !isRelinkingMedia
        case .cancelMediaRelink:
            return isRelinkingMedia
        }
    }
}
