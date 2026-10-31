import Foundation

enum RuntimeContext {
    static var testPreferencesURL: URL? {
        guard isTesting, let path = ProcessInfo.processInfo.environment["PATHDECK_TEST_PREFERENCES"], path.hasPrefix("/private/tmp/PathDeck-Session-") else { return nil }
        return URL(fileURLWithPath: path)
    }
    static let isTesting = ["--tile-test", "--continuity-test", "--workspace-save-test", "--workspace-load-test"].contains(where: CommandLine.arguments.contains) || CommandLine.arguments.contains("--drag-test") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--performance-test") || CommandLine.arguments.contains("--terminal-test") || CommandLine.arguments.contains("--interaction-test") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    @MainActor static var startedAt = ProcessInfo.processInfo.systemUptime
}
