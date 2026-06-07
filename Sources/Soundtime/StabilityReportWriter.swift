import Foundation

struct StabilityCheckReport: Codable, Sendable {
    let name: String
    let status: String
    let detail: String?
}

struct StabilitySuiteReport: Codable, Sendable {
    let suiteName: String
    let status: String
    let generatedAt: Date
    let durationMilliseconds: Double
    let checks: [StabilityCheckReport]
    let metadata: [String: String]
}

enum StabilityReportWriter {
    @discardableResult
    static func writePassedSuite(
        name: String,
        startedAtNanoseconds: UInt64,
        checks: [String],
        metadata: [String: String] = [:],
        arguments: [String]
    ) -> URL? {
        guard let directory = reportDirectory(arguments: arguments) else {
            return nil
        }

        let endedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let report = StabilitySuiteReport(
            suiteName: name,
            status: "passed",
            generatedAt: Date(),
            durationMilliseconds: Double(endedAtNanoseconds - startedAtNanoseconds) / 1_000_000,
            checks: checks.map { StabilityCheckReport(name: $0, status: "passed", detail: nil) },
            metadata: metadata
        )
        let fileName = sanitizedFileName(name) + ".json"
        let url = directory.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            Swift.print("Soundtime could not write stability report: \(error)")
            return nil
        }
    }

    private static func reportDirectory(arguments: [String]) -> URL? {
        if let reportDirectory = explicitReportDirectory(arguments: arguments) {
            return reportDirectory
        }

        guard let path = ProcessInfo.processInfo.environment["SOUNDTIME_STABILITY_REPORT_DIR"],
              !path.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func explicitReportDirectory(arguments: [String]) -> URL? {
        guard let flagIndex = arguments.firstIndex(of: "--report-dir") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex), !arguments[valueIndex].isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: arguments[valueIndex], isDirectory: true)
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let sanitized = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "soundtime-stability-report" : sanitized
    }
}
