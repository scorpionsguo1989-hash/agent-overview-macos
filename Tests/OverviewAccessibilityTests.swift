import Foundation

@main
struct OverviewAccessibilityTests {
    static func main() {
        let now = Date()
        let claude = AgentDefinition.monitored.first { $0.key == "claude" }!
        let hermes = AgentDefinition.monitored.first { $0.key == "hermes" }!
        let awaiting = AgentSignalSnapshot(
            definition: claude,
            state: .awaiting,
            sourceLabel: "synthetic fixture",
            updatedAt: now,
            ready: true
        )
        let usage = AgentUsageSnapshot(
            key: "cc",
            plan: nil,
            windows: [
                AgentUsageWindow(
                    label: "Weekly",
                    usedPercent: 81.6,
                    remainingPercent: 18.4,
                    resetsAt: now.addingTimeInterval(3_600),
                    approximate: false
                ),
            ],
            sourceUpdatedAt: now,
            checkedAt: now,
            sourcePath: "synthetic fixture",
            note: nil,
            error: nil
        )

        assert(AgentOverviewAccessibility.rowLabel(for: awaiting) == "Claude 详情")
        assert(
            AgentOverviewAccessibility.rowValue(
                for: awaiting,
                usage: usage,
                usageRefreshing: false,
                isExpanded: false
            ) == "等待人工，额度剩余 18%，已折叠"
        )
        assert(AgentOverviewAccessibility.rowHint(isExpanded: false) == "按下可展开详情")
        assert(AgentOverviewAccessibility.rowHint(isExpanded: true) == "按下可收起详情")

        let idleHermes = AgentSignalSnapshot(
            definition: hermes,
            state: .idle,
            sourceLabel: "synthetic fixture",
            updatedAt: now,
            ready: true
        )
        assert(
            AgentOverviewAccessibility.rowValue(
                for: idleHermes,
                usage: nil,
                usageRefreshing: false,
                isExpanded: true
            ) == "空闲，无额度接口，已展开"
        )
        assert(AgentOverviewAccessibility.watcherValue(enabled: true) == "已开启")
        assert(AgentOverviewAccessibility.watcherValue(enabled: false) == "已关闭")
        print("Agent Overview accessibility model tests: PASS")
    }
}
