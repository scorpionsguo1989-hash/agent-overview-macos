import AppKit
import Foundation

private let signalBundleIdentifier = "io.github.agentoverview.macos"
private let monitoredBundleIdentifiers: Set<String> = [
    "com.anthropic.claudefordesktop",
    "com.openai.codex",
    "com.moonshot.kimichat",
    "com.todesktop.230313mzl4w4u92",
    "com.nousresearch.hermes",
    "com.google.Chrome.app.fdpbfcmhdmhnbbcblfofemkcoonbgded",
]
private final class AgentLaunchWatcher {
    private let signalAppURL: URL
    private var launchObserver: NSObjectProtocol?

    init(signalAppURL: URL) {
        self.signalAppURL = signalAppURL
    }

    func run() {
        let workspace = NSWorkspace.shared

        if workspace.runningApplications.contains(where: isMonitoredDesktopApp) {
            launchSignalAppIfNeeded()
        }

        launchObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                self.isMonitoredDesktopApp(application)
            else { return }
            self.launchSignalAppIfNeeded()
        }

        RunLoop.main.run()
    }

    func diagnosticSummary() -> String {
        let appCount = NSWorkspace.shared.runningApplications.filter(isMonitoredDesktopApp).count
        let signalRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: signalBundleIdentifier
        ).isEmpty
        return "apps=\(appCount) signalApp=\(signalRunning)"
    }

    private func launchSignalAppIfNeeded() {
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: signalBundleIdentifier
        ).isEmpty else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: signalAppURL, configuration: configuration)
    }

    private func isMonitoredDesktopApp(_ application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return monitoredBundleIdentifiers.contains(bundleIdentifier)
    }
}

guard CommandLine.arguments.count >= 2 else { exit(64) }

let checkOnly = CommandLine.arguments[1] == "--check"
let appPathIndex = checkOnly ? 2 : 1
guard CommandLine.arguments.indices.contains(appPathIndex) else { exit(64) }

private let watcher = AgentLaunchWatcher(
    signalAppURL: URL(fileURLWithPath: CommandLine.arguments[appPathIndex])
)
if checkOnly {
    print(watcher.diagnosticSummary())
    exit(0)
}
watcher.run()
