import Foundation

private final class ProcessOutputBox {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data) {
        lock.lock()
        data.append(value)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let value = data
        lock.unlock()
        return String(decoding: value, as: UTF8.self)
    }
}

enum LocalStatusParser {
    static let completedTTL: TimeInterval = 10 * 60
    static let awaitingTTL: TimeInterval = 6 * 60 * 60
    static let liveActivityTTL: TimeInterval = 30
    static let hermesPromptTTL: TimeInterval = 6 * 60
    static let openClawLastGoodGrace: TimeInterval = 30

    static func openClawLastKnownGoodOutput(
        output: String?,
        fetchedAt: Date?,
        now: Date
    ) -> String? {
        guard
            let output,
            let fetchedAt,
            now.timeIntervalSince(fetchedAt) <= openClawLastGoodGrace
        else { return nil }
        return output
    }

    static func mappedState(_ rawValue: String) -> AgentSignalState? {
        let value = rawValue.lowercased()
        if ["processing", "working", "running", "active", "in_progress", "thinking", "streaming_text", "tool_running"].contains(value) {
            return .working
        }
        if ["awaiting", "waiting", "waiting_input", "awaiting_input", "input_required", "approval_required", "permission_required"].contains(value) {
            return .awaiting
        }
        if ["completed", "complete", "finished", "done", "success", "succeeded", "turn_ended"].contains(value) {
            return .completed
        }
        if ["idle", "ready", "inactive", "stopped"].contains(value) {
            return .idle
        }
        if ["error", "failed", "failure"].contains(value) {
            return .error
        }
        return nil
    }

