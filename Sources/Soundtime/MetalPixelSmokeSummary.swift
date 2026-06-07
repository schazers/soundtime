import Foundation

enum MetalPixelSmokeError: Error, CustomStringConvertible {
    case metalDeviceUnavailable
    case commandQueueUnavailable
    case libraryUnavailable
    case pipelineUnavailable
    case textureUnavailable
    case commandBufferUnavailable
    case encoderUnavailable

    var description: String {
        switch self {
        case .metalDeviceUnavailable:
            return "Metal device unavailable"
        case .commandQueueUnavailable:
            return "Metal command queue unavailable"
        case .libraryUnavailable:
            return "Metal shader library unavailable"
        case .pipelineUnavailable:
            return "Metal render pipeline unavailable"
        case .textureUnavailable:
            return "Metal smoke texture unavailable"
        case .commandBufferUnavailable:
            return "Metal command buffer unavailable"
        case .encoderUnavailable:
            return "Metal render encoder unavailable"
        }
    }
}

struct MetalPixelSmokeSummary: Sendable {
    let width: Int
    let height: Int
    let totalPixelCount: Int
    let nonBackgroundPixelCount: Int
    let brightPixelCount: Int
    let cyanPixelCount: Int
    let redPixelCount: Int
    let cyanCentroidX: Double?
    let redCentroidX: Double?
    let brightCentroidX: Double?

    static func analyzeBGRA8(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        backgroundLuminanceThreshold: Int = 34
    ) -> MetalPixelSmokeSummary {
        var nonBackgroundPixelCount = 0
        var brightPixelCount = 0
        var cyanPixelCount = 0
        var redPixelCount = 0
        var cyanXSum = 0.0
        var redXSum = 0.0
        var brightXSum = 0.0

        let pixelCount = min(width * height, bytes.count / 4)
        for index in 0..<pixelCount {
            let byteIndex = index * 4
            let blue = Int(bytes[byteIndex])
            let green = Int(bytes[byteIndex + 1])
            let red = Int(bytes[byteIndex + 2])
            let luminance = (red * 54 + green * 183 + blue * 19) / 256
            let x = Double(index % max(width, 1))

            if luminance > backgroundLuminanceThreshold {
                nonBackgroundPixelCount += 1
            }
            if luminance > 92 {
                brightPixelCount += 1
                brightXSum += x
            }
            if blue > 105, green > 95, red < 92 {
                cyanPixelCount += 1
                cyanXSum += x
            }
            if red > 120, green < 105, blue < 105 {
                redPixelCount += 1
                redXSum += x
            }
        }

        return MetalPixelSmokeSummary(
            width: width,
            height: height,
            totalPixelCount: pixelCount,
            nonBackgroundPixelCount: nonBackgroundPixelCount,
            brightPixelCount: brightPixelCount,
            cyanPixelCount: cyanPixelCount,
            redPixelCount: redPixelCount,
            cyanCentroidX: cyanPixelCount > 0 ? cyanXSum / Double(cyanPixelCount) : nil,
            redCentroidX: redPixelCount > 0 ? redXSum / Double(redPixelCount) : nil,
            brightCentroidX: brightPixelCount > 0 ? brightXSum / Double(brightPixelCount) : nil
        )
    }
}
