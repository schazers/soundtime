import Foundation

enum EditGroupModel {
    static func primaryGroupID(
        from groupIDs: [UUID?],
        fallback: UUID
    ) -> UUID {
        var counts: [UUID: Int] = [:]
        var firstSeenOrder: [UUID] = []

        for optionalGroupID in groupIDs {
            let groupID = optionalGroupID ?? fallback
            if counts[groupID] == nil {
                firstSeenOrder.append(groupID)
            }
            counts[groupID, default: 0] += 1
        }

        return firstSeenOrder.max { lhs, rhs in
            let lhsCount = counts[lhs] ?? 0
            let rhsCount = counts[rhs] ?? 0
            if lhsCount == rhsCount {
                let lhsIndex = firstSeenOrder.firstIndex(of: lhs) ?? Int.max
                let rhsIndex = firstSeenOrder.firstIndex(of: rhs) ?? Int.max
                return lhsIndex > rhsIndex
            }
            return lhsCount < rhsCount
        } ?? fallback
    }

    static func normalizedGroupIDs(
        from groupIDs: [UUID?],
        fallback: UUID
    ) -> [UUID] {
        let primaryGroupID = primaryGroupID(from: groupIDs, fallback: fallback)
        return Array(repeating: primaryGroupID, count: groupIDs.count)
    }

    static func needsNormalization(
        _ groupIDs: [UUID?],
        fallback: UUID
    ) -> Bool {
        guard !groupIDs.isEmpty else {
            return false
        }

        let primaryGroupID = primaryGroupID(from: groupIDs, fallback: fallback)
        return groupIDs.contains { ($0 ?? fallback) != primaryGroupID }
    }
}
