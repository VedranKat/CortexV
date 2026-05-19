import Foundation

enum AppPaths {
    static var appHome: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cortex V", isDirectory: true)
        createDirectory(url)
        return url
    }

    static var dataDirectory: URL {
        let url = appHome.appendingPathComponent("data", isDirectory: true)
        createDirectory(url)
        return url
    }

    static var databaseFile: URL {
        dataDirectory.appendingPathComponent("CortexV.sqlite", isDirectory: false)
    }

    private static func createDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            fatalError("Failed to create directory \(url.path): \(error)")
        }
    }
}
