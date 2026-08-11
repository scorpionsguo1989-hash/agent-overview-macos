import Foundation

@main
struct StatusModelTests {
    static func main() {
        validatesAgentIdentityBadges()
        detectsAppCLIAndWebEntrypoints()
        mapsOpenClawIdleAndWorkingStates()
        preservesOpenClawStateAcrossBriefProbeFailures()
        mapsLocalTaskEventSources()
        mapsKimiDaimonRuntimeStates()
        mapsOpenClawTrajectoryStates()
        mapsHermesCompletion()
        mapsAwaitingHumanSignals()
        preservesOfflineAndIdleDistinction()
        marksOpenButSignedOutAgentOffline()
        print("AgentSignalMenu model tests: PASS")
    }

    private static func validatesAgentIdentityBadges() {
        require(AgentDefinition.monitored.count == 6, "应监控六个 Agent")
        let labels = AgentDefinition.monitored.map(\.shortLabel)
        require(Set(labels).count == labels.count, "状态栏短标识必须唯一")
        require(labels.allSatisfy { (2...3).contains($0.count) }, "状态栏短标识应为二至三个字符")
        let expected = [
            "claude": "cc",
            "codex": "cdx",
            "kimi": "km",
            "cursor": "cs",
            "hermes": "hm",
            "openclaw": "oc",
        ]
        for (key, label) in expected {
            require(AgentDefinition.definition(for: key)?.shortLabel == label, "\(key) 标识错误")
        }
        require(AgentDefinition.definition(for: "claudex") == nil, "信号灯不应再包含 Claudex/ccx")
        require(!labels.contains("ccx"), "状态栏不应再渲染 ccx")
        require(AgentDefinition.definition(for: "zcode") == nil, "信号灯不应再包含 ZCode/zc")
        require(!labels.contains("zc"), "状态栏不应再渲染 zc")
        require(AgentDefinition.definition(for: "grok") == nil, "信号灯不应再包含 Grok/gk")
        require(!labels.contains("gk"), "状态栏不应再渲染 gk")
    }

    private static func detectsAppCLIAndWebEntrypoints() {
        let processText = """
        /Applications/Claude.app/Contents/MacOS/Claude
        /Applications/Cursor.app/Contents/MacOS/Cursor
        /tmp/agent-overview-test/.hermes/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS/Hermes
        /tmp/agent-overview-test/Applications/Chrome Apps.localized/OpenClaw Control.app/Contents/MacOS/app_mode_loader
        """
        let snapshot = DirectStatusEvaluator.snapshot(processText: processText)
        let states = Dictionary(uniqueKeysWithValues: snapshot.agents.map {
            ($0.definition.key, $0.state)
        })
        require(states["claude"] == .idle, "Claude App 应识别为已开启空闲")
        require(states["cursor"] == .idle, "Cursor App 应被识别")
        require(states["hermes"] == .idle, "Hermes App 应被识别")
        require(states["openclaw"] == .unknown, "无 Gateway 探测结果时应保持未知")
        require(states["kimi"] == .offline, "未运行的 Kimi 应为未开启")
    }

    private static func mapsOpenClawIdleAndWorkingStates() {
        let processText = "/tmp/agent-overview-test/Applications/Chrome Apps.localized/OpenClaw Control.app/Contents/MacOS/app_mode_loader"
        let idle = DirectStatusEvaluator.snapshot(
            processText: processText,
            openClawOutput: "Gateway local reachable 36ms\nTasks 0 active · 0 queued · 0 running"
        )
        require(state("openclaw", in: idle) == .idle, "OpenClaw 无任务时应为空闲")

        let working = DirectStatusEvaluator.snapshot(
            processText: processText,
            openClawOutput: "Gateway local reachable 20ms\nTasks 1 active · 0 queued · 1 running"
        )
        require(state("openclaw", in: working) == .working, "OpenClaw 有活动任务时应为任务中")

        let gatewayOnly = DirectStatusEvaluator.snapshot(
            processText: "node /opt/homebrew/lib/node_modules/openclaw/dist/index.js gateway --port 9999",
            openClawOutput: "Gateway local reachable 20ms\nTasks 0 active · 0 queued · 0 running"
        )
        require(state("openclaw", in: gatewayOnly) == .offline, "只有后台 Gateway、入口已退出时应为红色")
    }

