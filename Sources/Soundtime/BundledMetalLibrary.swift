import Foundation
import Metal

enum BundledMetalLibrary {
    enum LibraryError: Error {
        case unavailable(String)
    }

    static func load(
        named resourceName: String,
        device: MTLDevice,
        developmentSource: @autoclosure () -> String
    ) throws -> MTLLibrary {
        if
            let libraryURL = Bundle.module.url(forResource: resourceName, withExtension: "metallib"),
            let library = try? device.makeLibrary(URL: libraryURL)
        {
            return library
        }

        guard ProcessInfo.processInfo.environment["SOUNDTIME_ALLOW_RUNTIME_METAL_COMPILATION"] == "1" else {
            throw LibraryError.unavailable(resourceName)
        }

        return try device.makeLibrary(source: developmentSource(), options: nil)
    }
}
