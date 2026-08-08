import Foundation
import SoundtimeDiagnosticsCore

@main
enum SoundtimeLogCommand {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var root = DiagnosticSessionStore.defaultRootURL
        if let index = args.firstIndex(of: "--root"), args.indices.contains(index + 1) {
            root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            args.removeSubrange(index ... index + 1)
        }
        guard let command = args.first else { usage(); return }
        let files = DiagnosticSessionStore.sessionFiles(rootURL: root)
        switch command {
        case "list":
            for file in files { print(file.lastPathComponent) }
        case "tail":
            guard let file = resolve(args.dropFirst().first, files: files, root: root) else { throw CLIError.noSession }
            let count = Int(args.dropFirst(2).first ?? "50") ?? 50
            for event in try DiagnosticSessionStore.readEvents(at: file).suffix(count) { printLine(event) }
        case "search":
            let query = DiagnosticQuery(args.dropFirst().joined(separator: " "))
            guard !files.isEmpty else { throw CLIError.noSession }
            for file in files {
                for event in try DiagnosticSessionStore.readEvents(at: file).filter({ query.matches($0) }) {
                    print("\(file.lastPathComponent):", terminator: " ")
                    printLine(event)
                }
            }
        case "show":
            guard let file = resolve(args.dropFirst().first, files: files, root: root) else { throw CLIError.noSession }
            for event in try DiagnosticSessionStore.readEvents(at: file) { printLine(event) }
        case "incidents":
            for file in ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter({ $0.lastPathComponent.hasPrefix("incident-") }) { print(file.lastPathComponent) }
        case "export":
            guard let file = resolve(args.dropFirst().first, files: files, root: root) else { throw CLIError.noSession }
            let output = args.dropFirst(2).first.map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Soundtime-Diagnostics.soundtimediagnostics.zip")
            _ = try DiagnosticBundleExporter.export(sessionURL: file, outputURL: output,
                includeIdentifiable: args.contains("--include-identifiable"))
            print(output.path)
        default: usage()
        }
    }

    private static func resolve(_ value: String?, files: [URL], root: URL) -> URL? {
        guard let value else { return files.first }
        let direct = URL(fileURLWithPath: value)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return files.first { $0.lastPathComponent == value || $0.lastPathComponent.contains(value) }
    }
    private static func printLine(_ event: DiagnosticEvent) {
        let time = ISO8601DateFormatter().string(from: event.wallTime)
        let fields = event.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("\(time) [\(event.severity.rawValue.uppercased())] \(event.category.rawValue).\(event.name) \(event.message) \(fields)")
    }
    private static func usage() {
        print("""
        SoundtimeLog list [--root PATH]
        SoundtimeLog tail [SESSION] [COUNT]
        SoundtimeLog search QUERY
        SoundtimeLog show SESSION
        SoundtimeLog incidents
        SoundtimeLog export [SESSION] [OUTPUT] [--include-identifiable]
        """)
    }
    enum CLIError: Error { case noSession }
}