    private static func preservesOpenClawStateAcrossBriefProbeFailures() {
        let now = Date(timeIntervalSince1970: 1_000)
        let lastGood = "Gateway local reachable 20ms\nTasks 0 active · 0 queued · 0 running"

        require(
            LocalStatusParser.openClawLastKnownGoodOutput(
                output: lastGood,
                fetchedAt: now.addingTimeInterval(-15),
                now: now
            ) == lastGood,
            "OpenClaw 短暂探针失败时应保留最近有效状态"
        )
        require(
            LocalStatusParser.openClawLastKnownGoodOutput(
                output: lastGood,
                fetchedAt: now.addingTimeInterval(-31),
                now: now
            ) == nil,
            "OpenClaw 持续探针失败后不得无限保留旧绿灯"
        )

        let httpFallback = DirectStatusEvaluator.openClawResult(
            from: "Gateway local reachable via HTTP fallback"
        )
        require(httpFallback.0 == .idle, "OpenClaw Gateway HTTP 直连成功时应保持绿色可用")
    }

    private static func mapsLocalTaskEventSources() {
        let now = Date(timeIntervalSince1970: 1_000)
        let kimiRunning = try! JSONSerialization.data(withJSONObject: ["conversation": "running"])
        require(
            LocalStatusParser.kimiEvidence(data: kimiRunning, modifiedAt: now, now: now)?.state == .working,
            "Kimi running 应映射为任务中"
        )

        let codexLines = [
            #"{"timestamp":"1970-01-01T00:15:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"1970-01-01T00:15:01.000Z","type":"event_msg","payload":{"type":"agent_reasoning"}}"#,
        ].joined(separator: "\n").data(using: .utf8)!
        require(
            LocalStatusParser.codexEvidence(data: codexLines, modifiedAt: now, now: now)?.state == .working,
            "Codex 未完成任务应映射为任务中"
        )

    }

    private static func mapsKimiDaimonRuntimeStates() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let running = try! JSONSerialization.data(withJSONObject: [
            "lifecycleStatus": "running",
            "activeKernelTurns": [["id": "turn-1"]],
            "activeKernelToolCalls": [],
            "activeOperations": [],
            "activePendingInteractions": [],
        ])
        require(
            LocalStatusParser.kimiRunnerEvidence(data: running, modifiedAt: now, now: now)?.state == .working,
            "Kimi Daimon 活动 turn 应映射为任务中"
        )

        let lifecycleOnly = try! JSONSerialization.data(withJSONObject: [
            "lifecycleStatus": "running",
            "activeKernelTurns": [],
            "activeKernelToolCalls": [],
            "activeOperations": [],
            "activePendingInteractions": [],
        ])
        require(
            LocalStatusParser.kimiRunnerEvidence(data: lifecycleOnly, modifiedAt: now, now: now) == nil,
            "Kimi Daimon 仅 lifecycle=running 不得误判为任务中"
        )

        let wireWorking = [
            #"{"type":"context.append_loop_event","event":{"type":"step.begin"},"time":20000000000}"#,
            #"{"type":"llm.request","time":20000000000}"#,
        ].joined(separator: "\n").data(using: .utf8)!
        require(
            LocalStatusParser.kimiWireEvidence(data: wireWorking, modifiedAt: now, now: now)?.state == .working,
            "Kimi wire 开放步骤应映射为任务中"
        )