    static func kimiEvidence(data: Data, modifiedAt: Date, now: Date) -> AgentStatusEvidence? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let states = object.values.compactMap { value -> AgentSignalState? in
            guard let text = value as? String else { return nil }
            return mappedState(text)
        }
        if states.contains(.awaiting) {
            return evidence(.awaiting, "Kimi 会话状态 · 等待人工", modifiedAt)
        }
        if states.contains(.working) {
            return evidence(.working, "Kimi 会话状态 · 任务运行中", modifiedAt)
        }
        if states.contains(.error) {
            return evidence(.error, "Kimi 会话状态 · 异常", modifiedAt)
        }
        if states.contains(.completed), now.timeIntervalSince(modifiedAt) <= completedTTL {
            return evidence(.completed, "Kimi 会话状态 · 刚刚完成", modifiedAt)
        }
        return evidence(.idle, "Kimi 会话状态 · 当前空闲", modifiedAt)
    }

    static func kimiRunnerEvidence(data: Data, modifiedAt: Date, now: Date) -> AgentStatusEvidence? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let observedAt = parseDate(object["updatedAt"]) ?? modifiedAt
        let pending = collectionCount(object["activePendingInteractions"])
        if pending > 0 {
            return evidence(.awaiting, "Kimi 运行时 · 等待人工", observedAt)
        }
        let active = collectionCount(object["activeKernelTurns"])
            + collectionCount(object["activeKernelToolCalls"])
            + collectionCount(object["activeOperations"])
        if active > 0 {
            return evidence(.working, "Kimi 运行时 · 任务运行中", observedAt)
        }
        // Daimon 常驻时 lifecycleStatus 也一直是 running，不能据此判断任务中。
        return nil
    }

    static func kimiWireEvidence(data: Data, modifiedAt: Date, now: Date) -> AgentStatusEvidence? {
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        var lastState: AgentSignalState?
        var lastDate = modifiedAt

        for line in lines {
            guard
                let lineData = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let topType = object["type"] as? String
            else { continue }

            let nested = object["event"] as? [String: Any]
            let type = ((nested?["type"] as? String) ?? topType).lowercased()
            let timestamp = parseUnixDate(object["time"])
                ?? parseUnixDate(nested?["time"])
                ?? parseDate(object["ts"])
                ?? parseDate(object["timestamp"])
                ?? modifiedAt
            let finishReason = ((nested?["finishReason"] as? String)
                ?? (object["finishReason"] as? String)
                ?? "").lowercased()

            if type.contains("approval") || type.contains("permission.request") || type.contains("input_required") {
                lastState = .awaiting
                lastDate = timestamp
            } else if ["turn.prompt", "step.begin", "llm.request", "tool.call", "tool.result"].contains(type) {
                lastState = .working
                lastDate = timestamp
            } else if type == "step.end" {
                lastState = finishReason == "end_turn" ? .completed : .working
                lastDate = timestamp
            } else if ["turn.end", "turn.completed", "task.completed"].contains(type) {
                lastState = .completed
                lastDate = timestamp
            } else if type.contains("error") || type.contains("failed") {
                lastState = .error
                lastDate = timestamp
            }
            // usage.record 紧跟在 step.end 后；它只是记账，不能覆盖任务阶段。
        }

        switch lastState {
        case .awaiting where now.timeIntervalSince(lastDate) <= awaitingTTL:
            return evidence(.awaiting, "Kimi 事件流 · 等待人工", lastDate)
        case .working where now.timeIntervalSince(lastDate) <= liveActivityTTL:
            return evidence(.working, "Kimi 事件流 · 正在活动", lastDate)
        case .error where now.timeIntervalSince(lastDate) <= completedTTL:
            return evidence(.error, "Kimi 事件流 · 任务异常", lastDate)
        case .completed where now.timeIntervalSince(lastDate) <= completedTTL:
            return evidence(.completed, "Kimi 事件流 · 刚刚完成", lastDate)
        default:
            return evidence(.idle, "Kimi App 已开启 · 当前空闲", lastDate)
        }
    }

    static func claudeTranscriptEvidence(data: Data, modifiedAt: Date, now: Date) -> AgentStatusEvidence? {
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        var lastState: AgentSignalState?
        var lastDate = modifiedAt

        for line in lines {
            guard
                let lineData = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            let type = (object["type"] as? String ?? "").lowercased()
            let subtype = (object["subtype"] as? String ?? "").lowercased()
            let timestamp = parseDate(object["timestamp"]) ?? modifiedAt
            let message = object["message"] as? [String: Any] ?? [:]
            let role = (message["role"] as? String ?? "").lowercased()
            let content = message["content"] as? [[String: Any]] ?? []
            let toolNames = content.compactMap { block -> String? in
                guard (block["type"] as? String)?.lowercased() == "tool_use" else { return nil }
                return (block["name"] as? String)?.lowercased()
            }

            if type == "user" || role == "user" {
                lastState = .working
                lastDate = timestamp
            } else if type == "assistant" || role == "assistant" {
                if toolNames.contains(where: { ["askuserquestion", "askquestion", "request_user_input"].contains($0) }) {
                    lastState = .awaiting
                } else if !toolNames.isEmpty {
                    lastState = .working
                } else {
                    let stopReason = (message["stop_reason"] as? String ?? "").lowercased()
                    if ["end_turn", "stop", "stop_sequence"].contains(stopReason) {
                        lastState = .completed
                    }
                }
                lastDate = timestamp
            } else if type == "system", subtype == "turn_duration" {
                lastState = .completed
                lastDate = timestamp
            } else if type == "result" {
                lastState = (object["is_error"] as? Bool) == true ? .error : .completed
                lastDate = timestamp
            }
        }

        switch lastState {
        case .awaiting where now.timeIntervalSince(lastDate) <= awaitingTTL:
            return evidence(.awaiting, "Claude 本地任务 · 等待人工", lastDate)
        case .working where now.timeIntervalSince(lastDate) <= liveActivityTTL:
            return evidence(.working, "Claude 本地任务 · 正在活动", lastDate)
        case .error where now.timeIntervalSince(lastDate) <= completedTTL:
            return evidence(.error, "Claude 本地任务 · 任务异常", lastDate)
        case .completed where now.timeIntervalSince(lastDate) <= completedTTL:
            return evidence(.completed, "Claude 本地任务 · 刚刚完成", lastDate)
        default:
            return evidence(.idle, "Claude App 已登录 · 本地无活动任务", lastDate)
        }
    }

    static func codexEvidence(data: Data, modifiedAt: Date, now: Date) -> AgentStatusEvidence? {
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        var startedAt: Date?
        var completedAt: Date?
        var awaitingAt: Date?
        var answeredAt: Date?
        var lastActivityAt: Date?

        for line in lines {
            guard
                let lineData = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let timestamp = parseDate(object["timestamp"]) ?? modifiedAt
            guard let topType = object["type"] as? String else { continue }
            let payload = object["payload"] as? [String: Any] ?? [:]
            let payloadType = payload["type"] as? String ?? ""

            if topType == "event_msg" {
                switch payloadType {
                case "task_started": startedAt = later(startedAt, timestamp)
                case "task_complete": completedAt = later(completedAt, timestamp)
                case "approval_requested", "request_user_input", "input_required":
                    awaitingAt = later(awaitingAt, timestamp)
                case "agent_reasoning", "agent_message", "token_count":
                    lastActivityAt = later(lastActivityAt, timestamp)
                default: break
                }
            } else if topType == "response_item" {
                let name = (payload["name"] as? String ?? "").lowercased()
                if payloadType == "function_call",
                   name == "request_user_input" || name.contains("approval") || name.contains("permission") {
                    awaitingAt = later(awaitingAt, timestamp)
                } else if payloadType == "function_call_output" {
                    answeredAt = later(answeredAt, timestamp)
                }
            }
        }

        if let awaitingAt, now.timeIntervalSince(awaitingAt) <= awaitingTTL,
           (answeredAt == nil || awaitingAt > answeredAt!),
           completedAt == nil || awaitingAt > completedAt! {
            return evidence(.awaiting, "Codex 事件流 · 等待人工", awaitingAt)
        }
        if let startedAt, completedAt == nil || startedAt > completedAt! {
            return evidence(.working, "Codex 事件流 · 任务运行中", lastActivityAt ?? startedAt)
        }
        if let completedAt, now.timeIntervalSince(completedAt) <= completedTTL {
            return evidence(.completed, "Codex 事件流 · 刚刚完成", completedAt)
        }
        if let lastActivityAt, now.timeIntervalSince(lastActivityAt) <= 12 {
            return evidence(.working, "Codex 事件流 · 正在活动", lastActivityAt)
        }
        return evidence(.idle, "Codex 事件流 · 当前空闲", completedAt ?? modifiedAt)
    }

    static func cursorEvidence(data: Data, modifiedAt: Date, now: Date) -> AgentStatusEvidence? {
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        var lastState: AgentSignalState?
        for line in lines {
            guard
                let lineData = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            let type = (object["type"] as? String ?? "").lowercased()
            if type == "turn_ended" {
                lastState = (object["status"] as? String)?.lowercased() == "error" ? .error : .completed
                continue
            }
            if type.contains("approval") || type.contains("permission") || type.contains("input_required") {
                lastState = .awaiting
                continue
            }
            let role = (object["role"] as? String ?? "").lowercased()
            let message = object["message"] as? [String: Any] ?? [:]
            let content = message["content"] as? [[String: Any]] ?? []
            let toolNames = content.compactMap { block -> String? in
                guard (block["type"] as? String)?.lowercased() == "tool_use" else { return nil }
                return (block["name"] as? String)?.lowercased()
            }
            if role == "user" {
                lastState = .working
            } else if toolNames.contains(where: { ["askquestion", "askuserquestion", "request_user_input"].contains($0) }) {
                lastState = .awaiting
            } else if role == "assistant" {
                lastState = .working
            }
        }
        if lastState == .awaiting, now.timeIntervalSince(modifiedAt) <= awaitingTTL {
            return evidence(.awaiting, "Cursor Agent 记录 · 等待人工", modifiedAt)
        }
        if lastState == .error, now.timeIntervalSince(modifiedAt) <= completedTTL {
            return evidence(.error, "Cursor Agent 记录 · 任务异常", modifiedAt)
        }
        if lastState == .completed, now.timeIntervalSince(modifiedAt) <= completedTTL {
            return evidence(.completed, "Cursor Agent 记录 · 刚刚完成", modifiedAt)
        }
        if lastState == .working, now.timeIntervalSince(modifiedAt) <= liveActivityTTL {
            return evidence(.working, "Cursor Agent 记录 · 正在写入", modifiedAt)
        }
        return evidence(.idle, "Cursor App 已开启 · 未检测到活动任务", modifiedAt)
    }

    static func hermesEventEvidence(data: Data, modifiedAt: Date, now: Date) -> AgentStatusEvidence? {
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        var sessionStates: [String: AgentSignalState] = [:]

        for line in lines {
            let text = String(line)
            guard let jsonStart = text.firstIndex(of: "{") else { continue }
            let json = String(text[jsonStart...])
            guard
                let lineData = json.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                (object["method"] as? String) == "event",
                let params = object["params"] as? [String: Any],
                let rawType = params["type"] as? String
            else { continue }

            let type = rawType.lowercased()
            let sessionID = (params["session_id"] as? String) ?? "global"
            let payload = params["payload"] as? [String: Any] ?? [:]
            if ["approval.request", "clarify.request", "sudo.request", "secret.request"].contains(type)
                || type.contains("input_required") {
                sessionStates[sessionID] = .awaiting
            } else if ["message.start", "message.delta", "tool.start", "tool.complete"].contains(type) {
                sessionStates[sessionID] = .working
            } else if type == "message.complete" {
                let status = (payload["status"] as? String ?? "").lowercased()
                sessionStates[sessionID] = ["error", "failed", "failure"].contains(status) ? .error : .completed
            } else if type == "session.info", let running = payload["running"] as? Bool {
                sessionStates[sessionID] = running ? .working : .idle
            }
        }

        if sessionStates.values.contains(.awaiting), now.timeIntervalSince(modifiedAt) <= hermesPromptTTL {
            return evidence(.awaiting, "Hermes 网关事件 · 等待人工", modifiedAt)
        }
        if sessionStates.values.contains(.working), now.timeIntervalSince(modifiedAt) <= liveActivityTTL {
            return evidence(.working, "Hermes 网关事件 · 正在活动", modifiedAt)
        }
        if sessionStates.values.contains(.error), now.timeIntervalSince(modifiedAt) <= completedTTL {
            return evidence(.error, "Hermes 网关事件 · 任务异常", modifiedAt)
        }
        if sessionStates.values.contains(.completed), now.timeIntervalSince(modifiedAt) <= completedTTL {
            return evidence(.completed, "Hermes 网关事件 · 刚刚完成", modifiedAt)
        }
        return nil
    }

    static func openClawTrajectoryEvidence(data: Data, modifiedAt: Date, now: Date) -> AgentStatusEvidence? {
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        var lastState: AgentSignalState?
        var lastDate = modifiedAt

        for line in lines {
            guard
                let lineData = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let rawType = object["type"] as? String
            else { continue }

            let type = rawType.lowercased()
            let timestamp = parseDate(object["ts"]) ?? parseDate(object["timestamp"]) ?? modifiedAt
            let payload = object["data"] as? [String: Any] ?? [:]
            let status = (payload["status"] as? String ?? "").lowercased()

            let toolName = (payload["name"] as? String ?? "").lowercased()
            if type.contains("approval") || type.contains("permission") || type.contains("input_required")
                || (type == "tool.call" && ["askquestion", "askuserquestion", "request_user_input"].contains(toolName)) {
                lastState = .awaiting
                lastDate = timestamp
            } else if ["prompt.submitted", "session.started", "tool.call", "tool.result"].contains(type) {
                lastState = .working
                lastDate = timestamp
            } else if type == "session.ended" {
                lastState = ["error", "failed", "failure"].contains(status) ? .error : .completed
                lastDate = timestamp
            } else if type == "model.completed" {
                lastState = .completed
                lastDate = timestamp
            } else if type.contains("error") || type.contains("failed") {
                lastState = .error
                lastDate = timestamp
            }
        }

        switch lastState {
        case .awaiting where now.timeIntervalSince(lastDate) <= awaitingTTL:
            return evidence(.awaiting, "OpenClaw 会话轨迹 · 等待人工", lastDate)
        case .working:
            return evidence(.working, "OpenClaw 会话轨迹 · 任务运行中", lastDate)
        case .error where now.timeIntervalSince(lastDate) <= completedTTL:
            return evidence(.error, "OpenClaw 会话轨迹 · 任务异常", lastDate)
        case .completed where now.timeIntervalSince(lastDate) <= completedTTL:
            return evidence(.completed, "OpenClaw 会话轨迹 · 刚刚完成", lastDate)
        default:
            return evidence(.idle, "OpenClaw 网页已开启 · 当前无任务", lastDate)
        }
    }

    static func hermesEvidence(activeSessions: Int, lastEndedAt: Date?, now: Date) -> AgentStatusEvidence {
        if activeSessions > 0 {
            return evidence(.working, "Hermes 本地 API · 有活动会话", now)
        }
        if let lastEndedAt, now.timeIntervalSince(lastEndedAt) <= completedTTL {
            return evidence(.completed, "Hermes 会话库 · 刚刚完成", lastEndedAt)
        }
        return evidence(.idle, "Hermes 本地 API · 当前空闲", now)
    }

    private static func evidence(_ state: AgentSignalState, _ label: String, _ date: Date?) -> AgentStatusEvidence {
        AgentStatusEvidence(state: state, sourceLabel: label, updatedAt: date)
    }

    private static func later(_ current: Date?, _ candidate: Date) -> Date {
        guard let current else { return candidate }
        return max(current, candidate)
    }

    private static func collectionCount(_ value: Any?) -> Int {
        if let array = value as? [Any] { return array.count }
        if let object = value as? [String: Any] { return object.count }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: text) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: text)
    }

    private static func parseUnixDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let text = value as? String, let raw = Double(text) {
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        return parseDate(value)
    }
}

