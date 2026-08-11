import Foundation

struct AgentUsageWindow: Codable, Equatable, Identifiable {
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetsAt: Date?
    let approximate: Bool

    var id: String { "\(label)-\(resetsAt?.timeIntervalSince1970 ?? 0)" }
}

struct AgentUsageSnapshot: Codable, Equatable {
    let key: String
    let plan: String?
    let windows: [AgentUsageWindow]
    let sourceUpdatedAt: Date?
    let checkedAt: Date
    let sourcePath: String?
    let note: String?
    let error: String?

    var tightestWindow: AgentUsageWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    /// The quota used by the collapsed overview row. Cursor's named-model API
    /// bucket can be exhausted while its included Auto allowance is still usable,
    /// so the row intentionally prefers the included/weekly-style allowance.
    var summaryWindow: AgentUsageWindow? {
        guard key == "cs" else { return tightestWindow }
        if let included = windows.first(where: { window in
            let label = window.label.lowercased()
            return label.contains("auto")
                || label.contains("weekly")
                || label.contains("week")
                || label.contains("周")
                || label.contains("included")
        }) {
            return included
        }
        return windows.first { !$0.label.lowercased().contains("api") } ?? tightestWindow
    }

    var isStale: Bool {
        guard let sourceUpdatedAt else { return false }
        return Date().timeIntervalSince(sourceUpdatedAt) > 30 * 60
    }

    var hasAlert: Bool {
        windows.contains { $0.remainingPercent < 20 }
    }

    var hasExhaustedWindow: Bool {
        windows.contains { $0.remainingPercent <= 0.01 }
    }

    var summaryHasAlert: Bool {
        overviewAlertWindows.contains { $0.remainingPercent < 20 }
    }

    var summaryHasExhaustedWindow: Bool {
        overviewAlertWindows.contains { $0.remainingPercent <= 0.01 }
    }

    var overviewAlertWindows: [AgentUsageWindow] {
        guard key == "cs" else { return windows }
        return summaryWindow.map { [$0] } ?? []
    }

    func mergingError(from newer: AgentUsageSnapshot) -> AgentUsageSnapshot {
        AgentUsageSnapshot(
            key: key,
            plan: plan,
            windows: windows,
            sourceUpdatedAt: sourceUpdatedAt,
            checkedAt: newer.checkedAt,
            sourcePath: sourcePath,
            note: note,
            error: newer.error
        )
    }
}

struct AgentUsagePayload: Codable {
    let fetchedAt: Date
    let agents: [AgentUsageSnapshot]
}

struct AgentOverviewSnapshot {
    let status: AgentHubSnapshot
    let usageByKey: [String: AgentUsageSnapshot]
    let usageRefreshing: Bool
    let usageError: String?
    let watcherEnabled: Bool
    let spinnerAngle: CGFloat

    static func initial() -> AgentOverviewSnapshot {
        AgentOverviewSnapshot(
            status: .offline(),
            usageByKey: [:],
            usageRefreshing: false,
            usageError: nil,
            watcherEnabled: false,
            spinnerAngle: 0
        )
    }
}
