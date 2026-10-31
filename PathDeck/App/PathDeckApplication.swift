import AppKit

@main
@MainActor
enum PathDeckApplication {
    static func main() {
        RuntimeContext.startedAt = ProcessInfo.processInfo.systemUptime
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

