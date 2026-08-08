import Foundation
import SoundtimeEditing

enum TimelineLaneIdentity {
    static func uuid(for laneID: TimelinePlaybackLaneID) -> UUID {
        let value = "\(laneID.trackID.uuidString.lowercased())|\(laneID.sourceID.rawValue)"
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 1_099_511_628_211
        for byte in value.utf8 {
            first = (first ^ UInt64(byte)) &* 1_099_511_628_211
            second = (second &* 1_099_511_628_211) ^ UInt64(byte)
        }
        let bytes = withUnsafeBytes(of: (first.bigEndian, second.bigEndian)) { Array($0) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
