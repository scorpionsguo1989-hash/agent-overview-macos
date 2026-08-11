import Foundation

enum AgentSignalState: String, Equatable {
    case offline
    case idle
    case unknown
    case awaiting
    case completed
    case working
    case error

    var chineseLabel: String {
        switch self {
        case .offline: return "未开启"
        case .idle: return "空闲"
        case .unknown: return "状态未知"
        case .awaiting: return "等待人工"
        case .completed: return "工作完成"
        case .working: return "任务中"
        case .error: return "异常"
        }
    }
}

enum AgentEntryKind: String, Equatable {
    case app = "App"
    case cli = "CLI"
    case web = "Web"
}

struct AgentDefinition: Equatable {
    let key: String
    let title: String
    let shortLabel: String
    let entryKind: AgentEntryKind
    let processMatchers: [String]
    let appPaths: [String]
    let cliRelativePath: String?
    let webURL: String?

    static let monitored: [AgentDefinition] = [
        AgentDefinition(
            key: "claude",
            title: "Claude",
            shortLabel: "cc",
            entryKind: .app,
            processMatchers: ["/applications/claude.app/contents/macos/claude"],
            appPaths: ["/Applications/Claude.app"],
            cliRelativePath: nil,
            webURL: nil
        ),
        AgentDefinition(
            key: "codex",
            title: "Codex",
            shortLabel: "cdx",
            entryKind: .app,
            processMatchers: ["/applications/chatgpt.app/contents/macos/chatgpt"],
            appPaths: ["/Applications/ChatGPT.app"],
            cliRelativePath: nil,
            webURL: nil
        ),
        AgentDefinition(
            key: "kimi",
            title: "Kimi",
            shortLabel: "km",
            entryKind: .app,
            processMatchers: ["/applications/kimi.app/contents/macos/kimi"],
            appPaths: ["/Applications/Kimi.app"],
            cliRelativePath: nil,
            webURL: nil
        ),
        AgentDefinition(
            key: "cursor",
            title: "Cursor",
            shortLabel: "cs",
            entryKind: .app,
            processMatchers: ["/applications/cursor.app/contents/macos/cursor"],
            appPaths: ["/Applications/Cursor.app"],
            cliRelativePath: nil,
            webURL: nil
        ),
        AgentDefinition(
            key: "hermes",
            title: "Hermes",
            shortLabel: "hm",
            entryKind: .app,
            processMatchers: ["/hermes.app/contents/macos/hermes"],
            appPaths: [
                NSHomeDirectory() + "/.hermes/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app",
                "/Applications/Hermes.app",
            ],
            cliRelativePath: nil,
            webURL: nil
        ),
        AgentDefinition(
            key: "openclaw",
            title: "OpenClaw",
            shortLabel: "oc",
            entryKind: .web,
            processMatchers: [
                "/openclaw control.app/contents/macos/app_mode_loader",
                "--app-id=fdpbfcmhdmhnbbcblfofemkcoonbgded",
            ],
            appPaths: [
                NSHomeDirectory() + "/Applications/Chrome Apps.localized/OpenClaw Control.app",
            ],
            cliRelativePath: nil,
            webURL: "http://127.0.0.1:9999/"
        ),
    ]

    static func definition(for key: String) -> AgentDefinition? {
        monitored.first { $0.key == key }
    }
}

struct AgentSignalSnapshot: Equatable {
    let definition: AgentDefinition
    let state: AgentSignalState
    let sourceLabel: String
    let updatedAt: Date?
    let ready: Bool
}

struct AgentStatusEvidence: Equatable {
    let state: AgentSignalState
    let sourceLabel: String
    let updatedAt: Date?
}

struct AgentHubSnapshot {
    let agents: [AgentSignalSnapshot]
    let connected: Bool
    let fetchedAt: Date
    let errorMessage: String?

    static func offline(message: String? = nil) -> AgentHubSnapshot {
        AgentHubSnapshot(
            agents: AgentDefinition.monitored.map {
                AgentSignalSnapshot(
                    definition: $0,
                    state: .offline,
                    sourceLabel: "未开启",
                    updatedAt: nil,
                    ready: false
                )
            },
            connected: false,
            fetchedAt: Date(),
            errorMessage: message
        )
    }
}

enum DirectStatusEvaluator {
    static func isProcessRunning(definition: AgentDefinition, processText: String) -> Bool {
        let lowercased = processText.lowercased()
        return definition.processMatchers.contains { lowercased.contains($0.lowercased()) }
    }

    static func snapshot(
        processText: String,
        openClawOutput: String? = nil,
        hermesHasActiveDelegation: Bool = false,
        evidence: [String: AgentStatusEvidence] = [:],
        runningOverrides: [String: Bool] = [:],
        now: Date = Date()
    ) -> AgentHubSnapshot {
        let agents = AgentDefinition.monitored.map { definition -> AgentSignalSnapshot in
            let running = runningOverrides[definition.key]
                ?? isProcessRunning(definition: definition, processText: processText)
            guard running else {
                return AgentSignalSnapshot(
                    definition: definition,
                    state: .offline,
                    sourceLabel: "未开启",
                    updatedAt: nil,
                    ready: false
                )
            }

            let result: AgentStatusEvidence
            if let observed = evidence[definition.key] {
                result = observed
            } else if definition.key == "openclaw", let openClawOutput {
                let observed = openClawResult(from: openClawOutput)
                result = AgentStatusEvidence(
                    state: observed.0,
                    sourceLabel: observed.1,
                    updatedAt: now
                )
            } else if definition.key == "hermes", hermesHasActiveDelegation {
                result = AgentStatusEvidence(
                    state: .working,
                    sourceLabel: "本地任务运行中",
                    updatedAt: now
                )
            } else if definition.key == "openclaw" {
                result = AgentStatusEvidence(
                    state: .unknown,
                    sourceLabel: "入口已启动 · Gateway 状态读取失败",
                    updatedAt: now
                )
            } else {
                result = AgentStatusEvidence(
                    state: .idle,
                    sourceLabel: "入口已启动 · 未检测到活动任务",
                    updatedAt: now
                )
            }

            return AgentSignalSnapshot(
                definition: definition,
                state: result.state,
                sourceLabel: result.sourceLabel,
                updatedAt: result.updatedAt,
                ready: result.state != .offline
            )
        }

        return AgentHubSnapshot(
            agents: agents,
            connected: true,
            fetchedAt: now,
            errorMessage: nil
        )
    }

    static func openClawResult(from output: String) -> (AgentSignalState, String) {
        let lowercased = output.lowercased()
        guard lowercased.contains("gateway"), lowercased.contains("reachable") else {
            return (.unknown, "入口已启动，Gateway 状态未知")
        }

        let pattern = #"tasks\s+.*?(\d+)\s+active\s+.*?(\d+)\s+queued\s+.*?(\d+)\s+running"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return (.idle, "Gateway 可达")
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range) else {
            return (.idle, "Gateway 可达")
        }

        let counts = (1...3).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: output) else { return nil }
            return Int(output[range])
        }
        guard counts.count == 3 else {
            return (.idle, "Gateway 可达")
        }
        if counts.contains(where: { $0 > 0 }) {
            return (.working, "OpenClaw 有活动任务")
        }
        return (.idle, "Gateway 可达 · 当前无任务")
    }
}
