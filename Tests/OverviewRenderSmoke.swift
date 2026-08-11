import AppKit
import SwiftUI

@main
struct OverviewRenderSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else { exit(64) }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)

        let now = Date()
        let states: [String: AgentSignalState] = [
            "cc": .idle,
            "cdx": .idle,
            "km": .working,
            "cs": .completed,
            "hm": .idle,
            "oc": .idle,
        ]
        let agents = AgentDefinition.monitored.map { definition in
            AgentSignalSnapshot(
                definition: definition,
                state: states[definition.shortLabel] ?? .offline,
                sourceLabel: "设计预览",
                updatedAt: now,
                ready: true
            )
        }
        let status = AgentHubSnapshot(agents: agents, connected: true, fetchedAt: now, errorMessage: nil)
        let usage = previewUsage(now: now)

        let model = AgentOverviewViewModel()
        if CommandLine.arguments.count == 3 {
            model.expandedKey = CommandLine.arguments[2]
        }
        model.overview = AgentOverviewSnapshot(
            status: status,
            usageByKey: usage,
            usageRefreshing: false,
            usageError: nil,
            watcherEnabled: true,
            spinnerAngle: .pi / 4
        )

        let hosting = NSHostingView(rootView: AgentOverviewPanel(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 470, height: 1_000)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let fittingHeight = hosting.fittingSize.height
        hosting.frame = NSRect(x: 0, y: 0, width: 470, height: fittingHeight)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }

        do {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
            print(CommandLine.arguments[1])
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func previewUsage(now: Date) -> [String: AgentUsageSnapshot] {
        func window(_ label: String, _ remaining: Double, resetHours: TimeInterval, approximate: Bool = false) -> AgentUsageWindow {
            AgentUsageWindow(
                label: label,
                usedPercent: 100 - remaining,
                remainingPercent: remaining,
                resetsAt: now.addingTimeInterval(resetHours * 3600),
                approximate: approximate
            )
        }
        func record(
            _ key: String,
            plan: String? = nil,
            windows: [AgentUsageWindow],
            sourceUpdatedAt: Date? = nil,
            note: String? = nil
        ) -> AgentUsageSnapshot {
            AgentUsageSnapshot(
                key: key,
                plan: plan,
                windows: windows,
                sourceUpdatedAt: sourceUpdatedAt ?? now,
                checkedAt: now,
                sourcePath: "设计预览",
                note: note,
                error: nil
            )
        }
        return [
            "cc": record("cc", windows: [window("5 小时窗口", 100, resetHours: 120), window("1 周窗口", 93, resetHours: 144)]),
            "cdx": record("cdx", plan: "Pro", windows: [window("1 周窗口", 76, resetHours: 142), window("Spark · 1 周窗口", 100, resetHours: 168)]),
            "km": record("km", plan: "会员", windows: [window("账户总额度", 85.66, resetHours: 672), window("5 小时窗口 · Code", 100, resetHours: 2.5), window("1 周窗口 · Code", 64.21, resetHours: 96)]),
            "cs": record("cs", plan: "Pro", windows: [window("Auto", 63, resetHours: 624, approximate: true), window("API 模型", 0, resetHours: 624)]),
        ]
    }
}