final class AgentStatusProvider {
    private let queue = DispatchQueue(label: "com.local.agent-signal.status", qos: .utility)
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private var refreshing = false
    private var cachedOpenClawOutput: String?
    private var openClawFetchedAt: Date?
    private var cachedHermesEvidence: AgentStatusEvidence?
    private var hermesFetchedAt: Date?
    private var discoveryCache: [String: (url: URL, date: Date)] = [:]

    func refresh(completion: @escaping (AgentHubSnapshot) -> Void) {
        lock.lock()
        guard !refreshing else {
            lock.unlock()
            return
        }
        refreshing = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.readSnapshot()
            self.lock.lock()
            self.refreshing = false
            self.lock.unlock()
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    private func readSnapshot() -> AgentHubSnapshot {
        let processResult = run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,comm=,args="],
            timeout: 3
        )
        guard processResult.status == 0 else {
            return .offline(message: "无法读取本机 Agent 进程：\(processResult.output)")
        }

        let processText = processResult.output
        func isRunning(_ key: String) -> Bool {
            guard let definition = AgentDefinition.definition(for: key) else { return false }
            return DirectStatusEvaluator.isProcessRunning(definition: definition, processText: processText)
        }

        var evidence: [String: AgentStatusEvidence] = [:]
        if isRunning("claude") {
            evidence["claude"] = claudeEvidence()
        }
        if isRunning("codex") { evidence["codex"] = codexEvidence() }
        if isRunning("kimi") { evidence["kimi"] = kimiEvidence() }
        if isRunning("cursor") { evidence["cursor"] = cursorEvidence() }
        if isRunning("hermes") { evidence["hermes"] = hermesEvidence() }

        let openClawRunning = openClawUIRunning(processText: processText)
        if openClawRunning, let trajectory = openClawTrajectoryEvidence(), trajectory.state != .idle {
            evidence["openclaw"] = trajectory
        }
        return DirectStatusEvaluator.snapshot(
            processText: processText,
            openClawOutput: openClawRunning ? openClawStatus() : nil,
            evidence: evidence,
            runningOverrides: ["openclaw": openClawRunning]
        )
    }

