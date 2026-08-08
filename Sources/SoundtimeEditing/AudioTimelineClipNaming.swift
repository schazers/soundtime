public struct AudioTimelineClipSplitNames: Equatable, Sendable {
    public let left: String
    public let right: String

    public init(left: String, right: String) {
        self.left = left
        self.right = right
    }

    public static func derived(from displayedName: String) -> Self {
        let name = displayedName.isEmpty ? "Clip" : displayedName
        let utf8 = Array(name.utf8)
        var suffixStart = utf8.endIndex

        while suffixStart > utf8.startIndex {
            let byte = utf8[utf8.index(before: suffixStart)]
            guard byte >= Character("0").asciiValue!, byte <= Character("9").asciiValue! else {
                break
            }
            suffixStart = utf8.index(before: suffixStart)
        }

        guard suffixStart < utf8.endIndex else {
            return Self(left: "\(name) 1", right: "\(name) 2")
        }

        let prefix = String(decoding: utf8[..<suffixStart], as: UTF8.self)
        let suffix = Array(utf8[suffixStart...])
        return Self(
            left: name,
            right: prefix + incrementDecimalDigits(suffix)
        )
    }

    private static func incrementDecimalDigits(_ digits: [UInt8]) -> String {
        var result = digits
        var index = result.endIndex
        var carry = true

        while index > result.startIndex, carry {
            index = result.index(before: index)
            if result[index] == Character("9").asciiValue! {
                result[index] = Character("0").asciiValue!
            } else {
                result[index] += 1
                carry = false
            }
        }
        if carry {
            result.insert(Character("1").asciiValue!, at: result.startIndex)
        }
        return String(decoding: result, as: UTF8.self)
    }
}
