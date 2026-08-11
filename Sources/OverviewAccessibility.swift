import Foundation

enum AgentOverviewAccessibility {
    static func rowLabel(for agent: AgentSignalSnapshot) -> String {
        "\(agent.definition.title) 详情"
    }

    static func rowValue(
        for agent: AgentSignalSnapshot,
        usage: AgentUsageSnapshot?,
        usageRefreshing: Bool,
        isExpanded: Bool
    ) -> String {
        [
            agent.state.chineseLabel,
            quotaDescription(for: agent, usage: usage, usageRefreshing: usageRefreshing),
            isExpanded ? "已展开" : "已折叠",
        ].joined(separator: "，")
    }

    static func rowHint(isExpanded: Bool) -> String {
        isExpanded ? "按下可收起详情" : "按下可展开详情"
    }

    static func watcherValue(enabled: Bool) -> String {
        enabled ? "已开启" : "已关闭"
    }

    private static func quotaDescription(
        for agent: AgentSignalSnapshot,
        usage: AgentUsageSnapshot?,
        usageRefreshing: Bool
    ) -> String {
        if let error = usage?.error, !error.isEmpty { return "额度读取失败" }
        if let usage, let window = usage.summaryWindow {
            let remaining = Int(window.remainingPercent.rounded())
            return usage.isStale
                ? "额度数据已过期，剩余 \(remaining)%"
                : "额度剩余 \(remaining)%"
        }
        if ["hm", "oc"].contains(agent.definition.shortLabel) { return "无额度接口" }
        if agent.ready && usageRefreshing { return "额度正在同步" }
        return agent.ready ? "额度待同步" : "暂无额度信息"
    }
}
