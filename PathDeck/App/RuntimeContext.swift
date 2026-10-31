import Foundation

enum RuntimeContext {
    static let isTesting = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--performance-test") || CommandLine.arguments.contains("--terminal-test") || CommandLine.arguments.contains("--interaction-test") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    @MainActor static var startedAt = ProcessInfo.processInfo.systemUptime
}
