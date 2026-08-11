import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

private enum AgentLaunchWatcherError: LocalizedError {
    case helperMissing
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "Agent 启动监听器缺失，请重新安装应用"
        case .launchctlFailed(let message):
            return "Agent 启动监听器设置失败：\(message)"
        }
    }
}

private final class AgentLaunchWatcherManager {
    private let label = "io.github.agentoverview.watch-agents"
    private let fileManager = FileManager.default

    private var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AgentSignalWatcher")
    }

    private var domain: String { "gui/\(getuid())" }
    private var serviceTarget: String { "\(domain)/\(label)" }

    var isEnabled: Bool {
        fileManager.fileExists(atPath: launchAgentURL.path) && isServiceLoaded()
    }

    func enable() throws {
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw AgentLaunchWatcherError.helperMissing
        }
        try fileManager.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperURL.path, Bundle.main.bundleURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 10,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentURL, options: .atomic)

        if isServiceLoaded() {
            try runLaunchctl(["kickstart", "-k", serviceTarget])
        } else {
            do {
                try runLaunchctl(["bootstrap", domain, launchAgentURL.path])
            } catch {
                try? fileManager.removeItem(at: launchAgentURL)
                throw error
            }
        }
    }

    func disable() throws {
        if isServiceLoaded() {
            try runLaunchctl(["bootout", serviceTarget])
        }
        if fileManager.fileExists(atPath: launchAgentURL.path) {
            try fileManager.removeItem(at: launchAgentURL)
        }
    }

    func diagnosticSummary() -> String {
        "enabled=\(isEnabled) plist=\(launchAgentURL.path) helper=\(helperURL.path)"
    }

    private func isServiceLoaded() -> Bool {
        runLaunchctlResult(["print", serviceTarget]).status == 0
    }

    private func runLaunchctl(_ arguments: [String]) throws {
        let result = runLaunchctlResult(arguments)
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentLaunchWatcherError.launchctlFailed(
                message.isEmpty ? "launchctl 返回 \(result.status)" : message
            )
        }
    }

    private func runLaunchctlResult(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

private final class AgentSignalAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let provider = AgentStatusProvider()
    private let usageProvider = AgentUsageProvider()
    private let viewModel = AgentOverviewViewModel()
    private let launchWatcherManager = AgentLaunchWatcherManager()
    private var snapshot = AgentHubSnapshot.offline()
    private var usageByKey: [String: AgentUsageSnapshot] = [:]
    private var usageRefreshing = false
    private var usageError: String?
    private var refreshTimer: Timer?
    private var usageTimer: Timer?
    private var animationTimer: Timer?
    private var spinnerAngle: CGFloat = 0
    private var previousStates: [String: AgentSignalState] = [:]
    private var initialStatusDelivered = false
    private var hasRequestedInitialUsage = false
    private var lastUsageRefreshAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        usageByKey = usageProvider.current()
        configureStatusItem()
        configurePopover()
        configureNotifications()
        migrateLegacyLoginItemIfNeeded()
        refreshStatus()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        timer.tolerance = 0.35
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        let usageTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        usageTimer.tolerance = 30
        RunLoop.main.add(usageTimer, forMode: .common)
        self.usageTimer = usageTimer
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.toolTip = "Agent 总览"
        button.image = SignalRenderer.statusBarImage(
            agents: snapshot.agents,
            spinnerAngle: spinnerAngle
        )
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
    }

    private func configurePopover() {
        viewModel.onRefresh = { [weak self] in self?.refreshAll() }
        viewModel.onToggleWatcher = { [weak self] in self?.toggleAgentLaunchWatcher() }
        viewModel.onOpenAgent = { [weak self] key in self?.openAgent(key) }
        viewModel.onQuit = { NSApp.terminate(nil) }

        let controller = NSHostingController(rootView: AgentOverviewPanel(model: viewModel))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
    }

    private func configureNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatus()
        if lastUsageRefreshAt.map({ Date().timeIntervalSince($0) > 10 }) ?? true {
            refreshUsage()
        }
    }

    private func refreshAll() {
        refreshStatus()
        refreshUsage()
    }

    private func refreshStatus() {
        provider.refresh { [weak self] next in
            guard let self else { return }
            snapshot = next
            processStateTransitions(next)
            render()
            if !hasRequestedInitialUsage {
                hasRequestedInitialUsage = true
                refreshUsage()
            }
        }
    }

    private func refreshUsage() {
        guard !usageRefreshing else { return }
        usageRefreshing = true
        usageError = nil
        publishOverview()

        let activeKeys = Set(snapshot.agents.filter(\.ready).map(\.definition.shortLabel))
        usageProvider.refresh(activeKeys: activeKeys) { [weak self] usage, error in
            guard let self else { return }
            usageByKey = usage
            usageError = error
            usageRefreshing = false
            if error == nil {
                lastUsageRefreshAt = Date()
            }
            processQuotaAlerts(usage)
            publishOverview()
        }
    }

    private func render() {
        statusItem.button?.image = SignalRenderer.statusBarImage(
            agents: snapshot.agents,
            spinnerAngle: spinnerAngle
        )
        statusItem.button?.toolTip = tooltip()
        publishOverview()
        updateAnimation()
    }

    private func publishOverview() {
        viewModel.overview = AgentOverviewSnapshot(
            status: snapshot,
            usageByKey: usageByKey,
            usageRefreshing: usageRefreshing,
            usageError: usageError,
            watcherEnabled: launchWatcherManager.isEnabled,
            spinnerAngle: spinnerAngle
        )
    }

    private func tooltip() -> String {
        snapshot.agents
            .map { "\($0.definition.shortLabel) \($0.definition.title)：\($0.state.chineseLabel)" }
            .joined(separator: "\n")
    }

    private func updateAnimation() {
        let needsAnimation = snapshot.agents.contains { $0.state == .working }
        if needsAnimation, animationTimer == nil {
            let timer = Timer(timeInterval: 0.075, repeats: true) { [weak self] _ in
                guard let self else { return }
                spinnerAngle += .pi / 10
                renderAnimatedFrame()
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !needsAnimation {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func renderAnimatedFrame() {
        statusItem.button?.image = SignalRenderer.statusBarImage(
            agents: snapshot.agents,
            spinnerAngle: spinnerAngle
        )
        publishOverview()
    }

    private func openAgent(_ key: String) {
        guard let definition = AgentDefinition.definition(for: key) else { return }

        switch definition.entryKind {
        case .app:
            openApp(definition)
        case .cli:
            openCLI(definition)
        case .web:
            if definition.appPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                openApp(definition)
            } else if let value = definition.webURL, let url = URL(string: value) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func openApp(_ definition: AgentDefinition) {
        guard let path = definition.appPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            showOpenError("没有找到 \(definition.title) App：\(definition.appPaths.joined(separator: "、"))")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: configuration
        ) { _, error in
            if let error {
                DispatchQueue.main.async { self.showOpenError(error.localizedDescription) }
            }
        }
    }

    private func openCLI(_ definition: AgentDefinition) {
        guard let relativePath = definition.cliRelativePath else { return }
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            showOpenError("没有找到 \(definition.title) CLI：\(executable.path)")
            return
        }
        let command = shellQuote(executable.path)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script \"\(escaped)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func showOpenError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "无法打开 Agent"
        alert.informativeText = detail
        alert.runModal()
    }

    private func toggleAgentLaunchWatcher() {
        do {
            if launchWatcherManager.isEnabled {
                try launchWatcherManager.disable()
            } else {
                try launchWatcherManager.enable()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法更新随 Agent 启动设置"
            alert.runModal()
        }
        publishOverview()
    }

    private func processStateTransitions(_ next: AgentHubSnapshot) {
        if !initialStatusDelivered {
            previousStates = Dictionary(uniqueKeysWithValues: next.agents.map { ($0.definition.key, $0.state) })
            initialStatusDelivered = true
            return
        }

        for agent in next.agents {
            let old = previousStates[agent.definition.key]
            previousStates[agent.definition.key] = agent.state
            guard old != agent.state else { continue }
            switch agent.state {
            case .awaiting:
                sendNotification(
                    identifier: "status.awaiting.\(agent.definition.key).\(Date().timeIntervalSince1970)",
                    title: "\(agent.definition.title) · \(agent.definition.entryKind.rawValue)",
                    body: "等待人工输入"
                )
            case .completed:
                sendNotification(
                    identifier: "status.completed.\(agent.definition.key).\(Date().timeIntervalSince1970)",
                    title: agent.definition.title,
                    body: "任务已完成"
                )
            default:
                break
            }
        }
    }

    private func processQuotaAlerts(_ usage: [String: AgentUsageSnapshot]) {
        let defaults = UserDefaults.standard
        let now = Date()
        for (key, snapshot) in usage where !snapshot.isStale {
            guard let definition = AgentDefinition.monitored.first(where: { $0.shortLabel == key }) else { continue }
            for window in snapshot.overviewAlertWindows where window.remainingPercent < 20 {
                let safeLabel = window.label.replacingOccurrences(of: " ", with: "_")
                let alertKey = "quota-alert.\(key).\(safeLabel)"
                if let last = defaults.object(forKey: alertKey) as? Date,
                   now.timeIntervalSince(last) < 24 * 60 * 60 {
                    continue
                }
                defaults.set(now, forKey: alertKey)
                sendNotification(
                    identifier: alertKey,
                    title: "\(definition.title) · 额度告警",
                    body: "\(window.label) 剩余 \(Int(window.remainingPercent.rounded()))%"
                )
            }
        }
    }

    private func sendNotification(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    private func migrateLegacyLoginItemIfNeeded() {
        guard #available(macOS 13.0, *) else { return }
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
    }
}

if CommandLine.arguments.contains("--enable-agent-watcher") {
    do {
        let manager = AgentLaunchWatcherManager()
        try manager.enable()
        print(manager.diagnosticSummary())
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--agent-watcher-status") {
    print(AgentLaunchWatcherManager().diagnosticSummary())
    exit(0)
}

if CommandLine.arguments.contains("--dump-status") {
    let provider = AgentStatusProvider()
    provider.refresh { snapshot in
        for agent in snapshot.agents {
            print("\(agent.definition.key)\t\(agent.state.rawValue)\t\(agent.sourceLabel)")
        }
        exit(snapshot.connected ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        fputs("状态读取超时\n", stderr)
        exit(2)
    }
    RunLoop.main.run()
}

private let app = NSApplication.shared
private let delegate = AgentSignalAppDelegate()
app.delegate = delegate
app.run()
