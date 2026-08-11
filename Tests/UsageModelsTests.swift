import Foundation

@main
struct UsageModelsTests {
    static func main() {
        let now = Date()
        let auto = AgentUsageWindow(
            label: "Auto",
            usedPercent: 39.46,
            remainingPercent: 60.54,
            resetsAt: now,
            approximate: true
        )
        let api = AgentUsageWindow(
            label: "API 模型",
            usedPercent: 100,
            remainingPercent: 0,
            resetsAt: now,
            approximate: false
        )
        let cursor = snapshot(key: "cs", windows: [auto, api], now: now)
        assert(cursor.tightestWindow?.label == "API 模型")
        assert(cursor.hasAlert)
        assert(cursor.hasExhaustedWindow)
        assert(cursor.summaryWindow?.label == "Auto")
        assert(cursor.summaryWindow?.remainingPercent == 60.54)
        assert(!cursor.summaryHasAlert)
        assert(!cursor.summaryHasExhaustedWindow)
        assert(cursor.overviewAlertWindows.map(\.label) == ["Auto"])

        let cursorAPIFallback = snapshot(key: "cs", windows: [api], now: now)
        assert(cursorAPIFallback.summaryWindow?.label == "API 模型")
        assert(cursorAPIFallback.summaryHasExhaustedWindow)
        assert(cursorAPIFallback.overviewAlertWindows.map(\.label) == ["API 模型"])

        let ordinary = snapshot(key: "cdx", windows: [auto, api], now: now)
        assert(ordinary.summaryWindow?.label == "API 模型")
        assert(ordinary.summaryHasExhaustedWindow)
        print("AgentSignalMenu usage summary model tests: PASS")
    }

    private static func snapshot(
        key: String,
        windows: [AgentUsageWindow],
        now: Date
    ) -> AgentUsageSnapshot {
        AgentUsageSnapshot(
            key: key,
            plan: "Pro",
            windows: windows,
            sourceUpdatedAt: now,
            checkedAt: now,
            sourcePath: "test",
            note: nil,
            error: nil
        )
    }
}