        let wireCompleted = [
            #"{"type":"context.append_loop_event","event":{"type":"step.begin"},"time":9999999000}"#,
            #"{"type":"context.append_loop_event","event":{"type":"step.end","finishReason":"end_turn"},"time":20000000000}"#,
            #"{"type":"usage.record","time":20000000000}"#,
        ].joined(separator: "\n").data(using: .utf8)!
        require(
            LocalStatusParser.kimiWireEvidence(data: wireCompleted, modifiedAt: now, now: now)?.state == .completed,
            "Kimi wire end_turn 后应映射为完成"
        )
        require(
            LocalStatusParser.kimiWireEvidence(
                data: wireCompleted,
                modifiedAt: now,
                now: now.addingTimeInterval(700)
            )?.state == .idle,
            "Kimi wire 完成蓝灯超过 TTL 后应回到空闲"
        )
    }

    private static func mapsOpenClawTrajectoryStates() {
        let now = Date(timeIntervalSince1970: 1_000)
        let workingLines = [
            #"{"type":"session.started","ts":"1970-01-01T00:16:39Z"}"#,
            #"{"type":"prompt.submitted","ts":"1970-01-01T00:16:40Z"}"#,
        ].joined(separator: "\n").data(using: .utf8)!
        require(
            LocalStatusParser.openClawTrajectoryEvidence(data: workingLines, modifiedAt: now, now: now)?.state == .working,
            "OpenClaw prompt.submitted 应映射为任务中"
        )

        let completedLines = [
            #"{"type":"prompt.submitted","ts":"1970-01-01T00:16:39Z"}"#,
            #"{"type":"session.ended","ts":"1970-01-01T00:16:40Z","data":{"status":"success"}}"#,
        ].joined(separator: "\n").data(using: .utf8)!
        require(
            LocalStatusParser.openClawTrajectoryEvidence(data: completedLines, modifiedAt: now, now: now)?.state == .completed,
            "OpenClaw session.ended 应映射为完成"
        )
    }

    private static func mapsHermesCompletion() {
        let now = Date(timeIntervalSince1970: 1_000)
        require(
            LocalStatusParser.hermesEvidence(activeSessions: 1, lastEndedAt: nil, now: now).state == .working,
            "Hermes 活动会话应映射为任务中"
        )
        require(
            LocalStatusParser.hermesEvidence(activeSessions: 0, lastEndedAt: now.addingTimeInterval(-5), now: now).state == .completed,
            "Hermes 最近结束会话应映射为完成"
        )
    }

    private static func mapsAwaitingHumanSignals() {
        let now = Date(timeIntervalSince1970: 1_000)
        let claudeWaiting = [
            #"{"type":"user","timestamp":"1970-01-01T00:16:39Z","message":{"role":"user","content":[{"type":"text","text":"task"}]}}"#,
            #"{"type":"assistant","timestamp":"1970-01-01T00:16:40Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"AskUserQuestion"}]}}"#,
        ].joined(separator: "\n").data(using: .utf8)!
        require(
            LocalStatusParser.claudeTranscriptEvidence(data: claudeWaiting, modifiedAt: now, now: now)?.state == .awaiting,
            "Claude AskUserQuestion 应映射为等待人工"
        )
        let claudeAnswered = (String(data: claudeWaiting, encoding: .utf8)! + "\n" +
            #"{"type":"user","timestamp":"1970-01-01T00:16:41Z","message":{"role":"user","content":[{"type":"text","text":"answer"}]}}"#)
            .data(using: .utf8)!
        require(
            LocalStatusParser.claudeTranscriptEvidence(data: claudeAnswered, modifiedAt: now, now: now)?.state != .awaiting,
            "Claude 用户回答后不得继续卡在黄灯"
        )

        let kimiWaiting = try! JSONSerialization.data(withJSONObject: [
            "activeKernelTurns": [["id": "turn-1"]],
            "activeKernelToolCalls": [],
            "activeOperations": [],
            "activePendingInteractions": [["id": "prompt-1"]],
        ])
        require(
            LocalStatusParser.kimiRunnerEvidence(data: kimiWaiting, modifiedAt: now, now: now)?.state == .awaiting,
            "Kimi activePendingInteractions 应映射为等待人工"
        )

        let codexWaiting = #"{"timestamp":"1970-01-01T00:16:40.000Z","type":"event_msg","payload":{"type":"approval_requested"}}"#
            .data(using: .utf8)!
        require(
            LocalStatusParser.codexEvidence(data: codexWaiting, modifiedAt: now, now: now)?.state == .awaiting,
            "Codex approval_requested 应映射为等待人工"
        )

        let cursorWaiting = #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"AskQuestion","input":{}}]}}"#
            .data(using: .utf8)!
        require(
            LocalStatusParser.cursorEvidence(data: cursorWaiting, modifiedAt: now, now: now)?.state == .awaiting,
            "Cursor AskQuestion 应映射为等待人工"
        )
        let cursorAnswered = (String(data: cursorWaiting, encoding: .utf8)! + "\n" +
            #"{"role":"user","message":{"content":[{"type":"text","text":"answer"}]}}"#)
            .data(using: .utf8)!
        require(
            LocalStatusParser.cursorEvidence(data: cursorAnswered, modifiedAt: now, now: now)?.state != .awaiting,
            "Cursor 用户回答后不得继续卡在黄灯"
        )

        let hermesWaiting = #"[hermes] {"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"session-1","payload":{}}}"#
            .data(using: .utf8)!
        require(
            LocalStatusParser.hermesEventEvidence(data: hermesWaiting, modifiedAt: now, now: now)?.state == .awaiting,
            "Hermes approval.request 应映射为等待人工"
        )
        let hermesResolved = (String(data: hermesWaiting, encoding: .utf8)! + "\n" +
            #"[hermes] {"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"session-1","payload":{}}}"#)
            .data(using: .utf8)!
        require(
            LocalStatusParser.hermesEventEvidence(data: hermesResolved, modifiedAt: now, now: now)?.state == .working,
            "Hermes 工具继续执行后应清除黄灯"
        )

        let openClawWaiting = #"{"type":"approval.required","ts":"1970-01-01T00:16:40Z"}"#
            .data(using: .utf8)!
        require(
            LocalStatusParser.openClawTrajectoryEvidence(data: openClawWaiting, modifiedAt: now, now: now)?.state == .awaiting,
            "OpenClaw approval.required 应映射为等待人工"
        )
        let openClawResolved = (String(data: openClawWaiting, encoding: .utf8)! + "\n" +
            #"{"type":"tool.result","ts":"1970-01-01T00:16:41Z","data":{"name":"bash","status":"completed"}}"#)
            .data(using: .utf8)!
        require(
            LocalStatusParser.openClawTrajectoryEvidence(data: openClawResolved, modifiedAt: now, now: now)?.state == .working,
            "OpenClaw 审批后工具继续执行时应清除黄灯"
        )
    }

    private static func preservesOfflineAndIdleDistinction() {
        let snapshot = DirectStatusEvaluator.snapshot(
            processText: "/Applications/Kimi.app/Contents/MacOS/Kimi"
        )
        require(state("kimi", in: snapshot) == .idle, "已打开且无活动证据的 App 应为空闲")
        require(state("codex", in: snapshot) == .offline, "未打开的 App 应为红色未开启")
    }

    private static func marksOpenButSignedOutAgentOffline() {
        let evidence = AgentStatusEvidence(
            state: .offline,
            sourceLabel: "Claude App 已打开 · 未登录",
            updatedAt: Date()
        )
        let snapshot = DirectStatusEvaluator.snapshot(
            processText: "/Applications/Claude.app/Contents/MacOS/Claude",
            evidence: ["claude": evidence]
        )
        guard let claude = snapshot.agents.first(where: { $0.definition.key == "claude" }) else {
            require(false, "缺少 Claude 状态")
            return
        }
        require(claude.state == .offline, "Claude 未登录时应为红色")
        require(!claude.ready, "Claude 未登录时不应标记为就绪")
    }

    private static func state(_ key: String, in snapshot: AgentHubSnapshot) -> AgentSignalState? {
        snapshot.agents.first { $0.definition.key == key }?.state
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