    private func openClawUIRunning(processText: String) -> Bool {
        if let definition = AgentDefinition.definition(for: "openclaw"),
           DirectStatusEvaluator.isProcessRunning(definition: definition, processText: processText) {
            return true
        }
        let result = run(
            executable: URL(fileURLWithPath: "/usr/bin/lsappinfo"),
            arguments: ["list"],
            timeout: 2
        )
        guard result.status == 0 else { return false }
        return result.output.lowercased().contains("com.google.chrome.app.fdpbfcmhdmhnbbcblfofemkcoonbgded")
    }

    private func claudeEvidence() -> AgentStatusEvidence {
        let now = Date()
        let cookieDatabases = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/Cookies"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/Partitions/launch-preview-static/Cookies"),
        ]
        var queriedDatabase = false
        var loggedIn = false
        for database in cookieDatabases where fileManager.fileExists(atPath: database.path) {
            let result = run(
                executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: [database.path, "SELECT count(*) FROM cookies WHERE lower(name) LIKE 'sessionkey%';"],
                timeout: 2
            )
            guard result.status == 0 else { continue }
            queriedDatabase = true
            if (Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 {
                loggedIn = true
                break
            }
        }
        if loggedIn {
            if let taskEvidence = claudeTaskEvidence(), taskEvidence.state != .idle {
                return taskEvidence
            }
            return AgentStatusEvidence(
                state: .idle,
                sourceLabel: "Claude App 已登录 · 本地无活动信号（推断）",
                updatedAt: now
            )
        }
        if queriedDatabase || claudeConfigSaysSignedOut() {
            return AgentStatusEvidence(
                state: .offline,
                sourceLabel: "Claude App 已打开 · 未登录",
                updatedAt: now
            )
        }
        return AgentStatusEvidence(
            state: .unknown,
            sourceLabel: "Claude App 已打开 · 登录状态读取失败",
            updatedAt: now
        )
    }

    private func claudeConfigSaysSignedOut() -> Bool {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object["windowSizeWasSignedIn"] as? Bool
        else { return false }
        return !value
    }

    private func claudeTaskEvidence() -> AgentStatusEvidence? {
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard
            let url = newestFile(
                root: root,
                suffix: ".jsonl",
                excludedPathComponent: "/subagents/",
                cacheKey: "claude-transcript",
                rediscoverAfter: 6
            ),
            let data = tail(url: url, maximumBytes: 1_000_000),
            let modifiedAt = modificationDate(url)
        else { return nil }
        return LocalStatusParser.claudeTranscriptEvidence(data: data, modifiedAt: modifiedAt, now: Date())
    }

    private func codexEvidence() -> AgentStatusEvidence {
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let url = newestFile(root: root, suffix: ".jsonl", cacheKey: "codex", rediscoverAfter: 6),
              let data = tail(url: url, maximumBytes: 1_500_000),
              let modifiedAt = modificationDate(url),
              let result = LocalStatusParser.codexEvidence(data: data, modifiedAt: modifiedAt, now: Date())
        else {
            return AgentStatusEvidence(state: .unknown, sourceLabel: "Codex 已开启 · 事件流读取失败", updatedAt: nil)
        }
        return result
    }

    private func kimiEvidence() -> AgentStatusEvidence {
        let now = Date()
        let daimonRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon")
        let runnerURL = daimonRoot.appendingPathComponent("agents/main/runner.state.json")
        if let data = try? Data(contentsOf: runnerURL),
           let modifiedAt = modificationDate(runnerURL),
           let runner = LocalStatusParser.kimiRunnerEvidence(data: data, modifiedAt: modifiedAt, now: now) {
            return runner
        }

        let sessionsRoot = daimonRoot.appendingPathComponent("runtime/kimi-code/home/sessions")
        if let url = newestFile(root: sessionsRoot, suffix: "wire.jsonl", cacheKey: "kimi-wire", rediscoverAfter: 2),
           let data = tail(url: url, maximumBytes: 1_000_000),
           let modifiedAt = modificationDate(url),
           let wire = LocalStatusParser.kimiWireEvidence(data: data, modifiedAt: modifiedAt, now: now) {
            return wire
        }

        // 兼容旧版 Kimi；新版 3.x 的主信号源是上面的 Daimon runner + wire。
        let legacyURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-desktop/kimi-agent/conversation-statuses.json")
        if let data = try? Data(contentsOf: legacyURL),
           let modifiedAt = modificationDate(legacyURL),
           let legacy = LocalStatusParser.kimiEvidence(data: data, modifiedAt: modifiedAt, now: now) {
            return legacy
        }
        return AgentStatusEvidence(state: .unknown, sourceLabel: "Kimi 已开启 · 运行时状态读取失败", updatedAt: nil)
    }

    private func cursorEvidence() -> AgentStatusEvidence {
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/projects")
        if let url = newestFile(root: root, suffix: ".jsonl", requiredPathComponent: "/agent-transcripts/", cacheKey: "cursor", rediscoverAfter: 8),
           let data = tail(url: url, maximumBytes: 350_000),
           let modifiedAt = modificationDate(url),
           let result = LocalStatusParser.cursorEvidence(data: data, modifiedAt: modifiedAt, now: Date()) {
            return result
        }
        return AgentStatusEvidence(state: .idle, sourceLabel: "Cursor App 已开启 · 未检测到 Agent 任务", updatedAt: Date())
    }

    private func hermesEvidence() -> AgentStatusEvidence {
        let now = Date()
        if let fetchedAt = hermesFetchedAt, now.timeIntervalSince(fetchedAt) < 4, let cachedHermesEvidence {
            return cachedHermesEvidence
        }
        if let eventEvidence = hermesEventEvidence(), eventEvidence.state == .awaiting {
            cachedHermesEvidence = eventEvidence
            hermesFetchedAt = now
            return eventEvidence
        }
        let result = run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-fsS", "--max-time", "2", "http://127.0.0.1:9119/api/status"],
            timeout: 3
        )
        let observed: AgentStatusEvidence
        if result.status == 0,
           let data = result.output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let count = (object["active_sessions"] as? NSNumber)?.intValue {
            observed = LocalStatusParser.hermesEvidence(
                activeSessions: count,
                lastEndedAt: hermesLatestEndedAt(),
                now: now
            )
        } else if hermesHasActiveDelegation() {
            observed = AgentStatusEvidence(state: .working, sourceLabel: "Hermes 本地任务运行中", updatedAt: now)
        } else if let lastEndedAt = hermesLatestEndedAt(), now.timeIntervalSince(lastEndedAt) <= LocalStatusParser.completedTTL {
            observed = LocalStatusParser.hermesEvidence(activeSessions: 0, lastEndedAt: lastEndedAt, now: now)
        } else {
            observed = AgentStatusEvidence(state: .unknown, sourceLabel: "Hermes 已开启 · 本地状态 API 不可达", updatedAt: now)
        }
        cachedHermesEvidence = observed
        hermesFetchedAt = now
        return observed
    }

    private func hermesEventEvidence() -> AgentStatusEvidence? {
        let url = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/logs/desktop.log")
        guard
            let data = tail(url: url, maximumBytes: 800_000),
            let modifiedAt = modificationDate(url)
        else { return nil }
        return LocalStatusParser.hermesEventEvidence(data: data, modifiedAt: modifiedAt, now: Date())
    }

    private func openClawStatus() -> String? {
        let now = Date()
        if let fetchedAt = openClawFetchedAt,
           now.timeIntervalSince(fetchedAt) < 10,
           let cachedOpenClawOutput {
            return cachedOpenClawOutput
        }

        if openClawGatewayReachable() {
            let fallback = "Gateway local reachable via HTTP fallback"
            cachedOpenClawOutput = fallback
            openClawFetchedAt = now
            return fallback
        }

        let executable = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/bin/openclaw")
        if fileManager.isExecutableFile(atPath: executable.path) {
            let result = run(executable: executable, arguments: ["status"], timeout: 5)
            if result.status == 0 {
                cachedOpenClawOutput = result.output
                openClawFetchedAt = now
                return result.output
            }
        }

        return LocalStatusParser.openClawLastKnownGoodOutput(
            output: cachedOpenClawOutput,
            fetchedAt: openClawFetchedAt,
            now: now
        )
    }

    private func openClawGatewayReachable() -> Bool {
        let result = run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "--silent",
                "--show-error",
                "--fail",
                "--max-time", "1",
                "http://127.0.0.1:9999/",
            ],
            timeout: 2
        )
        return result.status == 0 && result.output.lowercased().contains("openclaw")
    }

    private func openClawTrajectoryEvidence() -> AgentStatusEvidence? {
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/agents/main/sessions")
        guard
            let url = newestFile(root: root, suffix: ".trajectory.jsonl", cacheKey: "openclaw-trajectory", rediscoverAfter: 4),
            let data = tail(url: url, maximumBytes: 2_000_000),
            let modifiedAt = modificationDate(url)
        else { return nil }
        return LocalStatusParser.openClawTrajectoryEvidence(data: data, modifiedAt: modifiedAt, now: Date())
    }

    private func hermesLatestEndedAt() -> Date? {
        let database = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/state.db")
        guard fileManager.fileExists(atPath: database.path) else { return nil }
        let query = "SELECT coalesce(max(ended_at),0) FROM sessions WHERE ended_at IS NOT NULL;"
        let result = run(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"), arguments: [database.path, query], timeout: 2)
        guard result.status == 0, let raw = Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines)), raw > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }

    private func hermesHasActiveDelegation() -> Bool {
        let database = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/state.db")
        guard fileManager.fileExists(atPath: database.path) else { return false }
        let query = "SELECT count(*) FROM async_delegations WHERE completed_at IS NULL AND lower(state) NOT IN ('completed','failed','cancelled');"
        let result = run(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"), arguments: [database.path, query], timeout: 2)
        return result.status == 0 && (Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    private func newestFile(
        root: URL,
        suffix: String,
        requiredPathComponent: String? = nil,
        excludedPathComponent: String? = nil,
        cacheKey: String,
        rediscoverAfter: TimeInterval
    ) -> URL? {
        let now = Date()
        if let cached = discoveryCache[cacheKey], now.timeIntervalSince(cached.date) < rediscoverAfter,
           fileManager.fileExists(atPath: cached.url.path) {
            return cached.url
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.path.hasSuffix(suffix) else { continue }
            if let requiredPathComponent, !url.path.contains(requiredPathComponent) { continue }
            if let excludedPathComponent, url.path.contains(excludedPathComponent) { continue }
            guard let date = modificationDate(url) else { continue }
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        if let newest { discoveryCache[cacheKey] = (newest.url, now) }
        return newest?.url
    }

    private func tail(url: URL, maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        var data = handle.readDataToEndOfFile()
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data.suffix(from: data.index(after: newline))
        }
        return data
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func run(executable: URL, arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        let outputBox = ProcessOutputBox()
        let readers = DispatchGroup()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in finished.signal() }

        for pipe in [outputPipe, errorPipe] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                outputBox.append(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }
        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            return (-1, error.localizedDescription)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            _ = readers.wait(timeout: .now() + 1)
            return (-2, "读取超时")
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        if readers.wait(timeout: .now() + max(timeout, 1)) == .timedOut {
            return (-3, "输出读取超时")
        }
        return (process.terminationStatus, outputBox.string())
    }
}
